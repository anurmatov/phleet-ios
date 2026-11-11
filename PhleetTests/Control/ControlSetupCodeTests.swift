import XCTest
@testable import Phleet

/// Reading a setup code, and what scanning one is allowed to do.
///
/// The format is the platform's (`docs/phone-setup-code.md`); the literals here are that format
/// with synthetic values. A scanned code is untrusted input: it may be any QR code at all.
@MainActor
final class ControlSetupCodeTests: XCTestCase {

    private let full = #"{"phleet":"control-setup","v":1,"origin":"https://fleet.example.invalid","#
        + #""accessClientId":"client-id-1","accessClientSecret":"client-secret-1","#
        + #""operatorToken":"operator-token-1"}"#

    private let readOnly = #"{"phleet":"control-setup","v":1,"origin":"https://fleet.example.invalid"}"#

    private func makeModel(api: FakeControlAPI = FakeControlAPI()) -> ControlSetupModel {
        ControlSetupModel(api: api, credentialStore: InMemoryControlCredentialStore())
    }

    // MARK: - Parsing

    func testAFullCodeReadsEveryPart() {
        XCTAssertEqual(
            ControlSetupCode.parse(full),
            .success(
                ControlSetupCode(
                    origin: "https://fleet.example.invalid",
                    accessClientId: "client-id-1",
                    accessClientSecret: "client-secret-1",
                    operatorToken: "operator-token-1"
                )
            )
        )
    }

    func testAReadOnlyCodeHasNoTokens() {
        XCTAssertEqual(
            ControlSetupCode.parse("  " + readOnly + "\n"),
            .success(
                ControlSetupCode(
                    origin: "https://fleet.example.invalid",
                    accessClientId: nil,
                    accessClientSecret: nil,
                    operatorToken: nil
                )
            )
        )
    }

    func testAnEmptyPartIsAbsentNotEmpty() {
        let code = #"{"phleet":"control-setup","v":1,"origin":"https://fleet.example.invalid","operatorToken":"  "}"#
        guard case .success(let parsed) = ControlSetupCode.parse(code) else {
            return XCTFail("an empty token is a read-only code, not a broken one")
        }
        XCTAssertNil(parsed.operatorToken)
    }

    func testSomeOtherQRCodeIsNotASetupCode() {
        let others = [
            "",
            "https://example.invalid/some/page",
            "WIFI:T:WPA;S:network;P:password;;",
            "[1,2,3]",
            #"{"phleet":"something-else","v":1,"origin":"https://fleet.example.invalid"}"#,
            #"{"v":1,"origin":"https://fleet.example.invalid"}"#,
            #"{"phleet":42,"v":1,"origin":"https://fleet.example.invalid"}"#
        ]
        for other in others {
            XCTAssertEqual(ControlSetupCode.parse(other), .failure(.notASetupCode), other)
        }
    }

    func testSomethingFarTooLongIsRefusedBeforeItIsParsed() {
        let padded = #"{"phleet":"control-setup","v":1,"origin":"https://fleet.example.invalid","x":""#
            + String(repeating: "a", count: ControlSetupCode.maximumLength) + #""}"#
        XCTAssertEqual(ControlSetupCode.parse(padded), .failure(.notASetupCode))
    }

    func testANewerFormatIsNamedAsThatAndNothingInItIsRead() {
        let newer = #"{"phleet":"control-setup","v":2,"origin":"https://fleet.example.invalid"}"#
        XCTAssertEqual(ControlSetupCode.parse(newer), .failure(.unsupportedVersion(2)))

        let unversioned = #"{"phleet":"control-setup","origin":"https://fleet.example.invalid"}"#
        XCTAssertEqual(ControlSetupCode.parse(unversioned), .failure(.unsupportedVersion(nil)))

        let stringVersion = #"{"phleet":"control-setup","v":"1","origin":"https://fleet.example.invalid"}"#
        XCTAssertEqual(ControlSetupCode.parse(stringVersion), .failure(.unsupportedVersion(nil)))
    }

