import SwiftUI

@main
struct AstroTonightApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        #endif
    }
}
