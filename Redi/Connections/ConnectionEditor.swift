import RediCore
import RedisClient
import SwiftUI
import UniformTypeIdentifiers

/// Create or edit a connection profile.
struct ConnectionEditor: View {
    /// Called after saving, with the saved profile and whether to connect immediately.
    var onSave: (ConnectionProfile, _ connect: Bool) -> Void

    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ConnectionProfile
    @State private var secrets: ConnectionSecrets
    @State private var urlText = ""
    @State private var urlError: String?
    @State private var testState: TestState = .idle
    @State private var importTarget: FileTarget?
    @State private var importProblem: ImportProblem?
    @State private var discoveredMasters: [SentinelMaster] = []
    @State private var discoveryError: String?
    @State private var additionalSentinelsText: String
    @State private var delimiterText: String
    private let isNew: Bool

    private enum TestState: Equatable {
        case idle, testing, succeeded(String), failed(String)
    }

    enum FileTarget: Identifiable {
        case caCertificate, clientCertificate, clientKey, sshKey
        var id: Self { self }
    }

    /// A certificate or key file that couldn't be used, with the Terminal commands that convert it.
    struct ImportProblem: Equatable {
        var message: String
        var commands: String
    }

    init(profile: ConnectionProfile? = nil, secrets: ConnectionSecrets = ConnectionSecrets(),
         onSave: @escaping (ConnectionProfile, Bool) -> Void) {
        isNew = profile == nil
        let initial = profile ?? ConnectionProfile(name: "")
        _profile = State(initialValue: initial)
        _secrets = State(initialValue: secrets)
        _additionalSentinelsText = State(initialValue: initial.sentinel.additionalSentinels.joined(separator: ", "))
        _delimiterText = State(initialValue: initial.keyDelimiter ?? "")
        self.onSave = onSave
    }