    func testACodeWithNoAddressIsIncomplete() {
        XCTAssertEqual(
            ControlSetupCode.parse(#"{"phleet":"control-setup","v":1}"#),
            .failure(.missingAddress)
        )
        XCTAssertEqual(
            ControlSetupCode.parse(#"{"phleet":"control-setup","v":1,"origin":7}"#),
            .failure(.missingAddress)
        )
    }

    func testHalfAServiceTokenIsIncomplete() {
        let half = #"{"phleet":"control-setup","v":1,"origin":"https://fleet.example.invalid","accessClientId":"client-id-1"}"#
        XCTAssertEqual(ControlSetupCode.parse(half), .failure(.incompleteServiceToken))
    }

    // MARK: - Scanning fills the form and nothing else

    func testAScannedCodeFillsTheFormAndNeverConnects() {
        let api = FakeControlAPI()
        let model = makeModel(api: api)

        XCTAssertTrue(model.apply(scanned: full))

        XCTAssertEqual(model.address, "https://fleet.example.invalid")
        XCTAssertEqual(model.accessClientId, "client-id-1")
        XCTAssertEqual(model.accessClientSecret, "client-secret-1")
        XCTAssertEqual(model.operatorToken, "operator-token-1")
        XCTAssertTrue(model.didFillFromScan)
        XCTAssertNil(model.scanMessage)
        // The address is on screen for a person to check. Connecting is a separate tap.
        XCTAssertTrue(api.calls.isEmpty, "scanning must never contact the scanned address")
    }

    func testAReadOnlyCodeClearsATokenThatWasAlreadyTyped() {
        // Otherwise a token typed for one orchestrator would be sent to whatever address a
        // scanned code named.
        let model = makeModel()
        model.operatorToken = "a-token-typed-earlier"
        model.accessClientId = "an-id-typed-earlier"
        model.accessClientSecret = "a-secret-typed-earlier"

        XCTAssertTrue(model.apply(scanned: readOnly))

        XCTAssertEqual(model.operatorToken, "")
        XCTAssertEqual(model.accessClientId, "")
        XCTAssertEqual(model.accessClientSecret, "")
    }

    func testACodeThatCannotBeReadChangesNothingThatWasTyped() {
        let model = makeModel()
        model.address = "typed.example.invalid"
        model.operatorToken = "typed-token"

        XCTAssertFalse(model.apply(scanned: "WIFI:T:WPA;S:network;P:password;;"))

        XCTAssertEqual(model.address, "typed.example.invalid")
        XCTAssertEqual(model.operatorToken, "typed-token")
        XCTAssertEqual(model.scanMessage, .setupCodeNotRecognised)
        XCTAssertFalse(model.didFillFromScan)
    }

    func testEachUnreadableCodeIsNamed() {
        let cases: [(String, ControlSetupModel.Message)] = [
            ("not a code", .setupCodeNotRecognised),
            (#"{"phleet":"control-setup","v":9,"origin":"https://fleet.example.invalid"}"#, .setupCodeNewerFormat),
            (#"{"phleet":"control-setup","v":1}"#, .setupCodeIncomplete),
            (#"{"phleet":"control-setup","v":1,"origin":"https://fleet.example.invalid","accessClientSecret":"s"}"#, .setupCodeIncomplete)
        ]
        for (text, expected) in cases {
            let model = makeModel()
            model.apply(scanned: text)
            XCTAssertEqual(model.scanMessage, expected, text)
        }
    }

    func testAScannedInsecureAddressIsRefusedByTheSameRuleAsATypedOne() async {
        // The scan fills it in as written; nothing upgrades it, and connect refuses it.
        let api = FakeControlAPI()
        let model = makeModel(api: api)
        model.apply(scanned: #"{"phleet":"control-setup","v":1,"origin":"http://fleet.example.invalid"}"#)
        XCTAssertEqual(model.address, "http://fleet.example.invalid")

        let credential = await model.connect()

        XCTAssertNil(credential)
        XCTAssertEqual(model.addressMessage, .addressInsecure)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testAScannedCodeConnectsWithExactlyWhatItCarried() async throws {
        let api = FakeControlAPI()
        let model = makeModel(api: api)
        model.apply(scanned: full)

        let credential = try await XCTUnwrapAsync(model.connect())

        XCTAssertEqual(credential.connection, .fixture)
        XCTAssertFalse(model.didFillFromScan, "the notice belongs to the scan, not to the attempt")
    }

    // MARK: - The scripted stand-in for the camera

    func testTheScriptedCodeIsAValidSetupCode() {
        guard case .success(let code) = ControlSetupCode.parse(LaunchDouble.scriptedSetupCode) else {
            return XCTFail("the scripted setup code does not parse")
        }
        XCTAssertEqual(code.origin, "https://scripted.example.invalid")
        XCTAssertNotNil(code.operatorToken)
    }

    func testOnlyTheScriptedBackendStandsInForTheCamera() {
        let real = AppEnvironment(
            credentialStore: InMemoryCredentialStore(),
            api: FakeFleetAPI(),
            stream: FakeConversationStream(),
            controlCredentialStore: InMemoryControlCredentialStore(),
            controlAPI: FakeControlAPI(),
            controlStream: FakeControlLiveStream(),
            controlLogStream: FakeAgentLogStream(),
            launchArguments: [],
            launchEnvironment: [:]
        )
        XCTAssertNil(real.scriptedSetupCode, "a real launch opens the scanner")

        let scripted = AppEnvironment(
            launchArguments: [LaunchArguments.scriptedBackend],
            launchEnvironment: [:]
        )
        XCTAssertEqual(scripted.scriptedSetupCode, LaunchDouble.scriptedSetupCode)

        let unreadable = AppEnvironment(
            launchArguments: [LaunchArguments.scriptedBackend, LaunchArguments.unreadableSetupCode],
            launchEnvironment: [:]
        )
        XCTAssertEqual(unreadable.scriptedSetupCode, "not a setup code")
    }
}
