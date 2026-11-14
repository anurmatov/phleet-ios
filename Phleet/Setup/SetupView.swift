import SwiftUI
import UIKit

/// The one setup step: scan the dashboard's code, check the address, connect.
///
/// It signs the phone in for the Fleet, Runs and Chat tabs at once. Scanning fills in nothing to
/// type and connects to nothing: the address the code named is on screen to be checked, and
/// connecting is a separate tap.
struct SetupView: View {

    @Environment(AppEnvironment.self) private var appEnvironment

    @State private var model: SetupModel?
    @State private var isScanning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let notice = appEnvironment.signedOutNotice {
                    noticeView(notice)
                }

                if let model {
                    content(model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .sheet(isPresented: $isScanning) {
            SetupCodeScannerSheet(
                scanned: { text in
                    model?.apply(scanned: text)
                    isScanning = false
                },
                cancel: { isScanning = false }
            )
        }
        .onAppear {
            if model == nil {
                model = appEnvironment.makeSetupModel(deviceName: UIDevice.current.model)
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

    private func content(_ model: SetupModel) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("setup.steps")
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            scanButton(model)

            pasteButton(model)

            if let code = model.code {
                scanned(code)
                connectButton(model)
            }

            if let message = model.message {
                Text(message.copyKey)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(AccessibilityIdentifier.setupMessage.identifier)
            }
        }
    }

    @ViewBuilder
    private func scanButton(_ model: SetupModel) -> some View {
        let button = Button {
            if let scripted = appEnvironment.scriptedSetupCode {
                // The scripted backend stands in for the camera, which a simulator lacks.
                model.apply(scanned: scripted)
            } else {
                isScanning = true
            }
        } label: {
            Label {
                Text(Self.scanKey(hasCode: model.code != nil))
            } icon: {
                Image(systemName: "qrcode.viewfinder")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(model.isConnecting)
        .accessibilityIdentifier(AccessibilityIdentifier.setupScan.identifier)
        .accessibilityLabel(AccessibilityIdentifier.setupScan.localizedLabel)

        // The first step is the prominent one until there is a code; then connecting is.
        if model.code == nil {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    /// The same setup code as text, for a phone that cannot point its camera at it: the code
    /// read by another device, or copied from the dashboard. It is read exactly as a scanned one
    /// is — shown, checked, and connected to only on a separate tap.
    ///
    /// The system's own paste button, so the clipboard is read because the person tapped it and
    /// no permission prompt interrupts.
    private func pasteButton(_ model: SetupModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in
                    model.apply(scanned: text)
                }
            }
            .disabled(model.isConnecting)
            .accessibilityIdentifier(AccessibilityIdentifier.setupPaste.identifier)
            .accessibilityLabel(AccessibilityIdentifier.setupPaste.localizedLabel)

            Text("setup.paste.help")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the code says, for a person to check before anything is sent to it.
    private func scanned(_ code: SetupCode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("setup.scanned.caption")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(verbatim: code.displayName)
                .font(.title3)
                .fontWeight(.semibold)
            Text(Self.routeKey(throughProxy: code.serviceToken != nil))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityIdentifier.setupScanned.identifier)
    }

    private func connectButton(_ model: SetupModel) -> some View {
        Button {
            Task {
                if let outcome = await model.connect() {
                    appEnvironment.finishSetup(outcome)
                }
            }
        } label: {
            HStack(spacing: 8) {
                if model.isConnecting {
                    ProgressView()
                }
                Text("setup.connect")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.isConnecting)
        .accessibilityIdentifier(AccessibilityIdentifier.setupConnect.identifier)
        .accessibilityLabel(AccessibilityIdentifier.setupConnect.localizedLabel)
    }

    // Typed explicitly so each is looked up in the catalog rather than shown as its own key: a
    // conditional between two literals would otherwise be read as a plain `String`.
    private static func scanKey(hasCode: Bool) -> LocalizedStringKey {
        hasCode ? "setup.scanAgain" : "setup.scan"
    }

    private static func routeKey(throughProxy: Bool) -> LocalizedStringKey {
        throughProxy ? "setup.scanned.proxy" : "setup.scanned.direct"
    }

    private func noticeView(_ notice: AppEnvironment.SignedOutNotice) -> some View {
        Label {
            Text(notice.copyKey).font(.footnote)
        } icon: {
            Image(systemName: notice.symbolName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityIdentifier.setupNotice.identifier)
    }
}

extension AppEnvironment.SignedOutNotice {

    var copyKey: LocalizedStringKey {
        switch self {
        case .revoked: return "setup.notice.revoked"
        case .credentialUnavailable: return "setup.notice.credentialUnavailable"
        case .serverNotTold: return "setup.notice.serverNotTold"
        }
    }

    var symbolName: String {
        switch self {
        case .revoked: return "lock.slash"
        case .credentialUnavailable: return "exclamationmark.triangle"
        case .serverNotTold: return "exclamationmark.circle"
        }
    }
}

extension SetupModel.Message {
    /// One key per case. Every `401` from registering is one message: the orchestrator answers a
    /// used, an expired and an unknown code the same way on purpose, and the copy does not guess.
    var copyKey: LocalizedStringKey {
        switch self {
        case .notASetupCode: return "setup.message.notASetupCode"
        case .olderDashboard: return "setup.message.olderDashboard"
        case .newerFormat: return "setup.message.newerFormat"
        case .incomplete: return "setup.message.incomplete"
        case .insecureAddress: return "setup.message.insecureAddress"
        case .invalidAddress: return "setup.message.invalidAddress"
        case .codeNotAccepted: return "setup.message.codeNotAccepted"
        case .deviceLimit: return "setup.message.deviceLimit"
        case .accessDenied: return "setup.message.accessDenied"
        case .unreachable: return "setup.message.unreachable"
        case .rateLimited: return "setup.message.rateLimited"
        case .serverTooOld: return "setup.message.serverTooOld"
        case .serverUnavailable: return "setup.message.serverUnavailable"
        case .notAFleet: return "setup.message.notAFleet"
        case .credentialWriteFailed: return "setup.message.credentialWriteFailed"
        case .signInRefused: return "setup.message.signInRefused"
        }
    }
}
