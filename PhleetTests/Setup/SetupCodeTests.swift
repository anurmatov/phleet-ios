import XCTest
@testable import Phleet

/// Reading a setup code. The format is the dashboard's (`phoneSetup.ts` in the platform
/// repository); the literals here are that format with synthetic values. A scanned code is
/// untrusted input: it may be any QR code at all.
final class SetupCodeTests: XCTestCase {

    /// What the dashboard draws for a fleet behind an access proxy, key for key.
    private let full = #"{"phleet":"setup","v":2,"origin":"https://fleet.example.invalid","#
        + #""accessClientId":"client-id-1","accessClientSecret":"client-secret-1","#
        + #""enrollmentCode":"enrollment-1.secret-value"}"#

    private let direct = #"{"phleet":"setup","v":2,"origin":"https://fleet.example.invalid","#
        + #""enrollmentCode":"enrollment-1.secret-value"}"#

    // MARK: - Reading

    func testAFullCodeReadsEveryPart() throws {
        let code = try SetupCode.parse(full).get()

        XCTAssertEqual(code.origin, "https://fleet.example.invalid")
        XCTAssertEqual(
            code.serviceToken,
            AccessServiceToken(clientId: "client-id-1", clientSecret: "client-secret-1")
        )
        XCTAssertEqual(code.enrollmentCode, "enrollment-1.secret-value")
        XCTAssertEqual(code.displayName, "fleet.example.invalid")
    }

    func testACodeForADirectlyReachedFleetHasNoServiceToken() throws {
        let code = try SetupCode.parse("  " + direct + "\n").get()

        XCTAssertNil(code.accessClientId)
        XCTAssertNil(code.accessClientSecret)
        XCTAssertNil(code.serviceToken)
    }

    func testAnAddressWithAPathKeepsIt() throws {
        let code = try SetupCode.parse(
            #"{"phleet":"setup","v":2,"origin":"https://fleet.example.invalid/fleet","enrollmentCode":"e.s"}"#
        ).get()
        XCTAssertEqual(code.origin, "https://fleet.example.invalid/fleet")
    }

    // MARK: - Refusing by name

    func testACodeFromAnOlderDashboardIsRefusedByNameAndNothingInItIsRead() {
        // It carried the fleet-wide operator token. This build neither uses nor keeps one.
        let older = #"{"phleet":"control-setup","v":1,"origin":"https://fleet.example.invalid","#
            + #""operatorToken":"operator-token-1"}"#
        XCTAssertEqual(SetupCode.parse(older), .failure(.olderDashboard))
        XCTAssertEqual(SetupCode.parse(LaunchDouble.olderSetupCode), .failure(.olderDashboard))
    }

    func testSomeOtherQRCodeIsNotASetupCode() {
        let others = [
            "",
            "https://example.invalid/some/page",
            "WIFI:T:WPA;S:network;P:password;;",
            "[1,2,3]",
            #"{"phleet":"something-else","v":2,"origin":"https://fleet.example.invalid"}"#,
            #"{"v":2,"origin":"https://fleet.example.invalid","enrollmentCode":"e.s"}"#,
            #"{"phleet":42,"v":2,"origin":"https://fleet.example.invalid"}"#
        ]
        for other in others {
            XCTAssertEqual(SetupCode.parse(other), .failure(.notASetupCode), other)
        }
    }

    func testSomethingFarTooLongIsRefusedBeforeItIsParsed() {
        let padded = #"{"phleet":"setup","v":2,"origin":"https://fleet.example.invalid","x":""#
            + String(repeating: "a", count: SetupCode.maximumLength) + #""}"#
        XCTAssertEqual(SetupCode.parse(padded), .failure(.notASetupCode))
    }

    func testAnotherVersionIsNamedAsThatAndNothingInItIsRead() {
        let newer = #"{"phleet":"setup","v":3,"origin":"https://fleet.example.invalid","enrollmentCode":"e.s"}"#
        XCTAssertEqual(SetupCode.parse(newer), .failure(.unsupportedVersion(3)))

        let unversioned = #"{"phleet":"setup","origin":"https://fleet.example.invalid","enrollmentCode":"e.s"}"#
        XCTAssertEqual(SetupCode.parse(unversioned), .failure(.unsupportedVersion(nil)))

        let stringVersion = #"{"phleet":"setup","v":"2","origin":"https://fleet.example.invalid","enrollmentCode":"e.s"}"#
        XCTAssertEqual(SetupCode.parse(stringVersion), .failure(.unsupportedVersion(nil)))
    }

    func testAMissingPartIsIncomplete() {
        let cases = [
            #"{"phleet":"setup","v":2,"enrollmentCode":"e.s"}"#,
            #"{"phleet":"setup","v":2,"origin":7,"enrollmentCode":"e.s"}"#,
            #"{"phleet":"setup","v":2,"origin":"https://fleet.example.invalid"}"#,
            #"{"phleet":"setup","v":2,"origin":"https://fleet.example.invalid","enrollmentCode":"  "}"#,
            #"{"phleet":"setup","v":2,"origin":"https://fleet.example.invalid","enrollmentCode":"e.s","accessClientId":"client-id-1"}"#,
            #"{"phleet":"setup","v":2,"origin":"https://fleet.example.invalid","enrollmentCode":"e.s","accessClientSecret":"s"}"#
        ]
        for text in cases {
            XCTAssertEqual(SetupCode.parse(text), .failure(.incomplete), text)
        }
    }

    // MARK: - The address

    func testAnInsecureAddressIsRefusedRatherThanUpgraded() {
        XCTAssertEqual(
            SetupCode.parse(
                #"{"phleet":"setup","v":2,"origin":"http://fleet.example.invalid","enrollmentCode":"e.s"}"#
            ),
            .failure(.insecureAddress)
        )
    }

    func testAnAddressWithCredentialsOrNoHostIsRefused() {
        let cases = [
            #"{"phleet":"setup","v":2,"origin":"https://someone:secret@fleet.example.invalid","enrollmentCode":"e.s"}"#,
            #"{"phleet":"setup","v":2,"origin":"https://","enrollmentCode":"e.s"}"#
        ]
        for text in cases {
            XCTAssertEqual(SetupCode.parse(text), .failure(.invalidAddress), text)
        }
    }

    // MARK: - The scripted stand-in for the camera

    func testTheScriptedCodeIsAValidSetupCode() throws {
        let code = try SetupCode.parse(LaunchDouble.scriptedSetupCode).get()
        XCTAssertEqual(code.origin, "https://scripted.example.invalid")
        XCTAssertFalse(code.enrollmentCode.isEmpty)
    }
}
