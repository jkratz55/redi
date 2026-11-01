import Foundation
import Observation
import RediCore
import RedisWire
import SwiftUI

@Observable
final class PubSubModel {
    var subscriptionText = ""
    var isSharded = false
    private(set) var isSubscribed = false
    private(set) var status: String?
    private(set) var revision = 0
    private(set) var totalReceived = 0
    private(set) var ratePerSecond = 0
    var isPaused = false {
        didSet { if !isPaused { refreshVisible() } }
    }
    var filter = "" {
        didSet { refreshVisible() }
    }
    var publishChannel = ""
    var publishMessage = ""
    private(set) var publishResult: String?
    private(set) var activeChannels: [(channel: String, subscribers: Int)] = []

    @ObservationIgnored private(set) var buffer = RingBuffer<PubSubMessage>(capacity: 50_000)
    /// Indices into `buffer` when a filter is active.
    @ObservationIgnored private(set) var visible: [Int]?
    @ObservationIgnored private unowned let workspace: WorkspaceModel
    @ObservationIgnored private var listener: PubSubListener?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var rateWindow: [(Date, Int)] = []

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
    }

    var rowCount: Int { visible?.count ?? buffer.count }

    func message(at row: Int) -> PubSubMessage {
        buffer[visible?[row] ?? row]
    }

    /// Parses "news, alerts.* metrics" into channels and (glob) patterns.
    private var parsedSubscriptions: (channels: [String], patterns: [String]) {
        let names = subscriptionText.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        return (names.filter { !$0.contains(where: { "*?[".contains($0) }) }, names.filter { $0.contains(where: { "*?[".contains($0) }) })
    }

    /// Shows "Subscribing…" until the server confirms. SUBSCRIBE gets no direct reply, so a refusal
    /// arrives later as a `.refused` event, which ends the subscription.
    func subscribe() async {
        guard let session = workspace.session, !isSubscribed else { return }
        let (channels, patterns) = parsedSubscriptions
        guard !channels.isEmpty || !patterns.isEmpty else { return }
        let listener = self.listener ?? PubSubListener(session: session)
        self.listener = listener
        startEvents(listener)
        isSubscribed = true
        status = String(localized: "Subscribing…")
        do {
            if isSharded {
                try await listener.subscribe(channels: [], patterns: [], sharded: channels)
            } else {
                try await listener.subscribe(channels: channels, patterns: patterns)
            }
        } catch {
            await stopListening(status: String(describing: error))
        }
    }

    func unsubscribe() async {
        await stopListening(status: nil)
    }

    /// Stops the listener and drops it: cancelling `eventTask` ends the listener's event stream for
    /// good, so the next Subscribe needs a new listener. `isSubscribed` stays set until the old
    /// listener has released its connection, so a new subscription can't start before then.
    private func stopListening(status: String?) async {
        self.status = status
        guard let listener else { return }
        await listener.stop()
        guard self.listener === listener else { return }
        self.listener = nil
        eventTask?.cancel()
        eventTask = nil
        isSubscribed = false
        ratePerSecond = 0
    }

    private func startEvents(_ listener: PubSubListener) {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            for await event in listener.events {
                guard let self else { return }
                switch event {
                case .messages(let messages): self.receive(messages)
                case .subscribed(let count): self.status = String(localized: "Subscribed (\(count))")
                case .connectionLost: self.status = String(localized: "Connection lost — reconnecting…")
                case .resubscribed: self.status = String(localized: "Reconnected and resubscribed")
                case .refused(let message): await self.stopListening(status: message)
                }
            }
        }
    }

    private func receive(_ messages: [PubSubMessage]) {
        totalReceived += messages.count
        let now = Date()
        rateWindow.append((now, messages.count))
        rateWindow.removeAll { now.timeIntervalSince($0.0) > 1 }
        ratePerSecond = rateWindow.reduce(0) { $0 + $1.1 }
        guard !isPaused else { return }
        buffer.append(contentsOf: messages)
        refreshVisible()
    }

    private func refreshVisible() {
        let query = filter.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            visible = nil
        } else {
            visible = (0..<buffer.count).filter { index in
                let message = buffer[index]
                return String(decoding: message.channel, as: UTF8.self).localizedCaseInsensitiveContains(query)
                    || String(decoding: message.payload.prefix(4096), as: UTF8.self).localizedCaseInsensitiveContains(query)
            }
        }
        revision += 1
    }

    func clear() {
        buffer.removeAll()
        totalReceived = 0
        refreshVisible()
    }

    func publish() async {
        guard let session = workspace.session, !publishChannel.isEmpty else { return }
        do {
            let reply = try await session.execute(RedisCommand(isSharded ? "SPUBLISH" : "PUBLISH", publishChannel, publishMessage))
            let count = Int(reply.int ?? 0)
            publishResult = String(AttributedString(localized: "Delivered to ^[\(count) subscriber](inflect: true)").characters)
        } catch {
            publishResult = String(describing: error)
        }
    }

    func loadActiveChannels() async {
        guard let session = workspace.session else { return }
        do {
            let channels = (try await session.execute(RedisCommand("PUBSUB", "CHANNELS"))).array?.compactMap(\.string) ?? []
            var counts: [String: Int] = [:]
            if !channels.isEmpty {
                let pairs = try await session.execute(RedisCommand("PUBSUB", ["NUMSUB"] + channels)).pairs ?? []
                for pair in pairs { if let name = pair.key.string { counts[name] = Int(pair.value.int ?? 0) } }
            }
            activeChannels = channels.sorted().map { ($0, counts[$0] ?? 0) }
        } catch {
            activeChannels = []
        }
    }
}

