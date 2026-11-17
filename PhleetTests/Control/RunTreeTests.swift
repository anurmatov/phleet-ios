import XCTest
@testable import Phleet

/// Laying a flat list of runs out as the tree their links make: a driver, the runs it started,
/// and the reviews those started. The same cases as the dashboard's.
final class RunTreeTests: XCTestCase {

    private func run(
        _ workflowId: String,
        runId: String? = nil,
        namespace: String = "fleet",
        parent: String? = nil,
        parentRun: String? = nil,
        waiter: String? = nil
    ) -> WorkflowRun {
        WorkflowRun(
            workflowId: workflowId,
            runId: runId ?? "run-" + workflowId,
            workflowType: "T",
            namespace: namespace,
            parentWorkflowId: parent,
            parentRunId: parentRun,
            waiterWorkflowId: waiter
        )
    }

    private func shape(_ placed: [RunTree.Placed]) -> [String] {
        placed.map { entry in
            let link: String
            switch entry.link {
            case .child?: link = " (child)"
            case .started?: link = " (started)"
            case nil: link = ""
            }
            return String(repeating: "  ", count: entry.depth) + entry.run.workflowId + link
        }
    }

    func testADriverTheRunItStartedAndThatRunsReviewReadAsOneTree() {
        let review = run("review-1", parent: "pr-601", parentRun: "run-pr-601")
        let driver = run("driver-1325")
        let pullRequest = run("pr-601", waiter: "driver-1325")
        let other = run("pr-1323")
        let blocked = run("driver-1273")

        XCTAssertEqual(shape(RunTree.arrange([review, driver, pullRequest, other, blocked])), [
            "driver-1325",
            "  pr-601 (started)",
            "    review-1 (child)",
            "pr-1323",
            "driver-1273"
        ])
    }

    func testRunsWithNoLinkKeepTheOrderTheyCameIn() {
        let runs = [run("c"), run("a"), run("b")]
        let placed = RunTree.arrange(runs)
        XCTAssertEqual(placed.map(\.run), runs)
        XCTAssertTrue(placed.allSatisfy { $0.depth == 0 && $0.link == nil && $0.elsewhere == nil })
    }

    func testSiblingsKeepTheirOrderAndEveryRunIsPlacedOnce() {
        let runs = [
            run("child-b", parent: "parent"), run("other"), run("parent"),
            run("child-a", parent: "parent"), run("grandchild", parent: "child-b")
        ]
        let placed = RunTree.arrange(runs)
        XCTAssertEqual(shape(placed), [
            "other", "parent", "  child-b (child)", "    grandchild (child)", "  child-a (child)"
        ])
        XCTAssertEqual(placed.count, runs.count)
        XCTAssertEqual(Set(placed.map(\.id)).count, runs.count)
    }

    func testTheRunIdTellsOneRunOfAReusedWorkflowIdFromAnother() {
        let old = run("parent", runId: "run-old")
        let current = run("parent", runId: "run-new")
        let child = run("child", parent: "parent", parentRun: "run-new")
        XCTAssertEqual(shape(RunTree.arrange([old, current, child])), ["parent", "parent", "  child (child)"])

        // Without a run id on the link, the first run of that id is the one.
        let loose = run("loose", parent: "parent")
        XCTAssertEqual(shape(RunTree.arrange([old, current, loose])), ["parent", "  loose (child)", "parent"])
    }

    func testAParentIsLookedForInTheRunsOwnNamespaceAndAWaiterAnywhere() {
        let otherParent = run("parent", namespace: "ops")
        let child = run("child", parent: "parent")
        XCTAssertEqual(shape(RunTree.arrange([otherParent, child])), ["parent", "child"])

        let opsDriver = run("driver", namespace: "ops")
        let fleetDriver = run("driver", runId: "run-fleet-driver")
        let started = run("started", waiter: "driver")
        XCTAssertEqual(shape(RunTree.arrange([opsDriver, started])), ["driver", "  started (started)"])
        // Its own namespace first.
        XCTAssertEqual(
            shape(RunTree.arrange([opsDriver, fleetDriver, started])),
            ["driver", "driver", "  started (started)"]
        )
    }

