import Foundation
import AVFoundation

@available(macOS 26, *)
nonisolated final class CaptionEmbedder: Sendable {
    /// Checked-Sendable representation used at every task boundary. AVCaption
    /// instances are constructed only inside the task that passes them to AVFoundation.
    private struct CaptionEvent: Sendable {
        let text: String
        let timeRange: CMTimeRange
    }

    private struct CaptionMoviePart: Sendable {
        let url: URL
        /// Global timeline position where the chunk's first visible caption should appear.
        let insertTime: CMTime
        /// Source-track time to trim leading CEA-608 preroll before inserting.
        let sourceTrimStart: CMTime
    }

    private static let defaultFrameDuration = CMTime(value: 1001, timescale: 30_000)
    private static let defaultEmbeddingStepTimeout: TimeInterval = 10
    private static let maxCaptionDurationSeconds: TimeInterval = 3
    private static let maxCaptionsPerCaptionMovie = 4
    private static let minGapForCaptionChunkSplitSeconds: TimeInterval = 0.25
    private static let undefinedLanguageCode = "und"
    private let embeddingStepTimeout: TimeInterval
    private let embeddingCleanupScheduler: CaptionEmbeddingTimeout.CleanupScheduler
    private let captionLanguageCode: String
    private let captionExtendedLanguageTag: String

    nonisolated init(
        embeddingStepTimeout: TimeInterval = CaptionEmbedder.defaultEmbeddingStepTimeout,
        locale: Locale = Locale(identifier: "en-US"),
        embeddingCleanupScheduler: CaptionEmbeddingTimeout.CleanupScheduler = CaptionEmbeddingTimeout.sharedCleanupScheduler
    ) {
        self.embeddingStepTimeout = embeddingStepTimeout
        self.embeddingCleanupScheduler = embeddingCleanupScheduler
        let tags = Self.captionLanguageTags(for: locale)
        self.captionLanguageCode = tags.languageCode
        self.captionExtendedLanguageTag = tags.extendedLanguageTag
    }

    @concurrent func estimatedEmbeddingTimeout(
        for segments: [CaptionSegment],
        into _: URL
    ) async throws -> TimeInterval {
        // An uncapped canonical count is a conservative upper bound that avoids
        // loading the asset or running AVFoundation caption conformance twice.
        let captionEvents = makeCanonicalCaptionEvents(
            from: segments,
            frameDuration: Self.defaultFrameDuration
        )
        guard !captionEvents.isEmpty else {
            return CaptionEmbeddingTimeoutBudget.totalTimeout(
                chunkCount: 0,
                perStepTimeout: embeddingStepTimeout
            )
        }
        let chunkRanges = Self.captionChunkRanges(
            in: captionEvents,
            maxCaptionsPerChunk: Self.maxCaptionsPerCaptionMovie
        )
        return CaptionEmbeddingTimeoutBudget.totalTimeout(
            chunkCount: chunkRanges.count,
            perStepTimeout: embeddingStepTimeout
        )
    }

    @concurrent func embedClosedCaptions(
        from segments: [CaptionSegment],
        into videoURL: URL,
        cancellation: CaptionEmbeddingCancellationHolder? = nil,
        progressHandler: (@Sendable (Float) -> Void)? = nil
    ) async throws -> URL {
        log("Starting caption embedding into \(videoURL.lastPathComponent)")
        logGeneratedSegments(segments)
        logFileSize(at: videoURL, label: "Source")

        let captionEvents = makeCanonicalCaptionEvents(
            from: segments,
            maxTimelineEnd: try await sourceVideoDuration(for: videoURL)
        )
        guard !captionEvents.isEmpty else { throw CaptionEmbeddingError.noTracksToCopy }

        let outputURL = temporaryOutputURL()
        try? FileManager.default.removeItem(at: outputURL)
        let temporaryFiles = CaptionEmbeddingTemporaryFiles()
        temporaryFiles.register(outputURL)
        let rootOperationLease = temporaryFiles.beginOperation()
        let finishRootOperation: @Sendable () -> Void = {
            temporaryFiles.requestCleanup()
            rootOperationLease.finish()
        }

        let ownsTimeout = cancellation == nil
        let cancellationHolder = cancellation ?? CaptionEmbeddingCancellationHolder()
        guard cancellationHolder.setTemporaryFiles(temporaryFiles) else {
            finishRootOperation()
            throw CancellationError()
        }
        defer { cancellationHolder.clearTemporaryFiles(temporaryFiles) }
        let chunkCount = Self.captionChunkRanges(
            in: captionEvents,
            maxCaptionsPerChunk: Self.maxCaptionsPerCaptionMovie
        ).count
        let totalTimeout = CaptionEmbeddingTimeoutBudget.totalTimeout(
            chunkCount: chunkCount,
            perStepTimeout: embeddingStepTimeout
        )

        let operation: @Sendable () async throws -> URL = { [self] in
            log("Prepared \(captionEvents.count) caption event(s)")

            let captionMovieParts = try await writeCaptionTrackMovies(
                captionEvents: captionEvents,
                cancellationHolder: cancellationHolder,
                temporaryFiles: temporaryFiles
            )

            try await runEmbeddingStep(
                named: "Captioned movie export",
                cancellationHolder: cancellationHolder,
                temporaryFiles: temporaryFiles
            ) {
                try await self.composeAndExport(
                    videoURL: videoURL,
                    captionMovieParts: captionMovieParts,
                    outputURL: outputURL,
                    cancellationHolder: cancellationHolder,
                    progressHandler: progressHandler
                )
            }
            try Task.checkCancellation()
            temporaryFiles.remove(captionMovieParts.map(\.url))
            temporaryFiles.preserve(outputURL)
            logFileSize(at: outputURL, label: "Output")
            log("Caption embedding completed: \(outputURL.lastPathComponent)")
            return outputURL
        }

        do {
            guard ownsTimeout else {
                defer { finishRootOperation() }
                return try await operation()
            }
            return try await CaptionEmbeddingTimeout.run(
                seconds: totalTimeout,
                cleanupScheduler: embeddingCleanupScheduler,
                cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                    prepare: {
                        return cancellationHolder.prepareCancellation()
                    },
                    perform: { [self] reason in
                        if reason == .timeout {
                            log("Caption embedding timed out after \(Int(totalTimeout))s; cancelling AVFoundation work")
                        }
                        cancellationHolder.performPreparedCancellation()
                    }
                ),
                discardedSuccessCleanup: { url in
                    try? FileManager.default.removeItem(at: url)
                },
                operationCompletion: finishRootOperation,
                operation: operation
            )
        } catch {
            log("Caption embedding aborted: \(error.localizedDescription)")
            throw error
        }
    }

    private nonisolated func writeCaptionTrackMovies(
        captionEvents: [CaptionEvent],
        cancellationHolder: CaptionEmbeddingCancellationHolder,
        temporaryFiles: CaptionEmbeddingTemporaryFiles
    ) async throws -> [CaptionMoviePart] {
        var parts: [CaptionMoviePart] = []

        let chunkRanges = Self.captionChunkRanges(
            in: captionEvents,
            maxCaptionsPerChunk: Self.maxCaptionsPerCaptionMovie
        )
        for (chunkIndex, range) in chunkRanges.enumerated() {
            try Task.checkCancellation()
            let localized = try Self.localizedCaptionChunk(captionEvents[range])
            let url = temporaryCaptionURL()
            try? FileManager.default.removeItem(at: url)
            temporaryFiles.register(url)

            log(
                "Caption movie chunk \(chunkIndex + 1): writing \(localized.events.count) caption(s) with timeline offset \(Self.formatLogTimestamp(CMTimeGetSeconds(localized.timelineOffset)))s"
            )
            try await runEmbeddingStep(
                named: "Caption movie chunk \(chunkIndex + 1)",
                cancellationHolder: cancellationHolder,
                temporaryFiles: temporaryFiles
            ) {
                try await self.writeCaptionTrackMovie(
                    captionEvents: localized.events,
                    to: url,
                    cancellationHolder: cancellationHolder
                )
            }
            let chunkCaptions = Array(captionEvents[range])
            guard let firstOriginal = chunkCaptions.first,
                  let firstLocalized = localized.events.first else {
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
    }

    nonisolated func runEmbeddingStep<Value: Sendable>(
        named stepName: String,
        cancellationHolder: CaptionEmbeddingCancellationHolder,
        temporaryFiles: CaptionEmbeddingTemporaryFiles,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let operationLease = temporaryFiles.beginOperation()
        return try await CaptionEmbeddingTimeout.run(
            seconds: embeddingStepTimeout,
            cleanupScheduler: embeddingCleanupScheduler,
            cleanupPlan: CaptionEmbeddingTimeout.CleanupPlan(
                prepare: {
                    return cancellationHolder.prepareCancellation()
                },
                perform: { [self] reason in
                    if reason == .timeout {
                        log("\(stepName) timed out after \(Int(embeddingStepTimeout))s; cancelling AVFoundation work")
                    }
                    cancellationHolder.performPreparedCancellation()
                }
            ),
            operationCompletion: {
                operationLease.finish()
            },
            operation: operation
        )
    }

    private nonisolated func writeCaptionTrackMovie(
        captionEvents: [CaptionEvent],
        to url: URL,
        cancellationHolder: CaptionEmbeddingCancellationHolder
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        guard cancellationHolder.setWriter(writer) else {
            throw CancellationError()
        }
        defer { cancellationHolder.clearWriter(writer) }
        try Task.checkCancellation()

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

        let conformedCaptions = try makeConformedCaptions(from: captionEvents)
        logConformedCaptions(count: conformedCaptions.count)
        log("Caption movie: appending \(conformedCaptions.count) caption(s)")
        for (index, caption) in conformedCaptions.enumerated() {
            try Task.checkCancellation()
            log("Caption movie: appending \(index + 1)/\(conformedCaptions.count)")
            try await receiver.append(caption)
            log("Caption movie: appended \(index + 1)/\(conformedCaptions.count)")
        }
        receiver.finish()

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CaptionEmbeddingError.cannotStartWriter
        }
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
        guard cancellationHolder.setExportSession(export) else {
            throw CancellationError()
        }
        defer { cancellationHolder.clearExportSession(export) }
        try Task.checkCancellation()

        log("Exporting captioned movie (passthrough, no network optimization)")
        let progressTask = Task { @concurrent in
            while !Task.isCancelled {
                guard let progress = cancellationHolder.exportProgress() else { break }
                progressHandler?(progress)
                if progress >= 1 {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        do {
            try await export.export(to: outputURL, as: .mov)
        } catch {
            progressTask.cancel()
            await progressTask.value
            throw error
        }
        progressTask.cancel()
        await progressTask.value
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

    nonisolated func makeClosedCaptions(
        from segments: [CaptionSegment],
        frameDuration: CMTime = CaptionEmbedder.defaultFrameDuration,
        maxTimelineEnd: CMTime? = nil
    ) throws -> [AVCaption] {
        let captionEvents = makeCanonicalCaptionEvents(
            from: segments,
            frameDuration: frameDuration,
            maxTimelineEnd: maxTimelineEnd
        )
        return try makeConformedCaptions(from: captionEvents, frameDuration: frameDuration)
    }

    private nonisolated func makeConformedCaptions(
        from captionEvents: [CaptionEvent],
        frameDuration: CMTime = CaptionEmbedder.defaultFrameDuration
    ) throws -> [AVCaption] {
        let conformer = Self.makeCaptionConformer(frameDuration: frameDuration)

        return try captionEvents.map { event in
            do {
                let caption = AVCaption(event.text, timeRange: event.timeRange)
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

    private nonisolated func makeCanonicalCaptionEvents(
        from segments: [CaptionSegment],
        frameDuration: CMTime = CaptionEmbedder.defaultFrameDuration,
        maxTimelineEnd: CMTime? = nil
    ) -> [CaptionEvent] {
        var captionEvents: [CaptionEvent] = []
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
                    captionEvents.append(CaptionEvent(text: chunk, timeRange: timeRange))
                    previousEnd = timeRange.end
                }
            }
        }

        return captionEvents
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

    private nonisolated func logConformedCaptions(count: Int) {
        log("Conformed \(count) caption event(s)")
    }

    private nonisolated func logFileSize(at url: URL, label: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
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
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Recording-\(UUID().uuidString)")
            .appendingPathExtension("mov")
    }

    private nonisolated func temporaryCaptionURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Captions-\(UUID().uuidString)")
            .appendingPathExtension("mov")
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
        captionChunkRanges(
            in: captions.map { CaptionEvent(text: $0.text, timeRange: $0.timeRange) },
            maxCaptionsPerChunk: maxCaptionsPerChunk
        )
    }

    private nonisolated static func captionChunkRanges(
        in captionEvents: [CaptionEvent],
        maxCaptionsPerChunk: Int
    ) -> [Range<Int>] {
        guard !captionEvents.isEmpty else { return [] }

        let count = captionEvents.count
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
        var chunkStart = captionEvents.startIndex

        for (chunkIndex, targetSize) in chunkSizes.enumerated() {
            guard chunkStart < captionEvents.endIndex else { break }

            let isLastChunk = chunkIndex == chunkSizes.count - 1
            var chunkEnd = isLastChunk
                ? captionEvents.endIndex
                : captionEvents.index(
                    chunkStart,
                    offsetBy: targetSize,
                    limitedBy: captionEvents.endIndex
                ) ?? captionEvents.endIndex

            if !isLastChunk,
               chunkEnd < captionEvents.endIndex,
               chunkStart < captionEvents.index(before: chunkEnd) {
                chunkEnd = preferredSplitIndex(
                    in: captionEvents,
                    chunkStart: chunkStart,
                    defaultEnd: chunkEnd
                )
            }

            ranges.append(chunkStart..<chunkEnd)
            chunkStart = chunkEnd
        }

        return ranges
    }

    private nonisolated static func preferredSplitIndex(
        in captionEvents: [CaptionEvent],
        chunkStart: Int,
        defaultEnd: Int
    ) -> Int {
        guard chunkStart < defaultEnd else { return defaultEnd }

        var bestSplit = defaultEnd
        var bestGap = -Double.infinity
        var index = chunkStart + 1
        while index < defaultEnd {
            let gap = gapBetween(captionEvents[index - 1], captionEvents[index])
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

    private nonisolated static func gapBetween(
        _ previous: CaptionEvent,
        _ next: CaptionEvent
    ) -> TimeInterval {
        CMTimeGetSeconds(CMTimeSubtract(next.timeRange.start, previous.timeRange.end))
    }

    private nonisolated static func localizedCaptionChunk(
        _ captionEvents: ArraySlice<CaptionEvent>
    ) throws -> (timelineOffset: CMTime, events: [CaptionEvent]) {
        guard let firstCaption = captionEvents.first else {
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
        let localizedEvents = captionEvents.map { caption in
            let localStart = caption.timeRange.start - localizationOffset
            let localRange = CMTimeRange(start: localStart, duration: caption.timeRange.duration)
            return CaptionEvent(text: caption.text, timeRange: localRange)
        }
        return (localizationOffset, localizedEvents)
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
