import RediCore
import RedisClient
import SwiftUI

/// Root of a connection window.
struct WorkspaceWindow: View {
    let profileID: UUID?
    @Environment(ConnectionStore.self) private var store

    var body: some View {
        if let profile = store.profile(id: profileID) {
            WorkspaceView(profile: profile, secrets: store.secrets(for: profile.id)) {
                store.markConnected(id: profile.id)
            }
            .id(profile.id)
        } else {
            ContentUnavailableView("Connection Unavailable", systemImage: "server.rack",
                                   description: Text("This connection was deleted."))
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}

private struct WorkspaceView: View {
    @State private var model: WorkspaceModel

    init(profile: ConnectionProfile, secrets: ConnectionSecrets, onConnected: @escaping () -> Void) {
        _model = State(initialValue: WorkspaceModel(profile: profile, secrets: secrets, onConnected: onConnected))
    }

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(selection: $model.selection, isCluster: model.isCluster)
        } detail: {
            VSplitView {
                VStack(spacing: 0) {
                    if let notice = model.notice {
                        NoticeBar(text: notice) { model.dismissNotice() }
                    }
                    WorkspaceDetail(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: 240, maxHeight: .infinity)
                if model.isBottomPanelVisible {
                    BottomPanel(model: model)
                        .frame(minHeight: 140, idealHeight: 260, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(model.profile.displayName)
        .navigationSubtitle(model.subtitle)
        .toolbar { toolbar }
        .focusedSceneValue(\.workspace, model)
        .frame(minWidth: 900, minHeight: 560)
        .task { await model.connect() }
        .onDisappear {
            let model = model
            Task { await model.disconnect() }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ConnectionStatusIndicator(status: model.status)
            if model.profile.isProduction {
                Badge(text: "Production", color: .red)
                    .help("This connection is marked as production.")
            }
            if model.profile.isReadOnly {
                Badge(text: "Read-only", color: .secondary)
                    .help("Write commands are blocked for this connection.")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isConnected, !model.isCluster {
                Menu {
                    ForEach(0..<model.databaseCount, id: \.self) { index in
                        Button {
                            Task { await model.selectDatabase(index) }
                        } label: {
                            if index == model.database { Label("db\(index)", systemImage: "checkmark") } else { Text(verbatim: "db\(index)") }
                        }
                    }
                } label: {
                    Label("db\(model.database)", systemImage: "cylinder.split.1x2")
                        .labelStyle(.titleAndIcon)
                }
                .help("Database")
                .accessibilityIdentifier("workspace.database")
            }
            Button("Bottom Panel", systemImage: "rectangle.bottomthird.inset.filled") {
                model.isBottomPanelVisible.toggle()
            }
            .help(model.isBottomPanelVisible ? "Hide Bottom Panel (⌘`)" : "Show Bottom Panel (⌘`)")
        }
    }
}

// MARK: - Sidebar

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case keys, pubSub, workbench, overview, slowLog, analysis, nodes

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .keys: "Keys"
        case .pubSub: "Pub/Sub"
        case .workbench: "Workbench"
        case .overview: "Overview"
        case .slowLog: "Slow Log"
        case .analysis: "Database Analysis"
        case .nodes: "Cluster Nodes"
        }
    }

    var systemImage: String {
        switch self {
        case .keys: "key"
        case .pubSub: "dot.radiowaves.left.and.right"
        case .workbench: "chevron.left.forwardslash.chevron.right"
        case .overview: "gauge.with.dots.needle.33percent"
        case .slowLog: "tortoise"
        case .analysis: "chart.pie"
        case .nodes: "square.grid.3x3.topleft.filled"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .keys: "1"
        case .pubSub: "2"
        case .workbench: "3"
        case .overview: "4"
        case .slowLog: "5"
        case .analysis: "6"
        case .nodes: "7"
        }
    }
}

private struct WorkspaceSidebar: View {
    @Binding var selection: SidebarItem?
    let isCluster: Bool

    var body: some View {
        List(selection: $selection) {
            Section("Browse") {
                row(.keys)
                row(.pubSub)
            }
            Section("Develop") {
                row(.workbench)
            }
            Section("Analyze") {
                row(.overview)
                row(.slowLog)
                row(.analysis)
                if isCluster { row(.nodes) }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
    }

    private func row(_ item: SidebarItem) -> some View {
        Label { Text(item.title) } icon: { Image(systemName: item.systemImage) }
            .tag(item)
    }
}

// MARK: - Detail

private struct WorkspaceDetail: View {
    let model: WorkspaceModel

    var body: some View {
        switch model.status {
        case .disconnected, .connecting:
            ProgressView("Connecting to \(model.profile.address)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Connect", systemImage: "bolt.horizontal.circle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.connect() } }
                    .keyboardShortcut(.defaultAction)
            }
        case .connected:
            feature(model.selection ?? .keys)
        }
    }

    @ViewBuilder
    private func feature(_ item: SidebarItem) -> some View {
        switch item {
        case .keys:
            BrowserView(model: model.browser)
        case .nodes:
            NodesView(model: model.nodes)
        case .workbench:
            WorkbenchView(model: model.workbench, workspace: model)
        case .pubSub:
            PubSubView(model: model.pubSub, isReadOnly: model.profile.isReadOnly)
        case .overview:
            OverviewView(model: model.overview, workspace: model)
        case .slowLog:
            SlowLogView(model: model.slowLog, isReadOnly: model.profile.isReadOnly)
        case .analysis:
            DatabaseAnalysisView(model: model.analysis, workspace: model)
        }
    }
}

struct FeaturePlaceholder: View {
    let title: LocalizedStringResource
    let systemImage: String

    var body: some View {
        ContentUnavailableView {
            Label { Text(title) } icon: { Image(systemName: systemImage) }
        } description: {
            Text("Not available yet.")
        }
    }
}

private struct NoticeBar: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Label(text, systemImage: "info.circle.fill")
                .font(.callout)
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.blue.opacity(0.12))
    }
}

private struct ConnectionStatusIndicator: View {
    let status: WorkspaceModel.Status

    var body: some View {
        Image(systemName: "circle.fill")
            .foregroundStyle(color)
            .imageScale(.small)
            .help(label)
            .accessibilityLabel(label)
    }

    private var label: String {
        switch status {
        case .disconnected: String(localized: "Disconnected")
        case .connecting: String(localized: "Connecting")
        case .connected: String(localized: "Connected")
        case .failed: String(localized: "Connection failed")
        }
    }

    private var color: Color {
        switch status {
        case .disconnected: .secondary
        case .connecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }
}
