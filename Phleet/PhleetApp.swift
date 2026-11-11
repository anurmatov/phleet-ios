import SwiftUI

@main
struct PhleetApp: App {

    /// Remote-notification callbacks arrive on the application delegate and nowhere else.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var appEnvironment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appEnvironment)
        }
    }
}
