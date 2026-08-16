import AVFoundation
import CoreMedia
import Foundation

@available(macOS 26, *)
enum Tx3gCaptionError: Error, Equatable {
    case noCaptionTracks
    case invalidPresentationSize
    case cannotCreateFormatDescription(OSStatus)
    case textSampleTooLarge
    case cannotAddInput
    case cannotAddInputGroup
    case cannotStartWriter
    case writerFailed
}

@available(macOS 26, *)
struct Tx3gCaptionTrackWriter: Sendable {
    private struct PreparedTrack {
        let input: AVAssetWriterInput
        let formatDescription: CMFormatDescription
        let samples: [Sample]
    }

    private struct Sample: Sendable {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    private struct TrackWriterState {
        let receiver: AVAssetWriterInput.SampleBufferReceiver
        let formatDescription: CMFormatDescription
        let samples: [Sample]
        var nextSampleIndex = 0
        var pendingSample: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>?
        var isFinished = false
        var appendedSampleCount = 0
    }

    @concurrent
    func write(
        tracks: [CaptionLanguageTrack],
        to outputURL: URL,
        presentationSize: CGSize,
        terminalPadding: TimeInterval = 0
    ) async throws {
        let presentationSize = try Self.validated(presentationSize: presentationSize)
        let preparedTracks = try tracks.compactMap {
            try Self.prepareTrack(
                $0,
                presentationSize: presentationSize,
                terminalPadding: terminalPadding
            )
        }
        guard !preparedTracks.isEmpty else { throw Tx3gCaptionError.noCaptionTracks }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        for preparedTrack in preparedTracks {
            guard writer.canAdd(preparedTrack.input) else { throw Tx3gCaptionError.cannotAddInput }
            writer.add(preparedTrack.input)
        }
        if preparedTracks.count > 1 {
            let group = AVAssetWriterInputGroup(
                inputs: preparedTracks.map(\.input),
                defaultInput: preparedTracks.first?.input
            )
            guard writer.canAdd(group) else { throw Tx3gCaptionError.cannotAddInputGroup }
            writer.add(group)
        }

        var trackStates = preparedTracks.map {
            TrackWriterState(
                receiver: writer.inputReceiver(for: $0.input),
                formatDescription: $0.formatDescription,
                samples: $0.samples
            )
        }
        guard writer.startWriting() else {
            throw writer.error ?? Tx3gCaptionError.cannotStartWriter
        }
        writer.startSession(atSourceTime: .zero)

        do {
            try await Self.appendCaptionTracks(&trackStates)
        } catch {
            CaptionLogger.error("TX3G writer append failed: \(String(reflecting: error))")
            writer.cancelWriting()
            throw error
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            CaptionLogger.error(
                "TX3G writer failed: \(writer.error?.localizedDescription ?? "unknown writer failure")"
            )
            throw writer.error ?? Tx3gCaptionError.writerFailed
        }
        CaptionLogger.info(
            "TX3G writer completed: captionTracks=\(trackStates.count), "
                + "captionSamples=\(trackStates.reduce(0) { $0 + $1.appendedSampleCount })"
        )
    }

