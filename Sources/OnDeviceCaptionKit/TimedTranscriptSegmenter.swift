import CoreMedia
import Foundation

@available(macOS 26, *)
enum TimedTranscriptSegmenter {
    enum Error: Swift.Error, Equatable {
        case missingTiming
        case invalidTiming
        case nonMonotonicTiming
        case transcriptMismatch
    }

    struct Token: Equatable, Sendable {
        var text: String
        let timeRange: CMTimeRange
    }

    static let maximumCharacters = 64
    static let maximumDuration: TimeInterval = 5
    static let silenceBreak: TimeInterval = 0.8

    static func segments(from text: AttributedString, startingAt index: Int) throws -> [CaptionSegment] {
        var tokens: [Token] = []
        var pendingWhitespace = ""

        for run in text.runs {
            let runText = String(text[run.range].characters)
            guard !runText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                pendingWhitespace += runText
                continue
            }
            guard let timeRange = run.audioTimeRange else {
                throw Error.missingTiming
            }
            tokens.append(
                Token(
                    text: pendingWhitespace + runText,
                    timeRange: timeRange
                )
            )
            pendingWhitespace = ""
        }

        if !pendingWhitespace.isEmpty, !tokens.isEmpty {
            tokens[tokens.index(before: tokens.endIndex)].text += pendingWhitespace
        }

        let output = try segments(from: tokens, startingAt: index)
        guard normalized(output.map(\.text).joined(separator: " "))
                == normalized(String(text.characters)) else {
            throw Error.transcriptMismatch
        }
        return output
    }

    static func segments(from tokens: [Token], startingAt index: Int) throws -> [CaptionSegment] {
        try validate(tokens)
        var groups: [[Token]] = []
        var current: [Token] = []

        for token in tokens {
            if shouldBreak(before: token, current: current) {
                groups.append(current)
                current = []
            }
            current.append(token)
            if token.text.trimmingCharacters(in: .whitespacesAndNewlines).last?.isSentenceTerminator == true {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }

        let segments: [CaptionSegment] = groups.enumerated().compactMap { offset, group in
            guard let first = group.first, let last = group.last else { return nil }
            let text = group.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let start = CMTimeGetSeconds(first.timeRange.start)
            let end = CMTimeGetSeconds(last.timeRange.end)
            guard !text.isEmpty, start.isFinite, end.isFinite, end > start else { return nil }
            return CaptionSegment(index: index + offset, startTime: start, endTime: end, text: text)
        }
        guard segments.count == groups.count else {
            throw Error.invalidTiming
        }
        return segments
    }

    private static func shouldBreak(before token: Token, current: [Token]) -> Bool {
        guard let first = current.first, let previous = current.last else { return false }
        let nextText = current.map(\.text).joined() + token.text
        let duration = CMTimeGetSeconds(token.timeRange.end - first.timeRange.start)
        let silence = CMTimeGetSeconds(token.timeRange.start - previous.timeRange.end)
        return nextText.count > maximumCharacters
            || duration > maximumDuration
            || silence >= silenceBreak
    }

    private static func validate(_ tokens: [Token]) throws {
        var previousStart: CMTime?
        var previousEnd: CMTime?

        for token in tokens {
            let start = token.timeRange.start
            let end = token.timeRange.end
            let startSeconds = CMTimeGetSeconds(start)
            let endSeconds = CMTimeGetSeconds(end)
            guard startSeconds.isFinite,
                  endSeconds.isFinite,
                  startSeconds >= 0,
                  endSeconds > startSeconds else {
                throw Error.invalidTiming
            }
            if let previousStart, let previousEnd,
               CMTimeCompare(start, previousStart) < 0 || CMTimeCompare(end, previousEnd) < 0 {
                throw Error.nonMonotonicTiming
            }
            previousStart = start
            previousEnd = end
        }
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private extension Character {
    var isSentenceTerminator: Bool {
        ".!?。！？".contains(self)
    }
}