    func testTheParentWinsOverTheWaiterAndTheWaiterIsUsedWhenTheParentIsNotListed() {
        let both = run("both", parent: "parent", waiter: "driver")
        XCTAssertEqual(
            shape(RunTree.arrange([run("driver"), run("parent"), both])),
            ["driver", "parent", "  both (child)"]
        )
        XCTAssertEqual(shape(RunTree.arrange([run("driver"), both])), ["driver", "  both (started)"])
    }

    func testARunWhoseOwnerIsNotInTheListStaysAtTheTopAndSaysWhoseItIs() {
        let driver = run("driver-1")
        let started = run("started", waiter: "driver-1")
        let orphan = run("orphan", parent: "gone-parent")

        // The driver is known from the whole list, though the search left it out of this one.
        let placed = RunTree.arrange([started, orphan], everything: [driver, started, orphan])
        XCTAssertEqual(placed.map(\.depth), [0, 0])
        XCTAssertEqual(placed[0].elsewhere, RunTree.Elsewhere(workflowId: "driver-1", link: .started, run: driver))
        // The parent is over: named by its identifier alone.
        XCTAssertEqual(placed[1].elsewhere, RunTree.Elsewhere(workflowId: "gone-parent", link: .child, run: nil))
    }

    func testARunNestedUnderItsOwnerDoesNotAlsoSayItBelongsElsewhere() {
        let placed = RunTree.arrange([run("parent"), run("child", parent: "parent")])
        XCTAssertNil(placed[1].elsewhere)
        XCTAssertEqual(placed[1].link, .child)
    }

    func testRunsThatOnlyPointAtEachOtherOrAtThemselvesEachGetOneRow() {
        let first = run("a", waiter: "b")
        let second = run("b", waiter: "a")
        let own = run("self", parent: "self", parentRun: "run-self", waiter: "self")
        let placed = RunTree.arrange([first, second, own])
        XCTAssertEqual(placed.count, 3)
        XCTAssertEqual(Set(placed.map(\.id)), Set([first, second, own].map(\.identity)))
    }

    func testALongChainStopsMovingRightAndStaysInOrder() {
        let chain = (0..<8).map { index in
            run("r\(index)", parent: index == 0 ? nil : "r\(index - 1)")
        }
        let placed = RunTree.arrange(chain)
        XCTAssertEqual(placed.map(\.run.workflowId), chain.map(\.workflowId))
        let deepest = RunTree.maximumDepth
        XCTAssertEqual(placed.map(\.depth), [0, 1, 2, 3, deepest, deepest, deepest, deepest])
    }

    func testARunFromAnOlderOrchestratorDecodesWithoutLinksAndALinkedOneWithThem() throws {
        let decoder = JSONDecoder()
        let plain = try decoder.decode(WorkflowRun.self, from: Data("""
        {"workflowId":"w","runId":"r","workflowType":"T","namespace":"fleet","status":"Running"}
        """.utf8))
        XCTAssertNil(plain.parentWorkflowId)
        XCTAssertNil(plain.parentRunId)
        XCTAssertNil(plain.waiterWorkflowId)

        let linked = try decoder.decode(WorkflowRun.self, from: Data("""
        {"workflowId":"w","runId":"r","workflowType":"T","namespace":"fleet","status":"Running",
         "parentWorkflowId":"p","parentRunId":"pr","waiterWorkflowId":"d"}
        """.utf8))
        XCTAssertEqual(linked.parentWorkflowId, "p")
        XCTAssertEqual(linked.parentRunId, "pr")
        XCTAssertEqual(linked.waiterWorkflowId, "d")

        // A link of the wrong shape costs the link, never the run.
        let odd = try decoder.decode(WorkflowRun.self, from: Data("""
        {"workflowId":"w","runId":"r","workflowType":"T","namespace":"fleet","status":"Running",
         "parentWorkflowId":7,"waiterWorkflowId":null}
        """.utf8))
        XCTAssertNil(odd.parentWorkflowId)
        XCTAssertNil(odd.waiterWorkflowId)
    }
}
