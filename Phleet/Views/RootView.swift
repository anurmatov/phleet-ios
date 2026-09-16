import SwiftUI

/// The unenrolled root state: what the app is, and the one thing you can do next.
///
/// There is no configured server to show, because this build ships with none and persists
/// none. Every font here is a semantic text style and every element carries its identifier and
/// label from `AccessibilityIdentifier`.
struct RootView: View {

    @State private var isShowingEnrollmentPlaceholder = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
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

                Button {
                    isShowingEnrollmentPlaceholder = true
                } label: {
                    Text("root.connectFleet")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier(AccessibilityIdentifier.rootConnectFleet.identifier)
                .accessibilityLabel(AccessibilityIdentifier.rootConnectFleet.localizedLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .sheet(isPresented: $isShowingEnrollmentPlaceholder) {
            EnrollmentPlaceholderView()
        }
    }
}

#Preview {
    RootView()
}
