import SwiftUI

/// What this device is connected to, and the one thing to do about it: remove it.
///
/// Shows the address and what the connection may do. It never shows a secret, and it offers no
/// editing — a changed address or token is a different connection, made by removing this one and
/// setting up again.
struct ControlConnectionView: View {

    let credential: ControlCredential
    let remove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemoval = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent {
                        Text(verbatim: displayAddress)
                    } label: {
                        Text("connection.address")
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.connectionAddress.identifier)

                    LabeledContent {
                        Text(modeKey)
                    } label: {
                        Text("connection.mode")
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.connectionMode.identifier)

                    LabeledContent {
                        Text(proxyKey)
                    } label: {
                        Text("connection.proxy")
                    }
                } footer: {
                    Text("connection.help")
                }

                Section {
                    if isConfirmingRemoval {
                        Button(role: .destructive) {
                            remove()
                        } label: {
                            Text("connection.remove.confirm")
                        }
                        .accessibilityIdentifier(
                            AccessibilityIdentifier.connectionRemoveConfirm.identifier
                        )
                        .accessibilityLabel(
                            AccessibilityIdentifier.connectionRemoveConfirm.localizedLabel
                        )

                        Button(role: .cancel) {
                            isConfirmingRemoval = false
                        } label: {
                            Text("connection.remove.cancel")
                        }
                        .accessibilityIdentifier(
                            AccessibilityIdentifier.connectionRemoveCancel.identifier
                        )
                        .accessibilityLabel(
                            AccessibilityIdentifier.connectionRemoveCancel.localizedLabel
                        )
                    } else {
                        Button(role: .destructive) {
                            isConfirmingRemoval = true
                        } label: {
                            Text("connection.remove")
                        }
                        .accessibilityIdentifier(AccessibilityIdentifier.connectionRemove.identifier)
                        .accessibilityLabel(AccessibilityIdentifier.connectionRemove.localizedLabel)
                    }
                } footer: {
                    Text("connection.remove.help")
                }
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

    // Typed explicitly so each is looked up in the catalog rather than shown as its own key.
    private var modeKey: LocalizedStringKey {
        credential.canDecide ? "connection.mode.decide" : "connection.mode.readOnly"
    }

    private var proxyKey: LocalizedStringKey {
        credential.serviceToken == nil ? "connection.proxy.none" : "connection.proxy.serviceToken"
    }

    /// The host, without the scheme: the scheme is always the same and the host is what a person
    /// recognises.
    private var displayAddress: String {
        guard let components = URLComponents(string: credential.origin) else {
            return credential.origin
        }
        let name = ServerDisplayName.derive(from: components)
        return name.isEmpty ? credential.origin : name
    }
}
