import LocalAuthentication
import Observation
import SwiftUI

/// The operating system's check that the person holding the phone is its owner.
///
/// Behind a seam because a simulator has no enrolled face and a test cannot answer the prompt.
protocol OwnerCheck {
    /// Whether the phone can check at all. It cannot without a passcode.
    var canEvaluate: Bool { get }
    func evaluate(reason: String) async -> Bool
}

/// Face ID or Touch ID, falling back to the passcode: whatever the phone itself unlocks with.
struct SystemOwnerCheck: OwnerCheck {

    var canEvaluate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func evaluate(reason: String) async -> Bool {
        // A new context each time, so one success is never reused for the next action.
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
        } catch {
            // Cancelled, failed or unavailable: none of them is a yes.
            return false
        }
    }
}

/// An optional second look before something that cannot be undone from the phone.
///
/// Off by default. When on, sending a gate decision, acting on an agent, and cancelling or
/// terminating a run each ask the phone to confirm its owner first — a phone left unlocked on a
/// desk should not be able to approve a merge.
///
/// It is a guard on this phone's interface, not a credential: the orchestrator neither knows nor
/// cares whether it was asked. Turning it off takes the same check as the actions it guards, or
/// it would guard nothing.
@MainActor
@Observable
final class OwnerConfirmation {

    private let check: OwnerCheck
    private let preferences: PreferenceStore

    private(set) var isRequired: Bool

    init(check: OwnerCheck, preferences: PreferenceStore) {
        self.check = check
        self.preferences = preferences
        self.isRequired = preferences.bool(forKey: PreferenceKey.confirmOwner)
    }

    /// Whether the switch can be offered. A phone with no passcode has nothing to check against.
    var isAvailable: Bool { check.canEvaluate }

    /// `true` when the action may go ahead: the switch is off, or the owner confirmed.
    func confirm(reason: String) async -> Bool {
        guard isRequired else { return true }
        return await check.evaluate(reason: reason)
    }

    /// Turns the switch on or off. Either way the owner confirms first.
    @discardableResult
    func setRequired(_ wanted: Bool, reason: String) async -> Bool {
        guard wanted != isRequired else { return true }
        guard await check.evaluate(reason: reason) else { return false }
        isRequired = wanted
        preferences.setBool(wanted, forKey: PreferenceKey.confirmOwner)
        return true
    }
}

/// How a view asks for the second look.
///
/// An environment value with a default that says yes, so a view rendered on its own — in a
/// preview or a rendering test — behaves as it does with the switch off.
struct ConfirmOwnerAction: Sendable {

    let perform: @MainActor @Sendable (String) async -> Bool

    @MainActor
    func callAsFunction(_ reason: String) async -> Bool {
        await perform(reason)
    }
}

private struct ConfirmOwnerKey: EnvironmentKey {
    static let defaultValue = ConfirmOwnerAction { _ in true }
}

extension EnvironmentValues {
    var confirmOwner: ConfirmOwnerAction {
        get { self[ConfirmOwnerKey.self] }
        set { self[ConfirmOwnerKey.self] = newValue }
    }
}
