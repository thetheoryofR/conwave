import SwiftUI

@main
struct ConwaveApp: App {
    @StateObject private var cloudKit = CloudKitManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cloudKit)
        }
        // Receives CKShare accept URLs when the user taps an invite link
        // (universal link scheme is derived from the container ID)
        .handlesExternalEvents(matching: Set(["*"]))
    }
}
