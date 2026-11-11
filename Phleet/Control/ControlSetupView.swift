import SwiftUI

/// The address, and the two secrets an operator already holds.
///
/// Only the address is required. The service token is for an orchestrator that sits behind an
/// access proxy, and is left empty for one reached over a private network. The operator token
/// may be left empty too: reading needs none, and a device set up without it can watch the fleet
/// and change nothing.
///
/// There is no QR scanner yet, for the reason enrollment has none: nothing on the operator's side
/// prints a code to scan.
struct ControlSetupView: View {

    @Environment(AppEnvironment.self) private var appEnvironment

    @State private var model: ControlSetupModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if appEnvironment.controlCredentialUnavailable {
                    Label {
                        Text("controlSetup.credentialUnavailable").font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier(
                        AccessibilityIdentifier.controlSetupCredentialUnavailable.identifier
                    )
                    .accessibilityLabel(
                        AccessibilityIdentifier.controlSetupCredentialUnavailable.localizedLabel
                    )
                }

                if let model {
                    form(model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if model == nil {
                model = appEnvironment.makeControlSetupModel()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("controlSetup.title")
                .font(.largeTitle)
                .fontWeight(.semibold)
                .accessibilityIdentifier(AccessibilityIdentifier.controlSetupTitle.identifier)
                .accessibilityLabel(AccessibilityIdentifier.controlSetupTitle.localizedLabel)

            Text("controlSetup.purpose")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private func form(_ model: ControlSetupModel) -> some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: 20) {
            labelled("controlSetup.address.label", help: nil) {
                TextField("controlSetup.address.prompt", text: $model.address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(
                        AccessibilityIdentifier.controlSetupAddressField.identifier
                    )
                    .accessibilityLabel(
                        AccessibilityIdentifier.controlSetupAddressField.localizedLabel
                    )
            }
            if let message = model.addressMessage {
                messageView(message, identifier: .controlSetupAddressMessage)
            }

            labelled("controlSetup.clientId.label", help: "controlSetup.serviceToken.help") {
                // Paste-first, like the enrollment code: autocapitalisation and autocorrection
                // both mangle an opaque identifier.
                TextField("controlSetup.optional.prompt", text: $model.accessClientId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(nil)
                    .keyboardType(.asciiCapable)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(
                        AccessibilityIdentifier.controlSetupClientIdField.identifier
                    )
                    .accessibilityLabel(
                        AccessibilityIdentifier.controlSetupClientIdField.localizedLabel
                    )
            }

            labelled("controlSetup.clientSecret.label", help: nil) {
                SecureField("controlSetup.optional.prompt", text: $model.accessClientSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(nil)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(
                        AccessibilityIdentifier.controlSetupClientSecretField.identifier
                    )
                    .accessibilityLabel(
                        AccessibilityIdentifier.controlSetupClientSecretField.localizedLabel
                    )
            }
            if let message = model.serviceTokenMessage {
                messageView(message, identifier: .controlSetupServiceTokenMessage)
            }

            labelled("controlSetup.token.label", help: "controlSetup.token.help") {
                SecureField("controlSetup.optional.prompt", text: $model.operatorToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(nil)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(
                        AccessibilityIdentifier.controlSetupTokenField.identifier
                    )
                    .accessibilityLabel(
                        AccessibilityIdentifier.controlSetupTokenField.localizedLabel
                    )
            }

            if let message = model.tokenMessage {
                messageView(message, identifier: .controlSetupTokenMessage)
            }

            if let message = model.formMessage {
                messageView(message, identifier: .controlSetupFormMessage)
            }

            Button {
                Task {
                    if let credential = await model.connect() {
                        appEnvironment.finishControlSetup(
                            credential,
                            tokenVerification: model.tokenVerification
                        )
                    }
                }
            } label: {
                Text("controlSetup.connect")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isConnecting)
            .accessibilityIdentifier(AccessibilityIdentifier.controlSetupConnect.identifier)
            .accessibilityLabel(AccessibilityIdentifier.controlSetupConnect.localizedLabel)
        }
    }

    private func labelled<Field: View>(
        _ titleKey: LocalizedStringKey,
        help: LocalizedStringKey?,
        @ViewBuilder field: () -> Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleKey)
                .font(.footnote)
                .foregroundStyle(.secondary)

            field()

            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func messageView(
        _ message: ControlSetupModel.Message,
        identifier: AccessibilityIdentifier
    ) -> some View {
        Text(message.copyKey)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier.identifier)
    }
}

extension ControlSetupModel.Message {
    /// One key per case. The address cases reuse enrollment's wording: it is the same kind of
    /// value, refused for the same reasons.
    var copyKey: LocalizedStringKey {
        switch self {
        case .addressEmpty: return "enrollment.message.addressEmpty"
        case .addressInsecure: return "enrollment.message.addressInsecure"
        case .addressMalformed: return "enrollment.message.addressMalformed"
        case .addressMissingHost: return "enrollment.message.addressMissingHost"
        case .addressUserInfo: return "enrollment.message.addressUserInfo"
        case .serviceTokenIncomplete: return "controlSetup.message.serviceTokenIncomplete"
        case .accessDenied: return "controlSetup.message.accessDenied"
        case .unreachable: return "controlSetup.message.unreachable"
        case .notAnOrchestrator: return "controlSetup.message.notAnOrchestrator"
        case .operatorTokenRejected: return "controlSetup.message.operatorTokenRejected"
        case .credentialWriteFailed: return "controlSetup.message.credentialWriteFailed"
        }
    }
}
