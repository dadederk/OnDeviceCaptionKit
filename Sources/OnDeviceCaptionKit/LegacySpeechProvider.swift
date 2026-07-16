import AVFoundation
import Foundation
import NaturalLanguage
import Speech

public protocol CaptionRecognitionProvider: Sendable {
    var providerID: CaptionRecognitionProviderID { get }

    func transcribe(
        from audioURL: URL,
        locale: Locale,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> [CaptionSegment]
}

struct LegacySpeechProvider: CaptionRecognitionProvider {
    let providerID: CaptionRecognitionProviderID = .legacy

    private let speechAuthorizationProvider: any SpeechAuthorizationProviding
    private let requestFactory: any LegacySpeechURLRecognitionRequestMaking
    private let minimumSegmentDuration: TimeInterval = 1.0
    private let maximumSegmentDuration: TimeInterval = 8.0

    init(
        speechAuthorizationProvider: any SpeechAuthorizationProviding = SystemSpeechAuthorizationProvider(),
        requestFactory: any LegacySpeechURLRecognitionRequestMaking = ProductionLegacySpeechURLRecognitionRequestFactory()
    ) {
        self.speechAuthorizationProvider = speechAuthorizationProvider
        self.requestFactory = requestFactory
    }

    func transcribe(
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

        final class RecognitionTaskBox: @unchecked Sendable {
            var task: SFSpeechRecognitionTask?
        }
        let taskBox = RecognitionTaskBox()
        let progressState = ProgressTracker()

        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LegacyRecognitionSnapshot, Error>) in
                var hasResumed = false
                taskBox.task = speechRecognizer.recognitionTask(with: request) { result, error in
                    guard !hasResumed else { return }
                    if let error {
                        hasResumed = true
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let result else {
                        hasResumed = true
                        continuation.resume(throwing: CaptionError.recognitionFailed)
                        return
                    }
                    if durationSeconds > 0, let progressHandler {
                        let latestTimestamp = result.bestTranscription.segments.last?.timestamp ?? 0
                        CaptionTranscriptionProgress.reportStreamProgress(
                            processedSeconds: latestTimestamp,
                            totalSeconds: durationSeconds,
                            lastReported: &progressState.lastReported,
                            handler: progressHandler
                        )
                    }
                    if result.isFinal {
                        hasResumed = true
                        continuation.resume(returning: LegacyRecognitionSnapshot(result: result))
                    }
                }
            }
        } onCancel: {
            taskBox.task?.cancel()
        }

        CaptionTranscriptionProgress.reportFinalizing(progressHandler)
        let segments = try await processRecognitionResult(result, duration: durationSeconds)
        CaptionTranscriptionProgress.reportComplete(progressHandler)
        return segments
    }

    private func processRecognitionResult(_ result: LegacyRecognitionSnapshot, duration: TimeInterval) async throws -> [CaptionSegment] {
        var allSegments: [LegacyTranscriptionSegmentSnapshot] = []

        for segment in result.segments {
            let startTime = segment.timestamp
            let endTime = startTime + segment.duration
            allSegments.append(
                LegacyTranscriptionSegmentSnapshot(
                    substring: segment.substring,
                    startTime: startTime,
                    endTime: endTime
                )
            )
        }

        let completeTranscript = allSegments.map(\.substring).joined(separator: " ")
        let sentenceBoundaries = try await identifySentenceBoundaries(in: completeTranscript, segments: allSegments)

        var segments: [CaptionSegment] = []
        var segmentIndex = 1
        var currentSegmentStart: TimeInterval = 0
        var currentSegmentText = ""

        for (index, segment) in allSegments.enumerated() {
            let isSentenceBoundary = sentenceBoundaries.contains(index)
            let hasPause = index > 0 ? hasSignificantPause(before: segment, after: allSegments[index - 1]) : false
            currentSegmentText += (currentSegmentText.isEmpty ? "" : " ") + segment.substring

            let shouldEndSegment = isSentenceBoundary || hasPause ||
                (segment.endTime - currentSegmentStart) > maximumSegmentDuration

            if shouldEndSegment && !currentSegmentText.isEmpty {
                segments.append(
                    CaptionSegment(
                        index: segmentIndex,
                        startTime: currentSegmentStart,
                        endTime: segment.endTime,
                        text: formatSubtitleText(currentSegmentText.trimmingCharacters(in: .whitespacesAndNewlines))
                    )
                )
                segmentIndex += 1
                currentSegmentStart = segment.endTime
                currentSegmentText = ""
            }
        }

        if !currentSegmentText.isEmpty {
            segments.append(
                CaptionSegment(
                    index: segmentIndex,
                    startTime: currentSegmentStart,
                    endTime: duration,
                    text: formatSubtitleText(currentSegmentText.trimmingCharacters(in: .whitespacesAndNewlines))
                )
            )
        }

        return segments.filter { !$0.text.isEmpty && $0.duration >= minimumSegmentDuration }
    }

    private func identifySentenceBoundaries(
        in transcript: String,
        segments: [LegacyTranscriptionSegmentSnapshot]
    ) async throws -> [Int] {
        let tagger = NLTagger(tagSchemes: [.tokenType, .lexicalClass, .nameType])
        tagger.string = transcript

        var sentenceBoundaries: [Int] = []
        var currentWordCount = 0

        tagger.enumerateTags(in: transcript.startIndex..<transcript.endIndex, unit: .sentence, scheme: .tokenType) { _, tokenRange in
            let sentenceText = String(transcript[tokenRange])
            let wordsInSentence = sentenceText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

            var wordCount = 0
            for (index, segment) in segments.enumerated() {
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

        return sentenceBoundaries
    }

    private func hasSignificantPause(
        before: LegacyTranscriptionSegmentSnapshot,
        after: LegacyTranscriptionSegmentSnapshot
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

extension LegacySpeechProvider: @unchecked Sendable {}

private struct LegacyRecognitionSnapshot: Sendable {
    let segments: [LegacyTranscriptionSegmentSnapshot]

    init(result: SFSpeechRecognitionResult) {
        segments = result.bestTranscription.segments.map { segment in
            LegacyTranscriptionSegmentSnapshot(
                substring: segment.substring,
                startTime: segment.timestamp,
                endTime: segment.timestamp + segment.duration
            )
        }
    }
}

private struct LegacyTranscriptionSegmentSnapshot: Sendable {
    let substring: String
    let startTime: TimeInterval
    let endTime: TimeInterval

    var timestamp: TimeInterval {
        startTime
    }

    var duration: TimeInterval {
        endTime - startTime
    }
}

private final class ProgressTracker: @unchecked Sendable {
    var lastReported = 0.0
}
