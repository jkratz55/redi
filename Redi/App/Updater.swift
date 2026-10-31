import Observation
import Sparkle
import SwiftUI

/// Sparkle auto-updates. Inert until the build has a public EdDSA key (`REDI_SPARKLE_PUBLIC_KEY`
/// build setting → `SUPublicEDKey`), so development builds never check a feed they can't verify.
@Observable
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        // Sparkle publishes its KVO changes on the main thread.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    var isAvailable: Bool { controller != nil }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Redi").font(.largeTitle.bold())
            Text(version).foregroundStyle(.secondary).textSelection(.enabled)
            Text("A fast, native Redis client for macOS.")
                .multilineTextAlignment(.center)
            Divider().padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 6) {
                Text("Acknowledgements").font(.headline)
                Text("Sparkle — software updates. Copyright © the Sparkle Project contributors. MIT License.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Redis is a registered trademark of Redis Ltd. Redi is an independent project and isn't affiliated with Redis Ltd.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 360)
    }
}
