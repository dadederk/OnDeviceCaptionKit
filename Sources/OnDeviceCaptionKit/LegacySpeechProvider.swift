import AVFoundation
import Foundation
import NaturalLanguage
import Speech
import Synchronization

public protocol CaptionRecognitionProvider: Sendable {
    var providerID: CaptionRecognitionProviderID { get }

    @concurrent func transcribe(
        from audioURL: URL,
        locale: Locale,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> [CaptionSegment]
}

struct LegacySpeechProvider: CaptionRecognitionProvider {
    let providerID: CaptionRecognitionProviderID = .legacy

    private let speechAuthorizationProvider: any SpeechAuthorizationProviding
    private let requestFactory: any LegacySpeechURLRecognitionRequestMaking
    private let maximumSegmentDuration: TimeInterval = 5.0
    private let maximumSegmentCharacters = 64

    init(
        speechAuthorizationProvider: any SpeechAuthorizationProviding = SystemSpeechAuthorizationProvider(),
        requestFactory: any LegacySpeechURLRecognitionRequestMaking = ProductionLegacySpeechURLRecognitionRequestFactory()
    ) {
        self.speechAuthorizationProvider = speechAuthorizationProvider
        self.requestFactory = requestFactory
    }

    @concurrent func transcribe(
        from audioURL: URL,
        locale: Locale,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [CaptionSegment] {
        CaptionLogger.info("Starting legacy transcription from audio file")
        let segments = try await performSpeechRecognition(on: audioURL, locale: locale, progressHandler: progressHandler)
        CaptionLogger.info("Legacy transcription completed with \(segments.count) segment(s)")
        return segments
    }

    private func ensureSpeechAuthorization() async throws {
        let status = await speechAuthorizationProvider.requestAuthorization()
        switch status {
        case .authorized:
            CaptionLogger.info("Speech recognition authorized")
        case .denied, .restricted, .notDetermined:
            throw CaptionError.speechAuthorizationDenied
        @unknown default:
            throw CaptionError.speechAuthorizationDenied
        }
    }

    private func performSpeechRecognition(
        on audioURL: URL,
        locale: Locale,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [CaptionSegment] {
        try await ensureSpeechAuthorization()

        guard let speechRecognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw CaptionError.speechRecognizerNotAvailable
        }
        guard speechRecognizer.isAvailable else {
            throw CaptionError.speechRecognizerNotAvailable
        }

        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        CaptionLogger.info("Audio duration: \(String(format: "%.1f", durationSeconds)) seconds")

        let request = requestFactory.makeRequest(url: audioURL)
        request.shouldReportPartialResults = progressHandler != nil
        request.taskHint = .dictation
        request.addsPunctuation = true

        let recognitionBridge = LegacySpeechRecognitionBridge()
        let progressState = ProgressTracker()

        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard recognitionBridge.install(continuation: continuation) else {
                    return
                }
                guard !Task.isCancelled else {
                    recognitionBridge.cancel()
                    return
                }
                let task = speechRecognizer.recognitionTask(with: request) { result, error in
                    guard recognitionBridge.shouldProcessCallback() else { return }
                    if let error {
                        recognitionBridge.resume(throwing: error)
                        return
                    }
                    guard let result else {
                        recognitionBridge.resume(throwing: CaptionError.recognitionFailed)
                        return
                    }
                    if durationSeconds > 0, let progressHandler {
                        let latestTimestamp = result.bestTranscription.segments.last?.timestamp ?? 0
                        progressState.report(
                            processedSeconds: latestTimestamp,
                            totalSeconds: durationSeconds,
                            handler: progressHandler
                        )
                    }
                    if result.isFinal {
                        recognitionBridge.resume(
                            returning: LegacySpeechRecognitionSnapshot(result: result)
                        )
                    }
                }
                recognitionBridge.install(task: task)
            }
        } onCancel: {
            recognitionBridge.cancel()
        }

        try Task.checkCancellation()
        CaptionTranscriptionProgress.reportFinalizing(progressHandler)
        if let first = result.segments.first, let last = result.segments.last {
            let recognizedStart = String(format: "%.2f", first.startTime)
            let recognizedEnd = String(format: "%.2f", last.endTime)
            CaptionLogger.info(
                "Legacy recognition finalized with \(result.segments.count) timed token(s), "
                    + "recognized range \(recognizedStart)s–\(recognizedEnd)s"
            )
        } else {
            CaptionLogger.info("Legacy recognition finalized without timed tokens")
        }
        let segments = try await processRecognitionResult(result, duration: durationSeconds)
        try Task.checkCancellation()
        CaptionTranscriptionProgress.reportComplete(progressHandler)
        return segments
    }

