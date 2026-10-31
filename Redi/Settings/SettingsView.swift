import SwiftUI

/// `UserDefaults` keys for app settings.
enum SettingsKey {
    static let confirmDangerousCommands = "general.confirmDangerousCommands"
    static let undoDeleteSizeLimitKB = "general.undoDeleteSizeLimitKB"
    static let keyDelimiter = "browser.keyDelimiter"
    static let scanCount = "browser.scanCount"
    static let defaultBrowserLayout = "browser.defaultLayout"
}

enum BrowserLayout: String, CaseIterable, Identifiable {
    case list, tree
    var id: Self { self }
}

struct SettingsView: View {
    let updater: Updater

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView(updater: updater)
            }
            Tab("Browser", systemImage: "key") {
                BrowserSettingsView()
            }
        }
        .frame(width: 480)
        .scenePadding()
    }
}

private struct GeneralSettingsView: View {
    @Bindable var updater: Updater
    @AppStorage(SettingsKey.confirmDangerousCommands) private var confirmDangerousCommands = true
    @AppStorage(SettingsKey.undoDeleteSizeLimitKB) private var undoDeleteSizeLimitKB = 1024

    var body: some View {
        Form {
            Toggle("Confirm dangerous commands", isOn: $confirmDangerousCommands)
            Text("Ask before running commands such as FLUSHALL, FLUSHDB, KEYS and SHUTDOWN.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Undo key deletion up to", selection: $undoDeleteSizeLimitKB) {
                Text("Off").tag(0)
                Text("256 KB").tag(256)
                Text("1 MB").tag(1024)
                Text("10 MB").tag(10_240)
            }
            if updater.isAvailable {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
            }
        }
    }
}

private struct BrowserSettingsView: View {
    @AppStorage(SettingsKey.keyDelimiter) private var keyDelimiter = ":"
    @AppStorage(SettingsKey.scanCount) private var scanCount = 500
    @AppStorage(SettingsKey.defaultBrowserLayout) private var layout = BrowserLayout.tree

    var body: some View {
        Form {
            TextField("Namespace delimiter", text: $keyDelimiter)
                .frame(maxWidth: 220)
            Picker("Keys per scan", selection: $scanCount) {
                ForEach([100, 250, 500, 1_000, 5_000, 10_000], id: \.self) { count in
                    Text(count, format: .number).tag(count)
                }
            }
            Picker("Default layout", selection: $layout) {
                Text("Tree").tag(BrowserLayout.tree)
                Text("List").tag(BrowserLayout.list)
            }
            .pickerStyle(.radioGroup)
        }
    }
}