    var body: some View {
        Form {
            urlSection
            generalSection
            if profile.mode == .sentinel { sentinelSection }
            authenticationSection
            tlsSection
            sshSection
            advancedSection
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .frame(minHeight: 420, idealHeight: 640)
        .safeAreaInset(edge: .bottom) { footer }
        .fileImporter(isPresented: Binding(get: { importTarget != nil }, set: { if !$0 { importTarget = nil } }),
                      allowedContentTypes: [.data, .item]) { result in
            handleImport(result)
        }
    }

    // MARK: - Sections

    private var urlSection: some View {
        Section {
            HStack {
                TextField("Connection URL", text: $urlText, prompt: Text(verbatim: "redis://user:password@host:6379/0"))
                    .accessibilityIdentifier("connection.url")
                    .onSubmit(applyURL)
                Button("Apply", action: applyURL)
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let urlError {
                Text(urlError).font(.caption).foregroundStyle(.red)
            }
        } footer: {
            Text("Paste a redis:// or rediss:// URL to fill in the details below.")
        }
    }

    private var generalSection: some View {
        Section("General") {
            TextField("Name", text: $profile.name, prompt: Text(profile.address))
                .accessibilityIdentifier("connection.name")
            Picker("Color", selection: $profile.colorTag) {
                ForEach(ConnectionProfile.ColorTag.allCases, id: \.self) { tag in
                    Label { Text(tag.title) } icon: { ColorTagDot(tag: tag) }.tag(tag)
                }
            }
            Picker("Type", selection: $profile.mode) {
                Text("Standalone").tag(ConnectionProfile.Mode.standalone)
                Text("Cluster").tag(ConnectionProfile.Mode.cluster)
                Text("Sentinel").tag(ConnectionProfile.Mode.sentinel)
            }
            .pickerStyle(.segmented)
            TextField(profile.mode == .sentinel ? "Sentinel Host" : "Host", text: $profile.host)
                .accessibilityIdentifier("connection.host")
            TextField(profile.mode == .sentinel ? "Sentinel Port" : "Port", value: $profile.port, format: .number.grouping(.never))
                .accessibilityIdentifier("connection.port")
        }
    }

    private var sentinelSection: some View {
        Section {
            HStack {
                TextField("Master Name", text: $profile.sentinel.masterName, prompt: Text(verbatim: "mymaster"))
                Menu("Discover") {
                    if discoveredMasters.isEmpty {
                        Text(discoveryError ?? "No masters found")
                    }
                    ForEach(discoveredMasters) { master in
                        Button("\(master.name) — \(master.endpoint.description)") { profile.sentinel.masterName = master.name }
                    }
                }
                .fixedSize()
                .simultaneousGesture(TapGesture().onEnded { Task { await discoverMasters() } })
            }
            TextField("Other Sentinels", text: $additionalSentinelsText, prompt: Text(verbatim: "host2:26379, host3:26379"))
            TextField("Sentinel Username", text: $profile.sentinel.username, prompt: Text("Optional"))
            SecureField("Sentinel Password", text: secretBinding(.sentinelPassword), prompt: Text("Optional"))
        } header: {
            Text("Sentinel")
        } footer: {
            Text("The credentials below under Authentication are used for the primary and replicas.")
        }
    }

    private var authenticationSection: some View {
        Section("Authentication") {
            TextField("Username", text: $profile.username, prompt: Text(verbatim: "default"))
                .accessibilityIdentifier("connection.username")
            SecureField("Password", text: secretBinding(.password))
                .accessibilityIdentifier("connection.password")
        }
    }

    private var tlsSection: some View {
        Section {
            Toggle("Use TLS", isOn: $profile.tls.isEnabled)
            if profile.tls.isEnabled {
                TextField("Server Name (SNI)", text: $profile.tls.serverName, prompt: Text(profile.host))
                FileRow(title: "CA Certificate", fileName: profile.tls.caCertificateName, placeholder: "System trust store") {
                    importTarget = .caCertificate
                } onClear: {
                    profile.tls.caCertificatePEM = nil
                    profile.tls.caCertificateName = nil
                }
                FileRow(title: "Client Certificate", fileName: profile.tls.clientCertificateName, placeholder: "None") {
                    importTarget = .clientCertificate
                } onClear: {
                    profile.tls.clientCertificatePEM = nil
                    profile.tls.clientCertificateName = nil
                }
                FileRow(title: "Client Key", fileName: profile.tls.clientKeyName, placeholder: "None") {
                    importTarget = .clientKey
                } onClear: {
                    profile.tls.clientKeyName = nil
                    secrets.tlsClientKey = nil
                }
                Toggle("Verify server certificate", isOn: $profile.tls.verifiesCertificate)
                Toggle("Verify hostname", isOn: $profile.tls.verifiesHostname)
                    .disabled(!profile.tls.verifiesCertificate)
            }
        } header: {
            Text("TLS")
        } footer: {
            if let importProblem, profile.tls.isEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Label(importProblem.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(verbatim: importProblem.commands)
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .textSelection(.enabled)
            }
        }
    }

    private var sshSection: some View {
        Section("SSH Tunnel") {
            Toggle("Connect through SSH", isOn: $profile.ssh.isEnabled)
            if profile.ssh.isEnabled {
                TextField("SSH Host", text: $profile.ssh.host, prompt: Text(verbatim: "bastion.example.com"))
                TextField("SSH Port", value: $profile.ssh.port, format: .number.grouping(.never))
                TextField("SSH User", text: $profile.ssh.username, prompt: Text("From ~/.ssh/config"))
                Picker("Authentication", selection: $profile.ssh.authentication) {
                    Text("SSH Agent / Config").tag(ConnectionProfile.SSH.Authentication.agent)
                    Text("Private Key").tag(ConnectionProfile.SSH.Authentication.privateKey)
                    Text("Password").tag(ConnectionProfile.SSH.Authentication.password)
                }
                switch profile.ssh.authentication {
                case .agent:
                    EmptyView()
                case .privateKey:
                    FileRow(title: "Private Key", fileName: profile.ssh.privateKeyPath.isEmpty ? nil : (profile.ssh.privateKeyPath as NSString).abbreviatingWithTildeInPath,
                            placeholder: "None") {
                        importTarget = .sshKey
                    } onClear: {
                        profile.ssh.privateKeyPath = ""
                    }
                    SecureField("Passphrase", text: secretBinding(.sshSecret), prompt: Text("Optional"))
                case .password:
                    SecureField("SSH Password", text: secretBinding(.sshSecret))
                }
            }
        }
    }

    private var advancedSection: some View {
        Section("Advanced") {
            if profile.mode != .cluster {
                Stepper(value: $profile.database, in: 0...255) {
                    LabeledContent("Database", value: "db\(profile.database)")
                }
            }
            Stepper(value: $profile.connectTimeoutSeconds, in: 1...120) {
                LabeledContent("Connect Timeout", value: "\(profile.connectTimeoutSeconds) s")
            }
            TextField("Key Delimiter", text: $delimiterText, prompt: Text("Use app setting"))
            Toggle("Read-only (block write commands)", isOn: $profile.isReadOnly)
            Toggle("Production (highlight this connection)", isOn: $profile.isProduction)
            Toggle("Force RESP2", isOn: $profile.forcesRESP2)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                testResult
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Test Connection") { Task { await test() } }
                    .disabled(testState == .testing || profile.host.isEmpty)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Save & Connect" : "Save") { save(connect: isNew) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(profile.host.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("connection.save")
            }
            .padding(12)
        }
        .background(.bar)
    }

    @ViewBuilder private var testResult: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
            }
        case .succeeded(let summary):
            Label(summary, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .help(message)
        }
    }

    // MARK: - Actions

    private func secretBinding(_ kind: SecretKind) -> Binding<String> {
        Binding(get: { secrets[kind] ?? "" }, set: { secrets[kind] = $0 })
    }

    private func normalized() -> ConnectionProfile {
        var result = profile
        result.host = result.host.trimmingCharacters(in: .whitespaces)
        result.sentinel.additionalSentinels = additionalSentinelsText.split(whereSeparator: { $0 == "," || $0 == " " })
            .map(String.init).filter { !$0.isEmpty }
        result.keyDelimiter = delimiterText.isEmpty ? nil : delimiterText
        return result
    }

    private func applyURL() {
        do {
            let (parsed, password) = try ConnectionProfile.parse(url: urlText)
            profile.host = parsed.host
            profile.port = parsed.port
            profile.username = parsed.username
            profile.database = parsed.database
            profile.tls.isEnabled = parsed.tls.isEnabled
            if let password { secrets.password = password }
            if profile.name.isEmpty { profile.name = parsed.name }
            urlError = nil
            urlText = ""
        } catch {
            urlError = error.description
        }
    }

    private func handleImport(_ result: Result<URL, any Error>) {
        guard let target = importTarget else { return }
        importTarget = nil
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if target == .sshKey {
            profile.ssh.privateKeyPath = url.path
            return
        }
        importProblem = nil
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importProblem = Self.notPEMProblem(file: url, target: target)
            return
        }
        switch target {
        case .caCertificate:
            profile.tls.caCertificatePEM = text
            profile.tls.caCertificateName = url.lastPathComponent
        case .clientCertificate:
            profile.tls.clientCertificatePEM = text
            profile.tls.clientCertificateName = url.lastPathComponent
        case .clientKey:
            secrets.tlsClientKey = text
            profile.tls.clientKeyName = url.lastPathComponent
        case .sshKey:
            break
        }
    }

    /// Certificates and keys are kept as PEM text, so a binary file (PKCS#12 or DER) is refused with
    /// the commands that convert it. They call macOS's own `/usr/bin/openssl` (LibreSSL), which reads
    /// old and new PKCS#12 encryption alike; Homebrew's OpenSSL 3 refuses older files without `-legacy`.
    static func notPEMProblem(file: URL, target: FileTarget) -> ImportProblem {
        let name = file.lastPathComponent
        let stem = file.deletingPathExtension().lastPathComponent
        let input = shellQuoted(name)
        func output(_ suffix: String) -> String { shellQuoted(stem + suffix) }
        let cd = "cd " + shellQuoted(file.deletingLastPathComponent().path)
        let openssl = "/usr/bin/openssl"
        let message: String
        let commands: [String]
        if ["p12", "pfx"].contains(file.pathExtension.lowercased()) {
            if target == .caCertificate {
                message = String(localized: "“\(name)” is a PKCS#12 file. Redi needs CA certificates as a PEM file; export them in Terminal:")
                commands = ["\(openssl) pkcs12 -in \(input) -cacerts -nokeys -out \(output("-ca.pem"))"]
            } else {
                message = String(localized: "“\(name)” is a PKCS#12 file. Redi needs the certificate and private key as separate PEM files; export them in Terminal, then choose the first as Client Certificate and the second as Client Key:")
                commands = ["\(openssl) pkcs12 -in \(input) -clcerts -nokeys -out \(output("-cert.pem"))",
                            "\(openssl) pkcs12 -in \(input) -nocerts -nodes -out \(output("-key.pem"))"]
            }
        } else {
            let converted = output(file.pathExtension.lowercased() == "pem" ? "-converted.pem" : ".pem")
            if target == .clientKey {
                message = String(localized: "“\(name)” isn't a text (PEM) file. If it's a DER private key, convert it in Terminal:")
                commands = ["\(openssl) pkey -inform der -in \(input) -out \(converted)"]
            } else {
                message = String(localized: "“\(name)” isn't a text (PEM) file. If it's a DER certificate, convert it in Terminal:")
                commands = ["\(openssl) x509 -inform der -in \(input) -out \(converted)"]
            }
        }
        return ImportProblem(message: message, commands: ([cd] + commands).joined(separator: "\n"))
    }

    /// `text` as one shell word: unchanged when it's plainly safe, otherwise single-quoted.
    static func shellQuoted(_ text: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./+@%,:")
        if !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func test() async {
        testState = .testing
        do {
            let session = try SessionFactory.makeSession(profile: normalized(), secrets: secrets)
            defer { Task { await session.close() } }
            let hello = try await session.open()
            var summary = "Connected to \(hello.server.capitalized) \(hello.version)"
            if let topology = await session.topology {
                summary += " · cluster of \(topology.primaries.count) primaries"
            } else if profile.mode == .sentinel {
                summary += " · primary \(await session.primaryEndpoint)"
            }
            testState = .succeeded(summary)
        } catch {
            testState = .failed(String(describing: error))
        }
    }

    private func discoverMasters() async {
        discoveryError = nil
        do {
            var sentinelProfile = normalized()
            sentinelProfile.username = sentinelProfile.sentinel.username
            var sentinelSecrets = secrets
            sentinelSecrets.password = secrets.sentinelPassword
            sentinelProfile.mode = .standalone
            sentinelProfile.database = 0
            discoveredMasters = try await Sentinel.masters(sentinel: SessionFactory.configuration(profile: sentinelProfile, secrets: sentinelSecrets))
        } catch {
            discoveredMasters = []
            discoveryError = String(describing: error)
        }
    }

    private func save(connect: Bool) {
        var result = normalized()
        if result.name.trimmingCharacters(in: .whitespaces).isEmpty { result.name = result.address }
        do {
            try store.save(result, secrets: secrets)
        } catch {
            // Stay open with everything entered, so nothing is lost and it can be retried.
            testState = .failed(String(describing: error))
            return
        }
        dismiss()
        onSave(result, connect)
    }
}

/// A form row showing a chosen file with Choose… and Clear buttons.
private struct FileRow: View {
    let title: LocalizedStringKey
    let fileName: String?
    let placeholder: LocalizedStringKey
    let onChoose: () -> Void
    let onClear: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                if let fileName {
                    Text(fileName).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Clear", systemImage: "xmark.circle.fill", action: onClear)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                } else {
                    Text(placeholder).foregroundStyle(.tertiary)
                }
                Button("Choose…", action: onChoose)
            }
        }
    }
}

struct ColorTagDot: View {
    let tag: ConnectionProfile.ColorTag

    var body: some View {
        Circle()
            .fill(tag.color ?? .clear)
            .strokeBorder(tag == .none ? Color.secondary : .clear, lineWidth: 1)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}

extension ConnectionProfile.ColorTag {
    var color: Color? {
        switch self {
        case .none: nil
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .none: "None"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }
}