    func processRecognitionResult(
        _ result: LegacySpeechRecognitionSnapshot,
        duration: TimeInterval
    ) async throws -> [CaptionSegment] {
        try Task.checkCancellation()
        let allSegments = result.segments
        let completeTranscript = allSegments.map(\.substring).joined(separator: " ")
        let sentenceBoundaries = try await identifySentenceBoundaries(in: completeTranscript, segments: allSegments)

        var segments: [CaptionSegment] = []
        var segmentIndex = 1
        var currentSegmentStart: TimeInterval?
        var currentSegmentText = ""

        for (index, segment) in allSegments.enumerated() {
            try Task.checkCancellation()
            let isSentenceBoundary = sentenceBoundaries.contains(index)
            let hasPause = index > 0 ? hasSignificantPause(
                before: allSegments[index - 1],
                after: segment
            ) : false
            let candidateText = currentSegmentText
                + (currentSegmentText.isEmpty ? "" : " ")
                + segment.substring
            let exceedsReadableLength = !currentSegmentText.isEmpty
                && candidateText.count > maximumSegmentCharacters
            if hasPause || exceedsReadableLength {
                appendCaption(
                    to: &segments,
                    index: &segmentIndex,
                    startTime: currentSegmentStart,
                    endTime: allSegments[index - 1].endTime,
                    text: &currentSegmentText
                )
                currentSegmentStart = nil
            }
            if currentSegmentStart == nil {
                currentSegmentStart = segment.startTime
            }
            currentSegmentText += (currentSegmentText.isEmpty ? "" : " ") + segment.substring

            let segmentDuration = segment.endTime - (currentSegmentStart ?? segment.startTime)
            let shouldEndSegment = isSentenceBoundary || segmentDuration >= maximumSegmentDuration

            if shouldEndSegment && !currentSegmentText.isEmpty {
                appendCaption(
                    to: &segments,
                    index: &segmentIndex,
                    startTime: currentSegmentStart,
                    endTime: segment.endTime,
                    text: &currentSegmentText
                )
                currentSegmentStart = nil
            }
        }

        if !currentSegmentText.isEmpty {
            appendCaption(
                to: &segments,
                index: &segmentIndex,
                startTime: currentSegmentStart,
                endTime: min(duration, allSegments.last?.endTime ?? duration),
                text: &currentSegmentText
            )
        }

        return segments
    }

