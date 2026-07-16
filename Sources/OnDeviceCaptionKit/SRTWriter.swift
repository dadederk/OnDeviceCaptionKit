import Foundation

nonisolated final class SRTWriter: @unchecked Sendable {
    init() {}

    func generateSRTFile(from segments: [CaptionSegment], to outputURL: URL) throws {
        CaptionLogger.info("Generating SRT file with \(segments.count) segment(s)")
        let srtContent = createSRTContent(from: segments)
        try srtContent.write(to: outputURL, atomically: true, encoding: .utf8)
        CaptionLogger.info("SRT file created successfully")
    }

    func createSRTContent(from segments: [CaptionSegment]) -> String {
        var entries: [String] = []
        var subtitleIndex = 1

        for segment in segments {
            let startTime = formatTime(segment.startTime)
            let endTime = formatTime(segment.endTime)
            let text = CaptionTextLayout.srtDisplayText(from: segment.text)
            guard !text.isEmpty else { continue }

            entries.append(
                """
                \(subtitleIndex)
                \(startTime) --> \(endTime)
                \(text)
                """
            )
            subtitleIndex += 1
        }

        guard !entries.isEmpty else { return "" }
        return entries.joined(separator: "\n\n") + "\n"
    }

    func formatTime(_ timeInterval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .pad
        formatter.unitsStyle = .positional

        let timeString = formatter.string(from: timeInterval) ?? "00:00:00"
        let milliseconds = Int((timeInterval.truncatingRemainder(dividingBy: 1)) * 1000)
        return "\(timeString),\(String(format: "%03d", milliseconds))"
    }

    func srtURLBesideVideo(_ videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("srt")
    }
}
