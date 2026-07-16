import Foundation
import AVFoundation

@available(macOS 26, *)
nonisolated final class CaptionEmbedder: @unchecked Sendable {
    private struct UncheckedSendableBox<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private struct CaptionMoviePart: Sendable {
        let url: URL
        /// Global timeline position where the chunk's first visible caption should appear.
        let insertTime: CMTime
        /// Source-track time to trim leading CEA-608 preroll before inserting.
        let sourceTrimStart: CMTime
    }

    private static let defaultFrameDuration = CMTime(value: 1001, timescale: 30_000)
    private static let defaultEmbeddingTimeout: TimeInterval = 10
    private static let maxCaptionDurationSeconds: TimeInterval = 3
    private static let maxCaptionsPerCaptionMovie = 4
    private static let minGapForCaptionChunkSplitSeconds: TimeInterval = 0.25
    private static let undefinedLanguageCode = "und"
    private let fileManager: FileManager
    private let embeddingTimeout: TimeInterval
    private let captionLanguageCode: String
    private let captionExtendedLanguageTag: String

    nonisolated init(
        fileManager: FileManager = .default,
        embeddingTimeout: TimeInterval = CaptionEmbedder.defaultEmbeddingTimeout,
        locale: Locale = Locale(identifier: "en-US")
    ) {
        self.fileManager = fileManager
        self.embeddingTimeout = embeddingTimeout
        let tags = Self.captionLanguageTags(for: locale)
        self.captionLanguageCode = tags.languageCode
        self.captionExtendedLanguageTag = tags.extendedLanguageTag
    }

    nonisolated func estimatedEmbeddingTimeout(
        for segments: [CaptionSegment],
        into videoURL: URL
    ) async throws -> TimeInterval {
        let captions = try makeClosedCaptions(
            from: segments,
            maxTimelineEnd: try await sourceVideoDuration(for: videoURL)
        )
        guard !captions.isEmpty else {
            return CaptionEmbeddingTimeoutBudget.totalTimeout(
                chunkCount: 0,
                perStepTimeout: embeddingTimeout
            )
        }
        let chunkRanges = Self.captionChunkRanges(
            in: captions,
            maxCaptionsPerChunk: Self.maxCaptionsPerCaptionMovie
        )
        return CaptionEmbeddingTimeoutBudget.totalTimeout(
            chunkCount: chunkRanges.count,
            perStepTimeout: embeddingTimeout
        )
    }

    nonisolated func embedClosedCaptions(
        from segments: [CaptionSegment],
        into videoURL: URL,
        cancellation: CaptionEmbeddingCancellationHolder? = nil,
        progressHandler: (@Sendable (Float) -> Void)? = nil
    ) async throws -> URL {
        log("Starting caption embedding into \(videoURL.lastPathComponent)")
        logGeneratedSegments(segments)
        logFileSize(at: videoURL, label: "Source")

        let captions = try makeClosedCaptions(from: segments, maxTimelineEnd: try await sourceVideoDuration(for: videoURL))
        guard !captions.isEmpty else { throw CaptionEmbeddingError.noTracksToCopy }
        log("Conformed \(captions.count) caption(s)")
        logConformedCaptions(captions)

        let outputURL = temporaryOutputURL()
        try? fileManager.removeItem(at: outputURL)

        let cancellationHolder = cancellation ?? CaptionEmbeddingCancellationHolder()
        let work = UncheckedSendableBox((
            captions: captions,
            videoURL: videoURL,
            outputURL: outputURL,
            cancellationHolder: cancellationHolder
        ))

        do {
            let captionMovieParts = try await writeCaptionTrackMovies(
                captions: work.value.captions,
                cancellationHolder: work.value.cancellationHolder
            )
            defer { removeCaptionMovieParts(captionMovieParts) }

            try await CaptionEmbeddingTimeout.run(
                seconds: embeddingTimeout,
                onTimeout: { [self] in
                    log("Captioned movie export timed out after \(Int(embeddingTimeout))s; cancelling export")
                    work.value.cancellationHolder.cancel()
                },
                operation: { [self] in
                    try await composeAndExport(
                        videoURL: work.value.videoURL,
                        captionMovieParts: captionMovieParts,
                        outputURL: work.value.outputURL,
                        cancellationHolder: work.value.cancellationHolder,
                        progressHandler: progressHandler
                    )
                }
            )

            logFileSize(at: outputURL, label: "Output")
            log("Caption embedding completed: \(outputURL.lastPathComponent)")
            return outputURL
        } catch {
            log("Caption embedding aborted: \(error.localizedDescription)")
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
    }

    private nonisolated func writeCaptionTrackMovies(
        captions: [AVCaption],
        cancellationHolder: CaptionEmbeddingCancellationHolder
    ) async throws -> [CaptionMoviePart] {
        var parts: [CaptionMoviePart] = []
        var temporaryURLs: [URL] = []

        do {
            let chunkRanges = Self.captionChunkRanges(in: captions, maxCaptionsPerChunk: Self.maxCaptionsPerCaptionMovie)
            for (chunkIndex, range) in chunkRanges.enumerated() {
                try Task.checkCancellation()
                let localized = try Self.localizedCaptionChunk(captions[range])
                let localizedWork = UncheckedSendableBox(localized)
                let url = temporaryCaptionURL()
                try? fileManager.removeItem(at: url)
                temporaryURLs.append(url)

                log(
                    "Caption movie chunk \(chunkIndex + 1): writing \(localized.captions.count) caption(s) with timeline offset \(Self.formatLogTimestamp(CMTimeGetSeconds(localized.timelineOffset)))s"
                )
                try await CaptionEmbeddingTimeout.run(
                    seconds: embeddingTimeout,
                    onTimeout: { [self] in
                        log(
                            "Caption movie chunk \(chunkIndex + 1) timed out after \(Int(embeddingTimeout))s; cancelling writer"
                        )
                        cancellationHolder.cancel()
                    },
                    operation: { [self] in
                        try await writeCaptionTrackMovie(
                            captions: localizedWork.value.captions,
                            to: url,
                            cancellationHolder: cancellationHolder
                        )
                    }
                )
                let chunkCaptions = Array(captions[range])
                guard let firstOriginal = chunkCaptions.first,
                      let firstLocalized = localized.captions.first else {
                    continue
                }
                parts.append(
                    CaptionMoviePart(
                        url: url,
                        insertTime: firstOriginal.timeRange.start,
                        sourceTrimStart: firstLocalized.timeRange.start
                    )
                )
            }
            return parts
        } catch {
            for url in temporaryURLs {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }

    private nonisolated func writeCaptionTrackMovie(
        captions: [AVCaption],
        to url: URL,
        cancellationHolder: CaptionEmbeddingCancellationHolder
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        cancellationHolder.setWriter(writer)
        defer { cancellationHolder.clearWriter(writer) }

        let captionInput = try makeClosedCaptionInput()
        guard writer.canAdd(captionInput) else {
            throw CaptionEmbeddingError.cannotAddInput(AVMediaType.closedCaption.rawValue)
        }
        writer.add(captionInput)
        let receiver = writer.inputCaptionReceiver(for: captionInput)

        guard writer.startWriting() else {
            throw writer.error ?? CaptionEmbeddingError.cannotStartWriter
        }
        writer.startSession(atSourceTime: .zero)

        log("Caption movie: appending \(captions.count) caption(s)")
        for (index, caption) in captions.enumerated() {
            try Task.checkCancellation()
            log("Caption movie: appending \(index + 1)/\(captions.count)")
            try await receiver.append(caption)
            log("Caption movie: appended \(index + 1)/\(captions.count)")
        }
        receiver.finish()

        try await finishWriting(writer)
        log("Caption movie written: \(url.lastPathComponent)")
    }

    private nonisolated func composeAndExport(
        videoURL: URL,
        captionMovieParts: [CaptionMoviePart],
        outputURL: URL,
        cancellationHolder: CaptionEmbeddingCancellationHolder,
        progressHandler: (@Sendable (Float) -> Void)? = nil
    ) async throws {
        let composition = AVMutableComposition()
        let sourceAsset = AVURLAsset(url: videoURL)

        try await insertTracks(of: .video, from: sourceAsset, into: composition)
        try await insertTracks(of: .audio, from: sourceAsset, into: composition)

        try await insertCaptionMovieParts(captionMovieParts, into: composition)
        log("Composed \(composition.tracks.count) track(s) for export")

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptionEmbeddingError.cannotCreateExportSession
        }
        export.outputURL = outputURL
        export.outputFileType = .mov
        export.shouldOptimizeForNetworkUse = false
        cancellationHolder.setExportSession(export)
        defer { cancellationHolder.clearExportSession(export) }

        log("Exporting captioned movie (passthrough, no network optimization)")
        let progressWork = UncheckedSendableBox((export: export, progressHandler: progressHandler))
        let progressTask = Task { @concurrent in
            while !Task.isCancelled {
                progressWork.value.progressHandler?(progressWork.value.export.progress)
                if progressWork.value.export.progress >= 1 {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { progressTask.cancel() }
        try await export.export(to: outputURL, as: .mov)
        progressHandler?(1)
        log("Export completed")
    }

    private nonisolated func insertCaptionMovieParts(
        _ parts: [CaptionMoviePart],
        into composition: AVMutableComposition
    ) async throws {
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .closedCaption,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CaptionEmbeddingError.cannotAddInput(AVMediaType.closedCaption.rawValue)
        }

        for part in parts {
            let asset = AVURLAsset(url: part.url)
            guard let track = try await asset.loadTracks(withMediaType: .closedCaption).first else {
                throw CaptionEmbeddingError.noTracksToCopy
            }

            let timeRange = try await track.load(.timeRange)
            guard CMTimeCompare(part.sourceTrimStart, timeRange.end) < 0 else {
                throw CaptionEmbeddingError.noTracksToCopy
            }
            let trimmedDuration = CMTimeSubtract(timeRange.end, part.sourceTrimStart)
            let trimmedRange = CMTimeRange(start: part.sourceTrimStart, duration: trimmedDuration)
            try compositionTrack.insertTimeRange(trimmedRange, of: track, at: part.insertTime)
            log(
                "Inserted caption chunk \(part.url.lastPathComponent) at \(Self.formatLogTimestamp(CMTimeGetSeconds(part.insertTime)))s (trimmed source from \(Self.formatLogTimestamp(CMTimeGetSeconds(part.sourceTrimStart)))s)"
            )
        }

        compositionTrack.languageCode = captionLanguageCode
        compositionTrack.extendedLanguageTag = captionExtendedLanguageTag
    }

    private nonisolated func insertTracks(
        of mediaType: AVMediaType,
        from asset: AVURLAsset,
        into composition: AVMutableComposition
    ) async throws {
        let tracks = try await asset.loadTracks(withMediaType: mediaType)
        for track in tracks {
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw CaptionEmbeddingError.cannotAddInput(mediaType.rawValue)
            }

            let timeRange = try await track.load(.timeRange)
            try compositionTrack.insertTimeRange(timeRange, of: track, at: .zero)
            try await applyLanguageMetadata(from: track, to: compositionTrack, mediaType: mediaType)

            if mediaType == .video {
                let preferredTransform = try await track.load(.preferredTransform)
                compositionTrack.preferredTransform = preferredTransform
            }
        }
    }

    private nonisolated func applyLanguageMetadata(
        from sourceTrack: AVAssetTrack,
        to compositionTrack: AVMutableCompositionTrack,
        mediaType: AVMediaType
    ) async throws {
        let sourceLanguageCode = try await sourceTrack.load(.languageCode)
        let sourceExtendedLanguageTag = try await sourceTrack.load(.extendedLanguageTag)

        compositionTrack.languageCode = sourceLanguageCode
        compositionTrack.extendedLanguageTag = sourceExtendedLanguageTag

        guard mediaType == .closedCaption else { return }

        if !Self.hasDefinedLanguageCode(compositionTrack.languageCode) {
            compositionTrack.languageCode = captionLanguageCode
        }
        if !Self.hasDefinedLanguageTag(compositionTrack.extendedLanguageTag) {
            compositionTrack.extendedLanguageTag = captionExtendedLanguageTag
        }
    }

    private nonisolated func finishWriting(_ writer: AVAssetWriter) async throws {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            throw writer.error ?? CaptionEmbeddingError.cannotStartWriter
        }
    }

    nonisolated func makeClosedCaptions(
        from segments: [CaptionSegment],
        frameDuration: CMTime = CaptionEmbedder.defaultFrameDuration,
        maxTimelineEnd: CMTime? = nil
    ) throws -> [AVCaption] {
        let captions = makeCanonicalCaptions(
            from: segments,
            frameDuration: frameDuration,
            maxTimelineEnd: maxTimelineEnd
        )
        guard !captions.isEmpty else { return [] }

        let conformer = Self.makeCaptionConformer(frameDuration: frameDuration)

        return try captions.map { caption in
            do {
                return try conformer.conformedCaption(for: caption)
            } catch {
                CaptionLogger.error("Failed to conform caption to CEA-608: \(error.localizedDescription)")
                throw CaptionEmbeddingError.captionConformanceFailed
            }
        }
    }

    private nonisolated func sourceVideoDuration(for videoURL: URL) async throws -> CMTime {
        let asset = AVURLAsset(url: videoURL)
        return try await asset.load(.duration)
    }

    private nonisolated func makeCanonicalCaptions(
        from segments: [CaptionSegment],
        frameDuration: CMTime,
        maxTimelineEnd: CMTime? = nil
    ) -> [AVCaption] {
        var captions: [AVCaption] = []
        var previousEnd = CMTime.zero

        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !CaptionTextLayout.normalizedParagraphs(from: text).isEmpty else { continue }

            var start = Self.alignedTime(seconds: segment.startTime, frameDuration: frameDuration, rounding: .up)
            if start < previousEnd {
                start = previousEnd
            }

            var end = Self.alignedTime(seconds: segment.endTime, frameDuration: frameDuration, rounding: .up)
            if let maxTimelineEnd, end > maxTimelineEnd {
                end = maxTimelineEnd
            }
            if let maxTimelineEnd, start >= maxTimelineEnd {
                continue
            }
            if end <= start {
                end = start + frameDuration
            }

            let segmentDuration = CMTimeSubtract(end, start)
            let chunks = Self.limitedCaptionChunks(
                text: text,
                segmentDuration: segmentDuration,
                frameDuration: frameDuration
            )
            let chunkDuration = CMTimeMultiplyByRatio(
                segmentDuration,
                multiplier: 1,
                divisor: Int32(max(chunks.count, 1))
            )

            for (chunkIndex, chunk) in chunks.enumerated() {
                var chunkStart = start + CMTimeMultiply(chunkDuration, multiplier: Int32(chunkIndex))
                if chunkStart < previousEnd {
                    chunkStart = previousEnd
                }

                var chunkEnd = chunkStart + chunkDuration
                if chunkIndex == chunks.count - 1 {
                    chunkEnd = max(chunkEnd, end)
                }
                if let maxTimelineEnd, chunkEnd > maxTimelineEnd {
                    chunkEnd = maxTimelineEnd
                }
                if let maxTimelineEnd, chunkStart >= maxTimelineEnd {
                    continue
                }
                if chunkEnd <= chunkStart {
                    chunkEnd = chunkStart + frameDuration
                }

                let timeRanges = Self.splitCaptionTimeRange(
                    start: chunkStart,
                    end: chunkEnd,
                    frameDuration: frameDuration
                )
                for timeRange in timeRanges {
                    guard Self.isValidCaptionTimeRange(timeRange) else { continue }
                    captions.append(AVCaption(chunk, timeRange: timeRange))
                    previousEnd = timeRange.end
                }
            }
        }

        return captions
    }

    private nonisolated func makeClosedCaptionInput() throws -> AVAssetWriterInput {
        var formatDescription: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: kCMMediaType_ClosedCaption,
            mediaSubType: kCMClosedCaptionFormatType_CEA608,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDescription else {
            CaptionLogger.error("Failed to create CEA-608 closed-caption format description: \(status)")
            assertionFailure("Failed to create CEA-608 closed-caption format description")
            throw CaptionEmbeddingError.cannotCreateClosedCaptionFormat(status)
        }

        let input = AVAssetWriterInput(
            mediaType: .closedCaption,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = false
        return input
    }

    private nonisolated func logGeneratedSegments(_ segments: [CaptionSegment]) {
        log("Prepared \(segments.count) caption segment(s) for embedding")
    }

    private nonisolated func logConformedCaptions(_ captions: [AVCaption]) {
        log("Conformed \(captions.count) caption event(s)")
    }

    private nonisolated func logFileSize(at url: URL, label: String) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else {
            log("\(label) file size: unavailable")
            return
        }
        log("\(label) file size: \(size) bytes")
    }

    private nonisolated func log(_ message: String) {
        CaptionLogger.info("\(message)")
    }

    private nonisolated func temporaryOutputURL() -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("Recording-\(UUID().uuidString)")
            .appendingPathExtension("mov")
    }

    private nonisolated func temporaryCaptionURL() -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("Captions-\(UUID().uuidString)")
            .appendingPathExtension("mov")
    }

    private nonisolated func removeCaptionMovieParts(_ parts: [CaptionMoviePart]) {
        for part in parts {
            try? fileManager.removeItem(at: part.url)
        }
    }

    private nonisolated static func isValidCaptionTimeRange(_ range: CMTimeRange) -> Bool {
        CMTIME_IS_NUMERIC(range.start)
            && CMTIME_IS_NUMERIC(range.duration)
            && CMTimeCompare(range.duration, .zero) > 0
    }

    private nonisolated static func limitedCaptionChunks(
        text: String,
        segmentDuration: CMTime,
        frameDuration: CMTime
    ) -> [String] {
        let lines = CaptionTextLayout.normalizedParagraphs(from: text).flatMap {
            CaptionTextLayout.rowSizedLines(from: $0)
        }
        guard CMTimeCompare(segmentDuration, .zero) > 0 else { return [] }

        let frameSeconds = CMTimeGetSeconds(frameDuration)
        let segmentSeconds = CMTimeGetSeconds(segmentDuration)
        guard frameSeconds.isFinite, frameSeconds > 0, segmentSeconds.isFinite, segmentSeconds > 0 else {
            return lines
        }

        let maxChunks = max(1, Int(floor(segmentSeconds / frameSeconds)))
        if maxChunks == 1 || segmentSeconds / Double(max(lines.count, 1)) < frameSeconds {
            return [lines.joined(separator: " ")]
        }
        guard lines.count > maxChunks else { return lines }

        var merged: [String] = []
        let groupSize = Int(ceil(Double(lines.count) / Double(maxChunks)))
        var index = lines.startIndex
        while index < lines.endIndex {
            let end = lines.index(index, offsetBy: groupSize, limitedBy: lines.endIndex) ?? lines.endIndex
            merged.append(lines[index..<end].joined(separator: " "))
            index = end
        }
        return merged.filter { !$0.isEmpty }
    }

    private nonisolated static func splitCaptionTimeRange(
        start: CMTime,
        end: CMTime,
        frameDuration: CMTime
    ) -> [CMTimeRange] {
        let maxDuration = CMTime(
            seconds: maxCaptionDurationSeconds,
            preferredTimescale: frameDuration.timescale
        )
        guard end > start, maxDuration > frameDuration else {
            return [CMTimeRange(start: start, end: max(start + frameDuration, end))]
        }

        var ranges: [CMTimeRange] = []
        var currentStart = start
        while currentStart < end {
            var currentEnd = min(currentStart + maxDuration, end)
            if currentEnd <= currentStart {
                currentEnd = currentStart + frameDuration
            }
            ranges.append(CMTimeRange(start: currentStart, end: currentEnd))
            currentStart = currentEnd
        }
        return ranges
    }

    internal nonisolated static func captionChunkRanges(
        in captions: [AVCaption],
        maxCaptionsPerChunk: Int
    ) -> [Range<Int>] {
        guard !captions.isEmpty else { return [] }

        let count = captions.count
        let chunkCount = (count + maxCaptionsPerChunk - 1) / maxCaptionsPerChunk
        var chunkSizes = Array(repeating: count / chunkCount, count: chunkCount)
        let remainder = count % chunkCount
        if remainder > 0 {
            // Put the extra captions in the last chunks so earlier chunk boundaries
            // land on caption transitions instead of mid-display splices.
            for index in (chunkCount - remainder)..<chunkCount {
                chunkSizes[index] += 1
            }
        }

        var ranges: [Range<Int>] = []
        var chunkStart = captions.startIndex

        for (chunkIndex, targetSize) in chunkSizes.enumerated() {
            guard chunkStart < captions.endIndex else { break }

            let isLastChunk = chunkIndex == chunkSizes.count - 1
            var chunkEnd = isLastChunk
                ? captions.endIndex
                : captions.index(chunkStart, offsetBy: targetSize, limitedBy: captions.endIndex) ?? captions.endIndex

            if !isLastChunk, chunkEnd < captions.endIndex, chunkStart < captions.index(before: chunkEnd) {
                chunkEnd = preferredSplitIndex(in: captions, chunkStart: chunkStart, defaultEnd: chunkEnd)
            }

            ranges.append(chunkStart..<chunkEnd)
            chunkStart = chunkEnd
        }

        return ranges
    }

    private nonisolated static func preferredSplitIndex(
        in captions: [AVCaption],
        chunkStart: Int,
        defaultEnd: Int
    ) -> Int {
        guard chunkStart < defaultEnd else { return defaultEnd }

        var bestSplit = defaultEnd
        var bestGap = -Double.infinity
        var index = chunkStart + 1
        while index < defaultEnd {
            let gap = gapBetween(captions[index - 1], captions[index])
            if gap > bestGap {
                bestGap = gap
                bestSplit = index
            }
            index += 1
        }

        if bestGap >= minGapForCaptionChunkSplitSeconds, bestSplit > chunkStart {
            return bestSplit
        }
        return defaultEnd
    }

    private nonisolated static func gapBetween(_ previous: AVCaption, _ next: AVCaption) -> TimeInterval {
        CMTimeGetSeconds(CMTimeSubtract(next.timeRange.start, previous.timeRange.end))
    }

    private nonisolated static func localizedCaptionChunk(
        _ captions: ArraySlice<AVCaption>
    ) throws -> (timelineOffset: CMTime, captions: [AVCaption]) {
        guard let firstCaption = captions.first else {
            return (.zero, [])
        }

        let conformer = makeCaptionConformer(frameDuration: defaultFrameDuration)
        let startProbe = AVCaption(
            firstCaption.text,
            timeRange: CMTimeRange(
                start: defaultFrameDuration,
                duration: firstCaption.timeRange.duration
            )
        )
        let sourceStartTime: CMTime
        do {
            sourceStartTime = try conformer.conformedCaption(for: startProbe).timeRange.start
        } catch {
            throw CaptionEmbeddingError.captionConformanceFailed
        }

        let localizationOffset = max(firstCaption.timeRange.start - sourceStartTime, .zero)
        let localizedCaptions = captions.map { caption in
            let localStart = caption.timeRange.start - localizationOffset
            let localRange = CMTimeRange(start: localStart, duration: caption.timeRange.duration)
            return AVCaption(caption.text, timeRange: localRange)
        }
        return (localizationOffset, localizedCaptions)
    }

    private nonisolated static func makeCaptionConformer(
        frameDuration: CMTime
    ) -> AVCaptionFormatConformer {
        let settings: [AVCaptionSettingsKey: Any] = [
            .mediaType: AVMediaType.closedCaption,
            .mediaSubType: NSNumber(value: kCMClosedCaptionFormatType_CEA608),
            .timeCodeFrameDuration: NSValue(time: frameDuration)
        ]
        let conformer = AVCaptionFormatConformer(conversionSettings: settings)
        conformer.conformsCaptionsToTimeRange = true
        return conformer
    }

    private nonisolated static func captionLanguageTags(for locale: Locale) -> (languageCode: String, extendedLanguageTag: String) {
        let extendedLanguageTag = bcp47LanguageTag(for: locale)
        let iso639_1 = locale.language.languageCode?.identifier ?? extendedLanguageTag.prefix(2).lowercased()
        let languageCode: String
        switch iso639_1 {
        case "en": languageCode = "eng"
        case "es": languageCode = "spa"
        case "ca": languageCode = "cat"
        case "fr": languageCode = "fra"
        case "de": languageCode = "deu"
        case "it": languageCode = "ita"
        case "pt": languageCode = "por"
        case "ja": languageCode = "jpn"
        case "ko": languageCode = "kor"
        case "zh": languageCode = "zho"
        default:
            languageCode = "und"
        }
        return (languageCode, extendedLanguageTag)
    }

    private nonisolated static func bcp47LanguageTag(for locale: Locale) -> String {
        guard let languageCode = locale.language.languageCode?.identifier else {
            return locale.identifier.replacingOccurrences(of: "_", with: "-")
        }
        guard let regionCode = locale.region?.identifier else {
            return languageCode
        }
        return "\(languageCode)-\(regionCode)"
    }

    private nonisolated static func hasDefinedLanguageCode(_ languageCode: String?) -> Bool {
        guard let languageCode, !languageCode.isEmpty else { return false }
        return languageCode != undefinedLanguageCode
    }

    private nonisolated static func hasDefinedLanguageTag(_ languageTag: String?) -> Bool {
        guard let languageTag, !languageTag.isEmpty else { return false }
        return languageTag != undefinedLanguageCode
    }

    private nonisolated static func alignedTime(
        seconds: TimeInterval,
        frameDuration: CMTime,
        rounding: FloatingPointRoundingRule
    ) -> CMTime {
        guard seconds.isFinite, seconds > 0 else {
            return .zero
        }

        let frameSeconds = CMTimeGetSeconds(frameDuration)
        guard frameSeconds.isFinite, frameSeconds > 0 else {
            return frameDuration
        }

        let frameCount = (seconds / frameSeconds).rounded(rounding)
        return CMTimeMultiply(frameDuration, multiplier: Int32(max(frameCount, 1)))
    }

    private nonisolated static func formatLogTimestamp(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0.000" }
        return String(format: "%.3f", seconds)
    }
}
