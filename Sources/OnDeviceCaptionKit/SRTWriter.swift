import Foundation

nonisolated final class SRTWriter: Sendable {
    private enum Error: Swift.Error {
        case rollbackFailed(recoveryDirectory: URL)
    }

    init() {}

    func generateSRTFile(from segments: [CaptionSegment], to outputURL: URL) throws {
        try writeSRTFile(from: segments, to: outputURL)
    }

    @concurrent
    func generateSRTFile(from segments: [CaptionSegment], to outputURL: URL) async throws {
        try writeSRTFile(from: segments, to: outputURL)
    }

    @concurrent
    func generateSRTBundle(
        from tracks: [CaptionLanguageTrack],
        besideVideoAt videoURL: URL
    ) async throws -> [URL] {
        try Task.checkCancellation()
        let files = tracks.enumerated().compactMap { index, track -> BundleFile? in
            guard track.segments.contains(where: {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else { return nil }
            let targetURL = srtURL(
                besideVideoAt: videoURL,
                languageIdentifier: index == 0 ? nil : track.languageIdentifier
            )
            return BundleFile(targetURL: targetURL, segments: track.segments)
        }
        guard !files.isEmpty else { return [] }

        let fileManager = FileManager.default
        let stagingURL = videoURL.deletingLastPathComponent()
            .appendingPathComponent(".CaptionSRTBundle-\(UUID().uuidString)", isDirectory: true)
        let stagedFilesURL = stagingURL.appendingPathComponent("staged", isDirectory: true)
        let backupsURL = stagingURL.appendingPathComponent("backups", isDirectory: true)
        try fileManager.createDirectory(at: stagedFilesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        var shouldPreserveStaging = false
        defer {
            if !shouldPreserveStaging {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        var stagedFiles: [(staged: URL, target: URL)] = []
        for file in files {
            try Task.checkCancellation()
            let stagedURL = stagedFilesURL.appendingPathComponent(file.targetURL.lastPathComponent)
            try writeSRTFile(from: file.segments, to: stagedURL)
            stagedFiles.append((stagedURL, file.targetURL))
        }

        var backups: [(backup: URL, target: URL)] = []
        var adoptedTargets: [URL] = []
        do {
            for (index, file) in stagedFiles.enumerated()
                where fileManager.fileExists(atPath: file.target.path) {
                try Task.checkCancellation()
                let backupURL = backupsURL.appendingPathComponent("\(index)-\(file.target.lastPathComponent)")
                try fileManager.moveItem(at: file.target, to: backupURL)
                backups.append((backupURL, file.target))
            }
            for file in stagedFiles {
                try Task.checkCancellation()
                try fileManager.moveItem(at: file.staged, to: file.target)
                adoptedTargets.append(file.target)
            }
        } catch {
            var rollbackFailed = false
            for target in adoptedTargets where fileManager.fileExists(atPath: target.path) {
                do {
                    try fileManager.removeItem(at: target)
                } catch {
                    rollbackFailed = true
                }
            }
            for backup in backups where fileManager.fileExists(atPath: backup.backup.path) {
                do {
                    try fileManager.moveItem(at: backup.backup, to: backup.target)
                } catch {
                    rollbackFailed = true
                }
            }
            if rollbackFailed {
                shouldPreserveStaging = true
                CaptionLogger.error("SRT bundle rollback failed; recovery directory preserved")
                throw Error.rollbackFailed(recoveryDirectory: stagingURL)
            }
            throw error
        }
        CaptionLogger.info("Created SRT bundle with \(adoptedTargets.count) file(s)")
        return adoptedTargets
    }

    private func writeSRTFile(from segments: [CaptionSegment], to outputURL: URL) throws {
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

    private func srtURL(
        besideVideoAt videoURL: URL,
        languageIdentifier: String?
    ) -> URL {
        let baseURL = videoURL.deletingPathExtension()
        guard let languageIdentifier else { return baseURL.appendingPathExtension("srt") }
        return baseURL
            .appendingPathExtension(languageIdentifier)
            .appendingPathExtension("srt")
    }

    private struct BundleFile {
        let targetURL: URL
        let segments: [CaptionSegment]
    }
}
