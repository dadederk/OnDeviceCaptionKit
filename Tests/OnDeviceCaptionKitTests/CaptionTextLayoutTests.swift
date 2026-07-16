import Foundation
import Testing
@testable import OnDeviceCaptionKit

struct CaptionTextLayoutTests {
    @Test("Display groups pair row-sized lines for two-row presentation")
    func givenLongTextWhenGroupingForDisplayThenLinesArePaired() {
        let text = String(repeating: "longword ", count: 16).trimmingCharacters(in: .whitespaces)
        let groups = CaptionTextLayout.displayGroups(from: text)

        #expect(groups.count >= 2)
        #expect(groups.allSatisfy { $0.count <= 2 })
        #expect(groups.flatMap { $0 }.joined(separator: " ") == text)
    }

    @Test("Explicit line breaks become separate rows in the same display group")
    func givenExplicitLineBreakWhenGroupingForDisplayThenRowsArePreserved() {
        let groups = CaptionTextLayout.displayGroups(from: "Line one\nLine two")

        #expect(groups == [["Line one", "Line two"]])
    }

    @Test("SRT display text wraps long text onto multiple lines")
    func givenLongTextWhenFormattingForSRTThenLinesAreWrapped() {
        let text = "This is a longer sentence that should wrap onto two rows"
        let formatted = CaptionTextLayout.srtDisplayText(from: text)

        #expect(formatted.contains("\n"))
        #expect(formatted.split(separator: "\n").allSatisfy { $0.count <= 32 })
    }
}
