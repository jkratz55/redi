import SwiftUI

/// Menu bar commands. Workspace actions route to the key window's `WorkspaceModel` through
/// `FocusedValues`, so they're disabled automatically when no workspace is frontmost.
struct RediCommands: Commands {
    let updater: Updater
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.workspace) private var workspace

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Redi") { openWindow(id: SceneID.about) }
            if updater.isAvailable {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Connection…") {
                openWindow(id: SceneID.connections)
                NotificationCenter.default.post(name: .showNewConnection, object: nil)
            }
            .keyboardShortcut("n")

            Button("Show Connections") {
                openWindow(id: SceneID.connections)
            }
            .keyboardShortcut("0", modifiers: [.command, .shift])

            Divider()

            Button("Import Connections from Redis Insight…") {
                openWindow(id: SceneID.connections)
                NotificationCenter.default.post(name: .importConnections, object: nil)
            }
        }

        CommandGroup(after: .sidebar) {
            Button(workspace?.isBottomPanelVisible == true ? "Hide Bottom Panel" : "Show Bottom Panel") {
                workspace?.isBottomPanelVisible.toggle()
            }
            .keyboardShortcut("`")
            .disabled(workspace == nil)

            Button("Show CLI") {
                workspace?.bottomPanelTab = .cli
                workspace?.isBottomPanelVisible = true
            }
            .keyboardShortcut("`", modifiers: [.command, .shift])
            .disabled(workspace == nil)

            Divider()
        }

        CommandMenu("Navigate") {
            Button("Go to Key…") {
                workspace?.selection = .keys
                NotificationCenter.default.post(name: .focusKeyFilter, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(workspace == nil)

            Divider()

            ForEach(SidebarItem.allCases) { item in
                Button {
                    workspace?.selection = item
                } label: {
                    Text(item.title)
                }
                .keyboardShortcut(item.shortcut, modifiers: .command)
                .disabled(workspace == nil || (item == .nodes && workspace?.isCluster != true))
            }
        }
    }
}

extension FocusedValues {
    @Entry var workspace: WorkspaceModel?
}

extension Notification.Name {
    static let showNewConnection = Notification.Name("com.github.jkratz55.Redi.showNewConnection")
    static let importConnections = Notification.Name("com.github.jkratz55.Redi.importConnections")
}
