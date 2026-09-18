import SwiftUI

/// Two fields and one action.
///
/// **Type the origin, paste the code.** An origin is a handful of characters someone can hold in
/// their head and retype after a typo; a 43-character base64url secret under a fifteen-minute
/// TTL is not, and asking someone to type one is how enrollment fails on the third attempt with
/// the code already burned.
///
/// There is no QR scanner in this slice. It is the better end state and it needs a
/// camera-permission prompt, a usage-description string, a capture session — and, the part that
/// actually blocks it, an operator-side generator that does not exist: the server's operator path
/// prints a code to a terminal. Building the client half of a QR flow whose server half is a
/// `printf` is building half a bridge.
struct EnrollmentView: View {

    @Environment(AppEnvironment.self) private var appEnvironment

    @State private var model: EnrollmentModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if appEnvironment.wasRevoked {
                    notice(
                        key: "enrollment.revoked",
                        identifier: .enrollmentRevokedNotice,
                        symbol: "lock.slash"
                    )
                }
                if appEnvironment.credentialUnavailable {
                    notice(
                        key: "enrollment.credentialUnavailable",
                        identifier: .enrollmentCredentialUnavailable,
                        symbol: "exclamationmark.triangle"
                    )
                }

                if let model {
                    form(model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .onAppear {
            if model == nil {
                model = appEnvironment.makeEnrollmentModel()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("root.title")
                .font(.largeTitle)
                .fontWeight(.semibold)
                .accessibilityIdentifier(AccessibilityIdentifier.rootTitle.identifier)
                .accessibilityLabel(AccessibilityIdentifier.rootTitle.localizedLabel)

            Text("root.purpose")
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityIdentifier.rootPurpose.identifier)
                .accessibilityLabel(AccessibilityIdentifier.rootPurpose.localizedLabel)
        }
    }

    private func form(_ model: EnrollmentModel) -> some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: 20) {
            field(
                titleKey: "enrollment.address.label",
                promptKey: "enrollment.address.prompt",
                text: $model.address,
                identifier: .enrollmentAddressField
            ) {
                $0.textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }

            if let message = model.addressMessage {
                messageView(message, identifier: .enrollmentAddressMessage)
            }

            VStack(alignment: .leading, spacing: 4) {
                field(
                    titleKey: "enrollment.code.label",
                    promptKey: "enrollment.code.prompt",
                    text: $model.enrollmentCode,
                    identifier: .enrollmentCodeField
                ) {
                    // Paste-first. Autocapitalisation, autocorrection and a content-type guess
                    // all mangle a base64url secret.
                    $0.textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(nil)
                        .keyboardType(.asciiCapable)
                }

                Text("enrollment.code.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = model.codeMessage {
                messageView(message, identifier: .enrollmentCodeMessage)
            }
            if let message = model.formMessage {
                messageView(message, identifier: .enrollmentFormMessage)
            }

            Button {
                Task {
                    if let outcome = await model.connect() {
                        appEnvironment.finishEnrollment(outcome)
                    }
                }
            } label: {
                Text("enrollment.connect")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isConnecting)
            .accessibilityIdentifier(AccessibilityIdentifier.enrollmentConnect.identifier)
            .accessibilityLabel(AccessibilityIdentifier.enrollmentConnect.localizedLabel)
            .accessibilityHint(Text("enrollment.connect.hint"))
        }
    }

    private func field<Modified: View>(
        titleKey: LocalizedStringKey,
        promptKey: LocalizedStringKey,
        text: Binding<String>,
        identifier: AccessibilityIdentifier,
        modify: (TextField<Text>) -> Modified
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleKey)
                .font(.footnote)
                .foregroundStyle(.secondary)

            modify(TextField(promptKey, text: text))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(identifier.identifier)
                .accessibilityLabel(identifier.localizedLabel)
        }
    }

    private func notice(
        key: LocalizedStringKey,
        identifier: AccessibilityIdentifier,
        symbol: String
    ) -> some View {
        Label {
            Text(key).font(.footnote)
        } icon: {
            Image(systemName: symbol)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(identifier.identifier)
        .accessibilityLabel(identifier.localizedLabel)
    }

    private func messageView(
        _ message: EnrollmentModel.Message,
        identifier: AccessibilityIdentifier
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.copyKey)
                .font(.footnote)
            if case .deviceLimit = message {
                // Names the real resolution — the operator revokes the other device and issues a
                // fresh code — and offers no "replace it" control, because no north route can do
                // that and an unauthenticated one would be a one-request denial of service
                // against the only way in.
                Text("enrollment.message.deviceLimit.resolution")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier.identifier)
    }
}

extension EnrollmentModel.Message {
    /// One key per case — and deliberately **one** key covering every `401`. Expired, burned and
    /// unknown codes are indistinguishable by contract, and the copy says so honestly instead of
    /// guessing which.
    var copyKey: LocalizedStringKey {
        switch self {
        case .addressEmpty: return "enrollment.message.addressEmpty"
        case .addressInsecure: return "enrollment.message.addressInsecure"
        case .addressMalformed: return "enrollment.message.addressMalformed"
        case .addressMissingHost: return "enrollment.message.addressMissingHost"
        case .addressUserInfo: return "enrollment.message.addressUserInfo"
        case .codeEmpty: return "enrollment.message.codeEmpty"
        case .codeNotAccepted: return "enrollment.message.codeNotAccepted"
        case .deviceLimit: return "enrollment.message.deviceLimit"
        case .credentialUnavailable: return "enrollment.message.credentialUnavailable"
        case .credentialWriteFailed: return "enrollment.message.credentialWriteFailed"
        case .rateLimited: return "enrollment.message.rateLimited"
        case .serverUnavailable: return "enrollment.message.serverUnavailable"
        case .deviceRevoked: return "enrollment.message.deviceRevoked"
        }
    }
}
