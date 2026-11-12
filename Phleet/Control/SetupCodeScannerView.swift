import AVFoundation
import SwiftUI
import VisionKit

/// Whether this device can scan right now, and if not, why.
enum SetupCodeScanAvailability: Equatable, Sendable {
    case available
    /// No usable camera: a simulator, or a device the scanner does not support.
    case unsupported
    /// The camera exists and this app is not allowed to use it.
    case denied
}

/// The camera, looking for one QR code.
///
/// A sheet with a single purpose: it hands back the first QR code's text and nothing else. What
/// that text means is not decided here — `SetupModel.apply(scanned:)` reads it, and reads
/// it as untrusted input.
struct SetupCodeScannerSheet: View {

    let scanned: (String) -> Void
    let cancel: () -> Void

    @State private var availability: SetupCodeScanAvailability?

    var body: some View {
        NavigationStack {
            Group {
                switch availability {
                case .available?:
                    SetupCodeScannerView(scanned: scanned)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityIdentifier(AccessibilityIdentifier.scannerCamera.identifier)
                        .accessibilityLabel(AccessibilityIdentifier.scannerCamera.localizedLabel)
                case .unsupported?:
                    unavailable("scanner.unsupported.title", "scanner.unsupported.description")
                case .denied?:
                    unavailable("scanner.denied.title", "scanner.denied.description")
                case nil:
                    ProgressView()
                }
            }
            .navigationTitle(Text("scanner.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        cancel()
                    } label: {
                        Text("scanner.cancel")
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.scannerCancel.identifier)
                    .accessibilityLabel(AccessibilityIdentifier.scannerCancel.localizedLabel)
                }
            }
            .task {
                availability = await Self.resolveAvailability()
            }
        }
    }

    private func unavailable(
        _ titleKey: LocalizedStringKey,
        _ descriptionKey: LocalizedStringKey
    ) -> some View {
        ContentUnavailableView {
            Label {
                Text(titleKey)
            } icon: {
                Image(systemName: "qrcode.viewfinder")
            }
        } description: {
            Text(descriptionKey)
        }
        .accessibilityIdentifier(AccessibilityIdentifier.scannerUnavailable.identifier)
    }

    /// Asks for the camera only when there is one to ask for, and only when the sheet is open:
    /// the permission prompt appears in answer to a tap on "scan", never at launch.
    private static func resolveAvailability() async -> SetupCodeScanAvailability {
        guard DataScannerViewController.isSupported else { return .unsupported }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .available
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video) ? .available : .denied
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }
}

/// The system data scanner, restricted to QR codes, reporting the first one it sees.
struct SetupCodeScannerView: UIViewControllerRepresentable {

    let scanned: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(scanned: scanned)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(
        _ scanner: DataScannerViewController,
        coordinator: Coordinator
    ) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {

        private let scanned: (String) -> Void
        private var hasReported = false

        init(scanned: @escaping (String) -> Void) {
            self.scanned = scanned
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            // Once. The scanner keeps seeing the same code on every frame, and the sheet is on
            // its way out after the first.
            guard !hasReported else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    hasReported = true
                    dataScanner.stopScanning()
                    scanned(payload)
                    return
                }
            }
        }
    }
}
