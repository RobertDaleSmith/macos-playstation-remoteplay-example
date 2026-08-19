import AppKit
import SwiftUI

@main
struct DemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("PlayStation Remote Play Example") {
            ContentView(client: delegate.client, source: delegate.source)
                .frame(minWidth: 520, minHeight: 620)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let client = RemotePlayClient()
    let source = ExampleInputSource()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // This is the whole integration: hand the client something that implements
        // RemotePlayInputSource and it is driven for the life of every session.
        client.addInputSource(source)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Leaving without this makes the console hold the session open, and it refuses the next
        // connection until it times out on its own.
        client.disconnectBeforeQuitting()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
