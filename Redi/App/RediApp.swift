import AppKit
import RedisClient
import SwiftUI

@main
struct RediApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ConnectionStore()
    @State private var updater = Updater()

    var body: some Scene {
        // The launcher: saved connections. Opening one creates a workspace window, and macOS window
        // tabbing can merge workspaces into tabs.
        Window("Connections", id: SceneID.connections) {
            ConnectionsWindow()
                .environment(store)
        }
        .defaultSize(width: 760, height: 480)
        .windowResizability(.contentMinSize)

        WindowGroup("Connection", id: SceneID.workspace, for: UUID.self) { $profileID in
            WorkspaceWindow(profileID: profileID)
                .environment(store)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { RediCommands(updater: updater) }

        Window("About Redi", id: SceneID.about) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(updater: updater)
        }
    }
}

enum SceneID {
    static let connections = "connections"
    static let workspace = "workspace"
    static let about = "about"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // No ssh process may outlive the app.
        SSHTunnel.closeAll()
    }
}
