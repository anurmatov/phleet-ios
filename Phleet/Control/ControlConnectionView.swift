import SwiftUI

/// What this phone is signed in to, notifications, and the one thing to do about the sign-in:
/// sign out.
///
/// Shows the address and whether an access proxy is in front of it. It never shows a secret, and
/// it offers no editing — another server is another sign-in, made by signing out and scanning a
/// new code.
struct ControlConnectionView: View {

    let credential: DeviceCredential
    /// Notifications for this sign-in, or `nil` when there is nothing to offer.
    let push: PushNotificationsModel?
    /// The second look before a decision, or `nil` where there is no switch to offer.
    var ownerConfirmation: OwnerConfirmation?

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent {
                        Text(verbatim: ServerDisplayName.derive(fromOrigin: credential.origin))
                    } label: {
                        Text("connection.address")
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.connectionAddress.identifier)

                    LabeledContent {
                        Text(proxyKey)
                    } label: {
                        Text("connection.proxy")
                    }
                } footer: {
                    Text("connection.help")
                }

                if let push {
                    PushNotificationsSection(model: push)
                }

                if let ownerConfirmation {
                    OwnerConfirmationSection(model: ownerConfirmation)
                }

                signOutSection
            }
            .navigationTitle(Text("connection.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("connection.done")
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.connectionDone.identifier)
                    .accessibilityLabel(AccessibilityIdentifier.connectionDone.localizedLabel)
                }
            }
        }
    }

    /// Two taps: a sign-out cannot be undone from here, and the way back is a new code from the
    /// dashboard.
    private var signOutSection: some View {
        Section {
            if appEnvironment.isSigningOut {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("connection.signOut.progress")
                        .font(.body)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(
                    AccessibilityIdentifier.connectionSignOutProgress.identifier
                )
            } else if isConfirmingSignOut {
                Button(role: .destructive) {
                    Task { await appEnvironment.signOut() }
                } label: {
                    Text("connection.signOut.confirm")
                }
                .accessibilityIdentifier(
                    AccessibilityIdentifier.connectionSignOutConfirm.identifier
                )
                .accessibilityLabel(
                    AccessibilityIdentifier.connectionSignOutConfirm.localizedLabel
                )

                Button(role: .cancel) {
                    isConfirmingSignOut = false
                } label: {
                    Text("connection.signOut.cancel")
                }
                .accessibilityIdentifier(AccessibilityIdentifier.connectionSignOutCancel.identifier)
                .accessibilityLabel(
                    AccessibilityIdentifier.connectionSignOutCancel.localizedLabel
                )
            } else {
                Button(role: .destructive) {
                    isConfirmingSignOut = true
                } label: {
                    Text("connection.signOut")
                }
                .accessibilityIdentifier(AccessibilityIdentifier.connectionSignOut.identifier)
                .accessibilityLabel(AccessibilityIdentifier.connectionSignOut.localizedLabel)
            }
        } footer: {
            Text("connection.signOut.help")
        }
    }

    // Typed explicitly so it is looked up in the catalog rather than shown as its own key.
    private var proxyKey: LocalizedStringKey {
        credential.serviceToken == nil ? "connection.proxy.none" : "connection.proxy.serviceToken"
    }
}

/// The switch for the second look before a decision or a disruptive action.
///
/// A plain button rather than a toggle: flipping it asks the phone to confirm its owner, which
/// can be declined, and a toggle that springs back reads as a fault.
struct OwnerConfirmationSection: View {

    let model: OwnerConfirmation

    @State private var isChanging = false

    var body: some View {
        Section {
            LabeledContent {
                Text(model.isRequired ? "confirmOwner.state.on" : "confirmOwner.state.off")
            } label: {
                Text("confirmOwner.title")
            }

            if model.isAvailable {
                Button {
                    let wanted = !model.isRequired
                    isChanging = true
                    Task {
                        await model.setRequired(
                            wanted,
                            reason: String(localized: "confirmOwner.reason.setting")
                        )
                        isChanging = false
                    }
                } label: {
                    Text(model.isRequired ? "confirmOwner.turnOff" : "confirmOwner.turnOn")
                }
                .disabled(isChanging)
                .accessibilityIdentifier(AccessibilityIdentifier.connectionConfirmOwner.identifier)
            }
        } footer: {
            Text(model.isAvailable ? "confirmOwner.help" : "confirmOwner.unavailable")
        }
    }
}
