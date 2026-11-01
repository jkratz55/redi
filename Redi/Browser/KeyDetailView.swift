import RediCore
import SwiftUI

/// Header (type, name, TTL, size) and type-specific editor for the selected key.
struct KeyDetailView: View {
    @Bindable var model: KeyDetailModel
    /// Deletes the key through the browser, which applies the same confirmation policy as the list.
    var onDelete: () -> Void = {}
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var isEditingTTL = false
    @State private var ttlText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.error {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { model.error = nil }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.red.opacity(0.08))
            }
            Divider()
            valueView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TypeBadge(type: model.details?.type ?? .unknown)
                Text(model.name)
                    .font(.title3.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                headerButtons
            }
            HStack(spacing: 14) {
                if let details = model.details {
                    Button {
                        ttlText = details.ttl.map { String($0 / 1000) } ?? ""
                        isEditingTTL = true
                    } label: {
                        Label(details.ttl.map { "TTL \($0.ttlDescription)" } ?? String(localized: "No TTL"), systemImage: "timer")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isReadOnly)
                    .help("Set or remove the expiry")
                    .popover(isPresented: $isEditingTTL) { ttlEditor }
                    if let length = details.length {
                        Label(details.type == .string ? "\(length.formatted()) bytes" : "\(length.formatted()) items", systemImage: "number")
                    }
                    if let memory = details.memory {
                        Label(memory.byteSize, systemImage: "memorychip")
                    }
                    if let encoding = details.encoding {
                        Label(encoding, systemImage: "shippingbox")
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(12)
    }

    private var headerButtons: some View {
        HStack(spacing: 4) {
            Button("Copy Key Name", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.name, forType: .string)
            }
            Button("Rename", systemImage: "pencil") {
                newName = String(decoding: model.key, as: UTF8.self)
                isRenaming = true
            }
            .disabled(model.isReadOnly)
            .popover(isPresented: $isRenaming) { renameEditor }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
            Button("Delete", systemImage: "trash", action: onDelete)
                .disabled(model.isReadOnly)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private var renameEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename Key").font(.headline)
            TextField("New name", text: $newName)
                .frame(width: 320)
                .onSubmit(rename)
            HStack {
                Spacer()
                Button("Cancel") { isRenaming = false }
                Button("Rename", action: rename).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func rename() {
        let name = newName
        isRenaming = false
        Task { _ = await model.rename(to: name) }
    }

    private var ttlEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Expiry").font(.headline)
            HStack {
                TextField("Seconds", text: $ttlText)
                    .frame(width: 140)
                    .onSubmit(applyTTL)
                Text("seconds").foregroundStyle(.secondary)
            }
            HStack {
                Button("Remove TTL") {
                    isEditingTTL = false
                    Task { await model.setTTL(seconds: nil) }
                }
                Spacer()
                Button("Set", action: applyTTL).keyboardShortcut(.defaultAction)
                    .disabled(Int64(ttlText) == nil)
            }
        }
        .padding(14)
    }

    private func applyTTL() {
        guard let seconds = Int64(ttlText), seconds > 0 else { return }
        isEditingTTL = false
        Task { await model.setTTL(seconds: seconds) }
    }

    // MARK: Value

    @ViewBuilder private var valueView: some View {
        switch model.value {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .string(let value):
            StringValueView(model: value, isReadOnly: model.isReadOnly)
        case .hash(let value):
            HashValueView(model: value, isReadOnly: model.isReadOnly)
        case .list(let value):
            ListValueView(model: value, isReadOnly: model.isReadOnly)
        case .set(let value):
            SetValueView(model: value, isReadOnly: model.isReadOnly)
        case .zset(let value):
            SortedSetValueView(model: value, isReadOnly: model.isReadOnly)
        case .stream(let value):
            StreamValueView(model: value, isReadOnly: model.isReadOnly)
        case .json(let value):
            JSONValueView(model: value, isReadOnly: model.isReadOnly)
        case .missing:
            ContentUnavailableView("Key Not Found", systemImage: "questionmark.key.filled",
                                   description: Text("The key was deleted or expired."))
        case .unsupported(let type):
            ContentUnavailableView {
                Label(type.displayName, systemImage: "puzzlepiece.extension")
            } description: {
                Text("Redi doesn't have an editor for this type yet. Inspect it with module commands in the CLI.")
            } actions: {
                Button("Open in CLI") { model.openInCLI("TYPE \(model.name)") }
            }
        }
    }
}

// MARK: - Shared pieces

/// How values are shown: Unicode, JSON, MessagePack, HEX…
struct FormatPicker: View {
    @Binding var selection: ValueFormat

    var body: some View {
        Picker("Format", selection: $selection) {
            ForEach(ValueFormat.allCases) { Text($0.displayName).tag($0) }
        }
        .fixedSize()
        .help("How values are shown")
    }
}

/// Search field, value format and actions for paged collections.
struct CollectionToolbar<Trailing: View>: View {
    @Binding var search: String
    let supportsSearch: Bool
    @Binding var format: ValueFormat
    let onSearch: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            if supportsSearch {
                TextField("Search", text: $search, prompt: Text("Filter (glob)"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit(onSearch)
            }
            FormatPicker(selection: $format)
            Spacer()
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct LoadMoreFooter: View {
    let count: Int
    let hasMore: Bool
    let isLoading: Bool
    let onLoadMore: () -> Void

    var body: some View {
        HStack {
            Text("\(count.formatted()) loaded").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if isLoading {
                ProgressView().controlSize(.mini)
            } else if hasMore {
                Button("Load More", action: onLoadMore).controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// Editable text that round-trips binary safely: UTF-8 text shows as-is, anything else uses
/// `\xHH` escapes. In the MessagePack format, MessagePack values show decoded and read-only.
struct BinaryText {
    var text: String
    let isEscaped: Bool
    /// The original bytes when `text` is a read-only decoding of them.
    let decodedFrom: [UInt8]?

    init(_ bytes: [UInt8], format: ValueFormat = .text, style: MessagePack.Style = .pretty) {
        if format == .messagePack, let decoded = ValueFormatter.messagePackElement(bytes, style: style) {
            text = decoded
            isEscaped = false
            decodedFrom = bytes
            return
        }
        isEscaped = !ValueFormatter.isText(bytes) && !bytes.isEmpty
        text = isEscaped ? ValueFormatter.escaped(bytes) : String(decoding: bytes, as: UTF8.self)
        decodedFrom = nil
    }

    init(text: String = "") {
        self.text = text
        isEscaped = false
        decodedFrom = nil
    }

    var isEditable: Bool { decodedFrom == nil }

    func bytes() throws -> [UInt8] {
        if let decodedFrom { return decodedFrom }
        return isEscaped ? try ValueFormatter.unescape(text) : Array(text.utf8)
    }
}

/// Sheet for adding or editing an element: one or two text fields plus optional extras.
struct ElementEditorSheet: View {
    struct Field: Identifiable {
        let id = UUID()
        let label: LocalizedStringKey
        var value: BinaryText
        var isMultiline = false
        var isEditable = true
    }

    let title: LocalizedStringKey
    @State var fields: [Field]
    var extraLabel: LocalizedStringKey?
    @State var extra = ""
    var extraPrompt: LocalizedStringKey = ""
    let onSave: ([[UInt8]], String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        Form {
            ForEach($fields) { $field in
                let isEditable = field.isEditable && field.value.isEditable
                if field.isMultiline {
                    LabeledContent(field.label) {
                        PlainTextView(text: $field.value.text, isEditable: isEditable)
                            .frame(minHeight: 140)
                    }
                } else {
                    TextField(field.label, text: $field.value.text)
                        .disabled(!isEditable)
                }
                if field.value.isEscaped {
                    Text("Binary value: non-text bytes are shown as \\xHH escapes.").font(.caption).foregroundStyle(.secondary)
                } else if !field.value.isEditable {
                    Text("Decoded from MessagePack, so it can't be edited here. To edit the raw bytes, choose Unicode in the Format menu.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let extraLabel {
                TextField(extraLabel, text: $extra, prompt: Text(extraPrompt))
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        let values = try fields.map { try $0.value.bytes() }
                        let extra = self.extra
                        Task {
                            await onSave(values, extra)
                            dismiss()
                        }
                    } catch {
                        self.error = String(describing: error)
                    }
                }
            }
        }
        .navigationTitle(title)
    }
}
