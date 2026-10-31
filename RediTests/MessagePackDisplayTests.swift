import RediCore
import Testing
@testable import Redi

/// `{"sku": "A-1", "qty": 2}` as MessagePack.
private let item: [UInt8] = [0x82, 0xA3, 0x73, 0x6B, 0x75, 0xA3, 0x41, 0x2D, 0x31, 0xA3, 0x71, 0x74, 0x79, 0x02]

@MainActor
private func listPager(_ values: [[UInt8]]) -> CollectionPager<ListEntry> {
    CollectionPager(supportsSearch: false, report: { _ in }, formattedValues: { [$0.value] }) { _, _ in
        ValuePage(elements: values.enumerated().map { ListEntry(index: $0.offset, value: $0.element) }, next: nil)
    }
}

@MainActor
struct MessagePackDisplayTests {
    @Test func pagerPicksMessagePackFromTheFirstPage() async {
        let pager = listPager([Array("plain".utf8), item])
        #expect(pager.format == .text)
        await pager.reload()
        #expect(pager.format == .messagePack)
    }

    @Test func pagerKeepsUnicodeForOtherValues() async {
        let pager = listPager([Array("plain".utf8), [0xFF, 0x00]])
        await pager.reload()
        #expect(pager.format == .text)
    }

    @Test func chosenFormatSurvivesReload() async {
        let pager = listPager([item])
        pager.format = .hex
        await pager.reload()
        #expect(pager.format == .hex)
    }

    @Test func editorShowsMessagePackDecodedAndReadOnly() throws {
        let decoded = BinaryText(item, format: .messagePack)
        #expect(!decoded.isEditable)
        #expect(decoded.text == "{\n  \"sku\": \"A-1\",\n  \"qty\": 2\n}")
        // Saving the sheet's other fields (a hash field's TTL) writes the original bytes back.
        #expect(try decoded.bytes() == item)
        #expect(BinaryText(item, format: .messagePack, style: .compact).text == #"{"sku": "A-1", "qty": 2}"#)

        let raw = BinaryText(item)
        #expect(raw.isEditable && raw.isEscaped)
        let text = BinaryText(Array("5".utf8), format: .messagePack)
        #expect(text.isEditable && text.text == "5")
    }
}
