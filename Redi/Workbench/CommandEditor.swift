import AppKit
import RediCore
import SwiftUI

/// Redis command editor: TextKit 2 `NSTextView` with incremental syntax highlighting and native
/// completion (Esc, or Tab after a partial command name).
struct CommandEditor: NSViewRepresentable {
    @Binding var text: String
    let catalog: CommandCatalog
    /// Reports the line under the caret (for the inline syntax hint) and the selected text.
    var onCaretLine: (String, String) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onCaretLine: onCaretLine) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = CommandTextView(usingTextLayoutManager: true)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.inlinePredictionType = .no
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.font = CommandHighlighter.font
        textView.typingAttributes = [.font: CommandHighlighter.font, .foregroundColor: NSColor.labelColor]
        textView.catalog = catalog
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.string = text
        textView.setAccessibilityIdentifier("workbench.editor")
        context.coordinator.highlighter.catalog = catalog
        context.coordinator.highlighter.highlight(textView.textStorage, range: NSRange(location: 0, length: (text as NSString).length))
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? CommandTextView else { return }
        context.coordinator.text = $text
        context.coordinator.onCaretLine = onCaretLine
        if textView.catalog.names.count != catalog.names.count {
            textView.catalog = catalog
            context.coordinator.highlighter.catalog = catalog
            context.coordinator.highlighter.highlight(textView.textStorage, range: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
        }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var text: Binding<String>
        var onCaretLine: (String, String) -> Void
        let highlighter = CommandHighlighter()

        init(text: Binding<String>, onCaretLine: @escaping (String, String) -> Void) {
            self.text = text
            self.onCaretLine = onCaretLine
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            reportCaret(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            reportCaret(textView)
        }

        private func reportCaret(_ textView: NSTextView) {
            let string = textView.string as NSString
            let selection = textView.selectedRange()
            let lineRange = string.lineRange(for: NSRange(location: min(selection.location, string.length), length: 0))
            let line = string.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let caretInLine = selection.location - lineRange.location
            let beforeCaret = String(line.prefix(max(0, caretInLine)))
            onCaretLine(beforeCaret, selection.length > 0 ? string.substring(with: selection) : "")
        }

        // Re-highlight only the paragraphs touched by each edit.
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            let paragraphs = (textStorage.string as NSString).paragraphRange(for: editedRange)
            highlighter.highlight(textStorage, range: paragraphs)
        }
    }
}

/// Text view adding command completion.
final class CommandTextView: NSTextView {
    var catalog = CommandCatalog.empty

    override func insertTab(_ sender: Any?) {
        // Tab completes a partial command name; otherwise it indents.
        let range = rangeForUserCompletion
        if range.length > 0, !(completions(forPartialWordRange: range, indexOfSelectedItem: nil) ?? []).isEmpty {
            complete(sender)
        } else {
            insertText("    ", replacementRange: selectedRange())
        }
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String]? {
        let string = self.string as NSString
        let lineRange = string.lineRange(for: NSRange(location: charRange.location, length: 0))
        let before = string.substring(with: NSRange(location: lineRange.location, length: charRange.location - lineRange.location))
        let partial = string.substring(with: charRange)
        let candidates = catalog.completions(for: before + partial)
        index?.pointee = -1
        return candidates.isEmpty ? nil : candidates
    }
}

/// Tokenizes command lines and applies colours: command names, quoted strings, numbers, comments.
final class CommandHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let commandFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    var catalog = CommandCatalog.empty

    func highlight(_ storage: NSTextStorage?, range: NSRange) {
        guard let storage, range.length > 0 else { return }
        let string = storage.string as NSString
        storage.beginEditing()
        storage.setAttributes([.font: Self.font, .foregroundColor: NSColor.labelColor], range: range)
        string.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            self.highlightLine(storage, string: string, lineRange: lineRange)
        }
        storage.endEditing()
    }

    private func highlightLine(_ storage: NSTextStorage, string: NSString, lineRange: NSRange) {
        let line = string.substring(with: lineRange)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: lineRange)
            return
        }
        var tokenIndex = 0
        var position = 0
        let characters = Array(line.utf16)
        var words: [String] = []
        while position < characters.count {
            while position < characters.count, characters[position] == 32 || characters[position] == 9 { position += 1 }
            guard position < characters.count else { break }
            let start = position
            let quote = characters[position]
            if quote == 34 || quote == 39 {
                position += 1
                while position < characters.count, characters[position] != quote {
                    if characters[position] == 92 { position += 1 }
                    position += 1
                }
                position = min(position + 1, characters.count)
                storage.addAttribute(.foregroundColor, value: NSColor.systemBrown, range: NSRange(location: lineRange.location + start, length: position - start))
            } else {
                while position < characters.count, characters[position] != 32, characters[position] != 9 { position += 1 }
                let word = String(utf16CodeUnits: Array(characters[start..<position]), count: position - start)
                let range = NSRange(location: lineRange.location + start, length: position - start)
                if tokenIndex == 0, Int(word) != nil, words.isEmpty {
                    // Repeat prefix ("10 INCR x").
                    storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: range)
                    tokenIndex -= 1
                } else if tokenIndex == 0 {
                    if catalog.docs[word.uppercased()] != nil {
                        storage.addAttributes([.foregroundColor: NSColor.systemBlue, .font: Self.commandFont], range: range)
                    }
                    words.append(word)
                } else if tokenIndex == 1, let command = words.first, catalog.docs["\(command.uppercased()) \(word.uppercased())"] != nil {
                    storage.addAttributes([.foregroundColor: NSColor.systemBlue, .font: Self.commandFont], range: range)
                } else if Double(word) != nil {
                    storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: range)
                }
            }
            tokenIndex += 1
        }
    }
}
