import SwiftUI

/// States plainly that enrollment has not shipped yet.
///
/// This is deliberately not an error presentation. Nothing failed and nothing was attempted —
/// the feature is not here yet, and the screen should read that way.
///
/// The unavailability message is exposed as a single accessibility element carrying the label
/// from `AccessibilityIdentifier`, so assistive technology reads one coherent sentence instead
/// of three fragments, and the UI test has one stable element to find.
struct EnrollmentPlaceholderView: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            ContentUnavailableView {
                Label("enrollment.placeholder.title", systemImage: "link.badge.plus")
            } description: {
                Text("enrollment.placeholder.body")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(AccessibilityIdentifier.enrollmentPlaceholderBody.identifier)
            .accessibilityLabel(AccessibilityIdentifier.enrollmentPlaceholderBody.localizedLabel)

            Button {
                dismiss()
            } label: {
                Text("enrollment.placeholder.dismiss")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier(AccessibilityIdentifier.enrollmentPlaceholderDismiss.identifier)
            .accessibilityLabel(AccessibilityIdentifier.enrollmentPlaceholderDismiss.localizedLabel)
        }
        .padding()
    }
}

#Preview {
    EnrollmentPlaceholderView()
}
