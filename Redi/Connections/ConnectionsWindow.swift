import RediCore
import SwiftUI
import UniformTypeIdentifiers

/// The launcher window: saved connections, most recently used first.
struct ConnectionsWindow: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var selection = Set<ConnectionProfile.ID>()
    @State private var searchText = ""
    @State private var editor: EditorRequest?
    @State private var pendingDelete: Set<ConnectionProfile.ID> = []
    @State private var isImporting = false
    @State private var importMessage: String?

    /// What the editor sheet should show.
    private struct EditorRequest: Identifiable {
        let id = UUID()
        var profile: ConnectionProfile?
        var secrets = ConnectionSecrets()
    }

    private var filtered: [ConnectionProfile] {
        let profiles = store.sortedProfiles
        guard !searchText.isEmpty else { return profiles }
        return profiles.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) || $0.address.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        content
            .frame(minWidth: 560, minHeight: 340)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Import", systemImage: "square.and.arrow.down") { isImporting = true }
                        .help("Import connections exported from Redis Insight")
                    Button("New Connection", systemImage: "plus") { editor = EditorRequest() }
                        .help("New Connection (⌘N)")
                }
            }
            .sheet(item: $editor) { request in
                ConnectionEditor(profile: request.profile, secrets: request.secrets) { profile, connect in
                    selection = [profile.id]
                    if connect { open([profile.id]) }
                }
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
                Button("Delete", role: .destructive) {
                    store.delete(ids: pendingDelete)
                    selection.subtract(pendingDelete)
                    pendingDelete = []
                }
            } message: {
                Text("Passwords and keys saved for these connections are removed from the Keychain.")
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                do {
                    let count = try store.importRedisInsight(from: url)
                    importMessage = String(localized: "Imported \(count) connections.")
                } catch {
                    importMessage = String(describing: error)
                }
            }
            .alert(importMessage ?? "", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("OK") {}
            }
            .onPasteCommand(of: [.plainText, .url]) { providers in
                paste(providers)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showNewConnection)) { _ in
                editor = EditorRequest()
            }
            .onReceive(NotificationCenter.default.publisher(for: .importConnections)) { _ in
                isImporting = true
            }
    }

    @ViewBuilder private var content: some View {
        if store.profiles.isEmpty {
            ContentUnavailableView {
                Label("No Connections", systemImage: "server.rack")
            } description: {
                Text("Add a Redis server to start browsing keys, running commands and analyzing memory. You can also paste a redis:// URL or import from Redis Insight.")
            } actions: {
                Button("New Connection…") { editor = EditorRequest() }
                    .buttonStyle(.borderedProminent)
                Button("Import from Redis Insight…") { isImporting = true }
            }
        } else {
            VStack(spacing: 0) {
                if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.orange.opacity(0.1))
                }
                List(filtered, selection: $selection) { profile in
                    ConnectionRow(profile: profile)
                }
                .contextMenu(forSelectionType: ConnectionProfile.ID.self) { ids in
                    contextMenu(for: ids)
                } primaryAction: { ids in
                    open(ids)
                }
                .onDeleteCommand { pendingDelete = selection }
                .searchable(text: $searchText, placement: .toolbar, prompt: "Filter Connections")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<ConnectionProfile.ID>) -> some View {
        Button("Connect") { open(ids) }
        if ids.count == 1, let id = ids.first, let profile = store.profile(id: id) {
            Button("Edit…") { editor = EditorRequest(profile: profile, secrets: store.secrets(for: id)) }
            Button("Duplicate") { if let copy = store.duplicate(id: id) { selection = [copy.id] } }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(profile.url, forType: .string)
            }
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = ids }
    }

    private var deleteTitle: String {
        if pendingDelete.count == 1, let profile = store.profile(id: pendingDelete.first) {
            return String(localized: "Delete “\(profile.displayName)”?")
        }
        return String(localized: "Delete \(pendingDelete.count) connections?")
    }

    private func open(_ ids: Set<ConnectionProfile.ID>) {
        for id in ids { openWindow(id: SceneID.workspace, value: id) }
    }

    /// ⌘V with a redis:// URL on the clipboard opens a pre-filled editor.
    private func paste(_ providers: [NSItemProvider]) {
        guard let text = NSPasteboard.general.string(forType: .string),
              let (profile, password) = try? ConnectionProfile.parse(url: text) else { return }
        editor = EditorRequest(profile: profile, secrets: ConnectionSecrets(password: password))
    }
}

private struct ConnectionRow: View {
    let profile: ConnectionProfile

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                if profile.colorTag != .none {
                    ColorTagDot(tag: profile.colorTag)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.displayName).font(.headline)
                    if profile.isProduction { Badge(text: "Production", color: .red) }
                    if profile.isReadOnly { Badge(text: "Read-only", color: .secondary) }
                }
                HStack(spacing: 6) {
                    Text(profile.address).font(.subheadline.monospaced())
                    if profile.tls.isEnabled { Image(systemName: "lock.fill").accessibilityLabel("TLS") }
                    if profile.ssh.isEnabled { Text(verbatim: "via \(profile.ssh.host)") }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let last = profile.lastConnectedAt {
                Text(last, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch profile.mode {
        case .standalone: "server.rack"
        case .cluster: "square.grid.3x3.topleft.filled"
        case .sentinel: "eye"
        }
    }
}

struct Badge: View {
    let text: LocalizedStringKey
    var color: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: .capsule)
    }
}
