import Foundation
import Testing
@testable import OnDeviceCaptionKit

struct SRTWriterTests {
    struct TimestampCase: Sendable {
        let seconds: TimeInterval
        let expected: String
    }

    @Test(
        "Formats timestamps using SRT clock syntax",
        arguments: [
            TimestampCase(seconds: 0, expected: "00:00:00,000"),
            TimestampCase(seconds: 2.5, expected: "00:00:02,500"),
            TimestampCase(seconds: 61.042, expected: "00:01:01,042"),
            TimestampCase(seconds: 3661.123, expected: "01:01:01,123")
        ]
    )
    func givenTimeIntervalWhenFormattingTimeThenTimestampUsesSRTSyntax(scenario: TimestampCase) {
        // Given
        let srtGenerator = SRTWriter()

        // When
        let formattedTime = srtGenerator.formatTime(scenario.seconds)

        // Then
        #expect(formattedTime == scenario.expected)
    }

    @Test("Formats non-empty segments as SRT content")
    func givenSegmentsWhenCreatingSRTContentThenEntriesAreFormattedAndReindexed() {
        // Given
        let srtGenerator = SRTWriter()
        let segments = [
            CaptionSegment(index: 10, startTime: 0.0, endTime: 2.5, text: "Hello world"),
            CaptionSegment(index: 20, startTime: 2.5, endTime: 5.0, text: "This is a test")
        ]

        // When
        let srtContent = srtGenerator.createSRTContent(from: segments)

        // Then
        let expectedContent = """
        1
        00:00:00,000 --> 00:00:02,500
        Hello world

        2
        00:00:02,500 --> 00:00:05,000
        This is a test

        """
        #expect(srtContent == expectedContent)
        #expect(srtContent.hasSuffix("\n\n") == false)
    }

    @Test("Empty segment input creates empty SRT content")
    func givenEmptySegmentsWhenCreatingSRTContentThenContentIsEmpty() {
        // Given
        let srtGenerator = SRTWriter()
        let segments: [CaptionSegment] = []

        // When
        let srtContent = srtGenerator.createSRTContent(from: segments)

        // Then
        #expect(srtContent == "")
    }

    @Test("Empty subtitle text is skipped and output indices stay sequential")
    func givenEmptyTextSegmentsWhenCreatingSRTContentThenSegmentsAreSkipped() {
        // Given
        let srtGenerator = SRTWriter()
        let segments = [
            CaptionSegment(index: 1, startTime: 0.0, endTime: 2.0, text: "Valid text"),
            CaptionSegment(index: 2, startTime: 2.0, endTime: 4.0, text: ""),
            CaptionSegment(index: 3, startTime: 4.0, endTime: 5.0, text: "   \n"),
            CaptionSegment(index: 4, startTime: 5.0, endTime: 6.0, text: "Another valid text")
        ]

        // When
        let srtContent = srtGenerator.createSRTContent(from: segments)

        // Then
        let expectedContent = """
        1
        00:00:00,000 --> 00:00:02,000
        Valid text

        2
        00:00:05,000 --> 00:00:06,000
        Another valid text

        """
        #expect(srtContent == expectedContent)
    }

    @Test("Subtitle text is trimmed and wrapped for SRT output")
    func givenWhitespaceAroundTextWhenCreatingSRTContentThenTextIsTrimmed() {
        // Given
        let srtGenerator = SRTWriter()
        let segments = [
            CaptionSegment(index: 1, startTime: 0.0, endTime: 1.0, text: "  Trim me\n")
        ]

        // When
        let srtContent = srtGenerator.createSRTContent(from: segments)

        // Then
        let expectedContent = """
        1
        00:00:00,000 --> 00:00:01,000
        Trim me

        """
        #expect(srtContent == expectedContent)
    }

    @Test("Long subtitle text wraps onto multiple SRT lines")
    func givenLongTextWhenCreatingSRTContentThenTextWraps() {
        // Given
        let srtGenerator = SRTWriter()
        let segments = [
            CaptionSegment(
                index: 1,
                startTime: 0.0,
                endTime: 2.0,
                text: "This is a longer sentence that should wrap onto two rows"
            )
        ]

        // When
        let srtContent = srtGenerator.createSRTContent(from: segments)

        // Then
        let wrappedText = CaptionTextLayout.srtDisplayText(from: segments[0].text)
        #expect(srtContent.contains(wrappedText))
        #expect(wrappedText.contains("\n"))
    }
}