    private func appendCaption(
        to captions: inout [CaptionSegment],
        index: inout Int,
        startTime: TimeInterval?,
        endTime: TimeInterval,
        text: inout String
    ) {
        let formattedText = formatSubtitleText(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let startTime, !formattedText.isEmpty, endTime > startTime else {
            text = ""
            return
        }
        captions.append(
            CaptionSegment(
                index: index,
                startTime: startTime,
                endTime: endTime,
                text: formattedText
            )
        )
        index += 1
        text = ""
    }

    private func identifySentenceBoundaries(
        in transcript: String,
        segments: [LegacySpeechRecognitionSnapshot.Segment]
    ) async throws -> [Int] {
        let tagger = NLTagger(tagSchemes: [.tokenType, .lexicalClass, .nameType])
        tagger.string = transcript

        var sentenceBoundaries: [Int] = []
        var currentWordCount = 0
        var wasCancelled = false

        tagger.enumerateTags(in: transcript.startIndex..<transcript.endIndex, unit: .sentence, scheme: .tokenType) { _, tokenRange in
            guard !Task.isCancelled else {
                wasCancelled = true
                return false
            }
            let sentenceText = String(transcript[tokenRange])
            let wordsInSentence = sentenceText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

            var wordCount = 0
            for (index, segment) in segments.enumerated() {
                guard !Task.isCancelled else {
                    wasCancelled = true
                    return false
                }
                let segmentWords = segment.substring.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                wordCount += segmentWords.count
                if wordCount >= currentWordCount + wordsInSentence.count {
                    sentenceBoundaries.append(index)
                    break
                }
            }

            currentWordCount += wordsInSentence.count
            return true
        }

        if wasCancelled {
            throw CancellationError()
        }
        return sentenceBoundaries
    }

    private func hasSignificantPause(
        before: LegacySpeechRecognitionSnapshot.Segment,
        after: LegacySpeechRecognitionSnapshot.Segment
    ) -> Bool {
        (after.startTime - before.endTime) > 0.5
    }

    private func formatSubtitleText(_ text: String) -> String {
        var formattedText = text
        formattedText = formattedText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        formattedText = formattedText.replacingOccurrences(of: "\\s*([.!?,;:])\\s*", with: "$1 ", options: .regularExpression)

        if let firstChar = formattedText.first, firstChar.isLowercase {
            formattedText = String(firstChar).uppercased() + formattedText.dropFirst()
        }

        let trimmedText = formattedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty && !trimmedText.hasSuffix(".") && !trimmedText.hasSuffix("!") && !trimmedText.hasSuffix("?") {
            formattedText = trimmedText + "."
        }

        return formattedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LegacySpeechRecognitionSnapshot: Sendable {
    struct Segment: Sendable {
        let substring: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    let segments: [Segment]

    init(segments: [Segment]) {
        self.segments = segments
    }

    init(result: SFSpeechRecognitionResult) {
        self.segments = result.bestTranscription.segments.map { segment in
            Segment(
                substring: segment.substring,
                startTime: segment.timestamp,
                endTime: segment.timestamp + segment.duration
            )
        }
    }
}

/// SFSpeechRecognitionTask is not Sendable. The bridge protects every access
/// to it and the continuation with one lock, and resumes at most once.
final class LegacySpeechRecognitionBridge: Sendable {
    /// `SFSpeechRecognitionTask` has no Sendable conformance. The wrapper is
    /// immutable and the bridge's mutex is the sole owner after installation.
    /// Remove this escape hatch when Speech exposes a Sendable task handle.
    private struct SpeechTask: @unchecked Sendable {
        let value: SFSpeechRecognitionTask
    }

    private struct State: ~Copyable {
        var continuation: CheckedContinuation<LegacySpeechRecognitionSnapshot, Error>?
        var task: SpeechTask?
        var isFinished = false
    }

    private let state = Mutex(State())

    func install(
        continuation: CheckedContinuation<LegacySpeechRecognitionSnapshot, Error>
    ) -> Bool {
        let shouldCancel = state.withLock { state in
            guard !state.isFinished else { return true }
            state.continuation = continuation
            return false
        }
        if shouldCancel {
            continuation.resume(throwing: CancellationError())
            return false
        }
        return true
    }

    func install(task: SFSpeechRecognitionTask) {
        let task = SpeechTask(value: task)
        let shouldCancel = state.withLock { state in
            guard !state.isFinished else { return true }
            state.task = task
            return false
        }
        if shouldCancel {
            task.value.cancel()
        }
    }

    func shouldProcessCallback() -> Bool {
        state.withLock { !$0.isFinished }
    }

    func resume(returning snapshot: LegacySpeechRecognitionSnapshot) {
        finish(with: .success(snapshot), cancelTask: false)
    }

    func resume(throwing error: Error) {
        finish(with: .failure(error), cancelTask: true)
    }

    func cancel() {
        finish(with: .failure(CancellationError()), cancelTask: true)
    }

    private func finish(
        with result: sending Result<LegacySpeechRecognitionSnapshot, Error>,
        cancelTask: Bool
    ) {
        let completion = state.withLock { state -> (
            CheckedContinuation<LegacySpeechRecognitionSnapshot, Error>?,
            SpeechTask?
        ) in
            guard !state.isFinished else { return (nil, nil) }
            state.isFinished = true
            let continuation = state.continuation
            let task = state.task
            state.continuation = nil
            state.task = nil
            return (continuation, task)
        }
        if cancelTask {
            completion.1?.value.cancel()
        }
        completion.0?.resume(with: result)
    }
}

private final class ProgressTracker: Sendable {
    private let lastReported = Mutex(0.0)

    func report(
        processedSeconds: TimeInterval,
        totalSeconds: TimeInterval,
        handler: @Sendable (Double) -> Void
    ) {
        let progress = CaptionTranscriptionProgress.streamProgress(
            processedSeconds: processedSeconds,
            totalSeconds: totalSeconds
        )
        let progressToReport = lastReported.withLock { lastReported in
            CaptionTranscriptionProgress.progressToReport(
                progress,
                lastReported: &lastReported
            )
        }
        if let progressToReport {
            handler(progressToReport)
        }
    }
}
