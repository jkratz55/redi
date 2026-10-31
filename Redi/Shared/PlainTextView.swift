import AppKit
import SwiftUI

/// A TextKit 2 `NSTextView` for values, JSON and logs: monospaced, find bar, no smart
/// substitutions, and fast with multi-megabyte text (unlike SwiftUI `Text`).
struct PlainTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var wrapsLines = true
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
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
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        apply(to: textView, scrollView: scrollView)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        apply(to: textView, scrollView: scrollView)
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            if (textView.string as NSString).length >= (selection.first?.rangeValue.upperBound ?? 0) {
                textView.selectedRanges = selection
            }
        }
    }

    private func apply(to textView: NSTextView, scrollView: NSScrollView) {
        textView.isEditable = isEditable
        textView.isSelectable = true
        if textView.font != font { textView.font = font }
        scrollView.hasHorizontalScroller = !wrapsLines
        if wrapsLines {
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        } else {
            textView.isHorizontallyResizable = true
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
