import SwiftUI
import AppKit

@main
struct WhispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("Whisp", id: "main") {
            ContentView()
        }.defaultSize(width: 1200, height: 820).windowStyle(.hiddenTitleBar)
            .commands { AboutCommands() }
        Settings { AppSettingsView() }
        Window("Whisp Logs", id: "logs") { LogsView() }
            .defaultSize(width: 960, height: 600)
        Window("About Whisp", id: "about") {
            AboutView().frame(width: 560, height: 520).preferredColorScheme(.dark)
        }.windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        Workspace.shared.close()
        MCPAccess.shared.shutdown()
    }
}