    private static func appendCaptionTracks(
        _ states: inout [TrackWriterState]
    ) async throws {
        let clock = ContinuousClock()
        var nextStallReport = clock.now + .seconds(2)
        while states.contains(where: { !$0.isFinished }) {
            try Task.checkCancellation()
            try stageCaptionSamples(in: &states)

            var madeProgress = false
            for index in states.indices {
                guard let sample = states[index].pendingSample else { continue }
                if try states[index].receiver.appendImmediately(sample) {
                    states[index].pendingSample = nil
                    states[index].nextSampleIndex += 1
                    states[index].appendedSampleCount += 1
                    madeProgress = true
                }
            }

            if madeProgress {
                nextStallReport = clock.now + .seconds(2)
            } else {
                if clock.now >= nextStallReport {
                    CaptionLogger.warning(
                        "TX3G writer waiting for input readiness: "
                            + "captionSamples=\(captionSampleCounts(in: states))"
                    )
                    nextStallReport = clock.now + .seconds(10)
                }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    private static func stageCaptionSamples(in states: inout [TrackWriterState]) throws {
        for index in states.indices where !states[index].isFinished {
            guard states[index].pendingSample == nil else { continue }
            guard states[index].nextSampleIndex < states[index].samples.count else {
                states[index].receiver.finish()
                states[index].isFinished = true
                continue
            }
            let sample = states[index].samples[states[index].nextSampleIndex]
            states[index].pendingSample = try makeSampleBuffer(
                text: sample.text,
                startTime: sample.startTime,
                endTime: sample.endTime,
                formatDescription: states[index].formatDescription
            )
        }
    }

    private static func captionSampleCounts(in states: [TrackWriterState]) -> String {
        states.map { String($0.appendedSampleCount) }.joined(separator: ",")
    }

    private static func prepareTrack(
        _ track: CaptionLanguageTrack,
        presentationSize: CGSize,
        terminalPadding: TimeInterval
    ) throws -> PreparedTrack? {
        let segments = track.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !segments.isEmpty else { return nil }

        let formatDescription = try makeFormatDescription(presentationSize: presentationSize)
        let input = AVAssetWriterInput(
            mediaType: .subtitle,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        input.naturalSize = presentationSize
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = 1_000
        input.mediaDataLocation = .sparselyInterleavedWithMainMediaData
        input.extendedLanguageTag = track.languageIdentifier
        input.languageCode = iso639_2TCode(for: track.languageIdentifier)

        var samples: [Sample] = []
        var previousEnd = 0.0
        for segment in segments {
            if segment.startTime > previousEnd {
                samples.append(
                    Sample(text: "", startTime: previousEnd, endTime: segment.startTime)
                )
            }
            samples.append(
                Sample(
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )
            )
            previousEnd = segment.endTime
        }
        if terminalPadding > 0 {
            samples.append(
                Sample(
                    text: "",
                    startTime: previousEnd,
                    endTime: previousEnd + terminalPadding
                )
            )
        }
        return PreparedTrack(
            input: input,
            formatDescription: formatDescription,
            samples: samples
        )
    }

    private static func makeFormatDescription(
        presentationSize: CGSize
    ) throws -> CMFormatDescription {
        let transparent: [CFString: Any] = [
            kCMTextFormatDescriptionColor_Red: 0,
            kCMTextFormatDescriptionColor_Green: 0,
            kCMTextFormatDescriptionColor_Blue: 0,
            kCMTextFormatDescriptionColor_Alpha: 0,
        ]
        let white: [CFString: Any] = [
            kCMTextFormatDescriptionColor_Red: 255,
            kCMTextFormatDescriptionColor_Green: 255,
            kCMTextFormatDescriptionColor_Blue: 255,
            kCMTextFormatDescriptionColor_Alpha: 255,
        ]
        let textBox: [CFString: Any] = [
            kCMTextFormatDescriptionRect_Top: Int16(0),
            kCMTextFormatDescriptionRect_Left: Int16(0),
            kCMTextFormatDescriptionRect_Bottom: Int16(presentationSize.height),
            kCMTextFormatDescriptionRect_Right: Int16(presentationSize.width),
        ]
        let style: [CFString: Any] = [
            kCMTextFormatDescriptionStyle_StartChar: 0,
            kCMTextFormatDescriptionStyle_EndChar: 0,
            kCMTextFormatDescriptionStyle_Font: 1,
            kCMTextFormatDescriptionStyle_FontFace: 0,
            kCMTextFormatDescriptionStyle_FontSize: 18,
            kCMTextFormatDescriptionStyle_ForegroundColor: white,
        ]
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_HorizontalJustification: 0,
            kCMTextFormatDescriptionExtension_VerticalJustification: -1,
            kCMTextFormatDescriptionExtension_BackgroundColor: transparent,
            kCMTextFormatDescriptionExtension_DefaultTextBox: textBox,
            kCMTextFormatDescriptionExtension_DefaultStyle: style,
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Serif"],
        ]

        var formatDescription: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: kCMMediaType_Subtitle,
            mediaSubType: kCMTextFormatType_3GText,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw Tx3gCaptionError.cannotCreateFormatDescription(status)
        }
        return formatDescription
    }

    private static func validated(presentationSize: CGSize) throws -> CGSize {
        let width = presentationSize.width.rounded(.up)
        let height = presentationSize.height.rounded(.up)
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0,
              width <= CGFloat(Int16.max),
              height <= CGFloat(Int16.max) else {
            throw Tx3gCaptionError.invalidPresentationSize
        }
        return CGSize(width: width, height: height)
    }

    private static func makeSampleBuffer(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        formatDescription: CMFormatDescription
    ) throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
        let encodedText = Array(text.utf8)
        guard encodedText.count <= Int(UInt16.max) else {
            throw Tx3gCaptionError.textSampleTooLarge
        }
        let length = UInt16(encodedText.count)
        let bytes = [UInt8(length >> 8), UInt8(length & 0xff)] + encodedText

        let dataBuffer = CMReadOnlyDataBlockBuffer(Data(bytes))
        let timing = CMSampleTimingInfo(
            duration: CMTime(seconds: endTime - startTime, preferredTimescale: 1_000),
            presentationTimeStamp: CMTime(seconds: startTime, preferredTimescale: 1_000),
            decodeTimeStamp: .invalid
        )
        let properties = CMSampleBuffer.SamplePropertiesCollection(
            sampleCount: 1,
            sizes: .uniform(bytes.count),
            timings: .sequential(startingAt: timing)
        )
        let dataSample = CMReadySampleBuffer(
            dataBuffer: dataBuffer,
            formatDescription: formatDescription,
            sampleProperties: properties
        )
        return CMReadySampleBuffer(dataSample)
    }

    private static func iso639_2TCode(for identifier: String) -> String {
        let languageCode = Locale(identifier: identifier).language.languageCode?.identifier
        return switch languageCode {
        case "en": "eng"
        case "es": "spa"
        case "ca": "cat"
        case "fr": "fra"
        case "de": "deu"
        case "it": "ita"
        case "pt": "por"
        case "ja": "jpn"
        case "ko": "kor"
        case "zh": "zho"
        case "ar": "ara"
        case "he": "heb"
        default: "und"
        }
    }
}