struct PubSubView: View {
    @Bindable var model: PubSubModel
    let isReadOnly: Bool
    @State private var isShowingChannels = false

    var body: some View {
        VStack(spacing: 0) {
            subscribeBar
            Divider()
            if model.buffer.isEmpty && !model.isSubscribed {
                ContentUnavailableView {
                    Label("Pub/Sub", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text("Subscribe to channels (or glob patterns such as news.*) to watch messages as they're published.")
                }
            } else {
                LogTableView(columns: [
                    .init(id: "time", title: String(localized: "Time"), width: 110, isMonospaced: false, isSecondary: true),
                    .init(id: "channel", title: String(localized: "Channel"), width: 180),
                    .init(id: "message", title: String(localized: "Message"), width: 400, isFlexible: true),
                ], rowCount: model.rowCount, revision: model.revision, text: { row, column in
                    let message = model.message(at: row)
                    switch column {
                    case "time": return message.receivedAt.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
                    case "channel":
                        if let pattern = message.pattern { return "\(String(decoding: message.channel, as: UTF8.self))  (\(String(decoding: pattern, as: UTF8.self)))" }
                        return String(decoding: message.channel, as: UTF8.self)
                    default: return ValueFormatter.preview(message.payload, limit: 2048)
                    }
                }, accessibilityLabel: String(localized: "Messages"))
            }
            Divider()
            publishBar
        }
    }

    private var subscribeBar: some View {
        HStack(spacing: 8) {
            TextField("Channels or patterns", text: $model.subscriptionText, prompt: Text(verbatim: "news, alerts.*"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onSubmit { Task { await model.subscribe() } }
                .disabled(model.isSubscribed)
                .accessibilityIdentifier("pubsub.subscriptions")
            Toggle("Sharded", isOn: $model.isSharded)
                .toggleStyle(.checkbox)
                .help("Use SSUBSCRIBE / SPUBLISH (Redis 7 sharded pub/sub)")
                .disabled(model.isSubscribed)
            if model.isSubscribed {
                Button("Unsubscribe") { Task { await model.unsubscribe() } }
            } else {
                Button("Subscribe") { Task { await model.subscribe() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.subscriptionText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let status = model.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("^[\(model.totalReceived) message](inflect: true) · \(model.ratePerSecond.formatted())/s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            TextField("Filter", text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
            Toggle(isOn: $model.isPaused) { Image(systemName: model.isPaused ? "play.fill" : "pause.fill") }
                .toggleStyle(.button)
                .help(model.isPaused ? "Resume" : "Pause")
                .accessibilityLabel(model.isPaused ? "Resume" : "Pause")
            Button("Clear", systemImage: "trash") { model.clear() }.labelStyle(.iconOnly)
            Button("Active Channels", systemImage: "list.bullet.rectangle") {
                isShowingChannels = true
                Task { await model.loadActiveChannels() }
            }
            .labelStyle(.iconOnly)
            .popover(isPresented: $isShowingChannels) {
                VStack(alignment: .leading) {
                    Text("Active Channels").font(.headline)
                    if model.activeChannels.isEmpty {
                        Text("No channels have subscribers.").foregroundStyle(.secondary)
                    }
                    ForEach(model.activeChannels, id: \.channel) { item in
                        HStack {
                            Text(item.channel).font(.body.monospaced())
                            Spacer()
                            Text("\(item.subscribers)").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .frame(minWidth: 260)
            }
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    private var publishBar: some View {
        HStack(spacing: 8) {
            Text("Publish").font(.callout.bold())
            TextField("Channel", text: $model.publishChannel).textFieldStyle(.roundedBorder).frame(width: 180)
                .accessibilityIdentifier("pubsub.channel")
            TextField("Message", text: $model.publishMessage).textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.publish() } }
                .accessibilityIdentifier("pubsub.message")
            Button("Publish") { Task { await model.publish() } }
                .disabled(model.publishChannel.isEmpty || isReadOnly)
            if let result = model.publishResult {
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }
}
