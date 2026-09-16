import SwiftUI

@main
struct PhleetApp: App {

    @State private var appEnvironment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appEnvironment)
        }
    }
}
