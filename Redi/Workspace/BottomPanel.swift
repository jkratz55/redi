import SwiftUI

enum BottomPanelTab: String, CaseIterable, Identifiable {
    case cli, commandHelper, profiler

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .cli: "CLI"
        case .commandHelper: "Command Helper"
        case .profiler: "Profiler"
        }
    }

    var systemImage: String {
        switch self {
        case .cli: "terminal"
        case .commandHelper: "book"
        case .profiler: "waveform.path.ecg"
        }
    }
}

/// The resizable drawer under the detail area, like Xcode's debug area. Hosts the CLI, the
/// Command Helper and the Profiler.
struct BottomPanel: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Panel", selection: $model.bottomPanelTab) {
                    ForEach(BottomPanelTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Close", systemImage: "xmark") { model.isBottomPanelVisible = false }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Hide Bottom Panel (⌘`)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }

    @ViewBuilder private var content: some View {
        if model.isConnected {
            switch model.bottomPanelTab {
            case .cli: CLIView(model: model.cli, workspace: model)
            case .commandHelper: CommandHelperView(workspace: model)
            case .profiler: ProfilerView(model: model.profiler, isCluster: model.isCluster)
            }
        } else {
            ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle")
        }
    }
}
