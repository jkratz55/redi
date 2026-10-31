import AppKit
import RediCore
import SwiftUI

extension RedisKeyType {
    /// Badge tint. Distinct hues per type, as in Redis Insight, using system colors so they adapt
    /// to light/dark mode and Increase Contrast.
    var nsColor: NSColor {
        switch self {
        case .string: .systemBlue
        case .hash: .systemPurple
        case .list: .systemGreen
        case .set: .systemOrange
        case .zset: .systemRed
        case .stream: .systemTeal
        case .json: .systemBrown
        case .timeSeries: .systemPink
        case .vectorSet: .systemIndigo
        case .bloom, .cuckoo, .countMinSketch, .topK, .tDigest: .systemMint
        case .unknown, .other, .none: .systemGray
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// SwiftUI type badge ("HASH", "ZSET", …).
struct TypeBadge: View {
    let type: RedisKeyType

    var body: some View {
        Text(verbatim: type.badge)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(type.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(type.color.opacity(0.16), in: .rect(cornerRadius: 4))
            .accessibilityLabel(type.displayName)
    }
}

/// AppKit type badge for table cells; drawn directly, no subviews.
final class TypeBadgeView: NSView {
    var type: RedisKeyType = .unknown {
        didSet {
            if oldValue != type {
                needsDisplay = true
                setAccessibilityLabel(type.displayName)
            }
        }
    }

    private static let font = NSFont.systemFont(ofSize: 9, weight: .bold)

    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 16) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let color = type.nsColor
        let rect = bounds.insetBy(dx: 0.5, dy: 1)
        color.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let text = type.badge as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
}

extension Int64 {
    /// Memory size, e.g. "1.2 KB".
    var byteSize: String { formatted(.byteCount(style: .memory)) }
}

extension Array where Element == UInt8 {
    /// Key/value bytes as display text (escaped when not valid UTF-8).
    var displayText: String { ValueFormatter.preview(self, limit: 4096) }
}

extension ArraySlice where Element == UInt8 {
    var displayText: String { ValueFormatter.preview(self, limit: 4096) }
}
