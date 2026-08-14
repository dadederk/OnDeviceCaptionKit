import AVFoundation
import CoreMedia
import Foundation

@available(macOS 26, *)
enum Tx3gCaptionError: Error, Equatable {
    case noCaptionTracks
    case cannotCreateFormatDescription(OSStatus)
    case textSampleTooLarge
    case cannotAddInput
    case cannotAddInputGroup
    case missingSourceFormatDescription
    case cannotAddSourceOutput
    case cannotStartReader
    case readerFailed
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
        var nextIndex = 0
    }

    private struct PreparedSourceTrack {
        let input: AVAssetWriterInput
        let output: AVAssetReaderTrackOutput
    }

    private struct SourceTrackWriterState {
        let receiver: AVAssetWriterInput.SampleBufferReceiver
        let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
        var isFinished = false
    }

    @concurrent
    func write(
        tracks: [CaptionLanguageTrack],
        to outputURL: URL,
        terminalPadding: TimeInterval = 0,
        copyingMediaFrom sourceURL: URL? = nil
    ) async throws {
        let preparedTracks = try tracks.compactMap {
            try Self.prepareTrack($0, terminalPadding: terminalPadding)
        }
        guard !preparedTracks.isEmpty else { throw Tx3gCaptionError.noCaptionTracks }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let sourceReader: AVAssetReader?
        let preparedSourceTracks: [PreparedSourceTrack]
        if let sourceURL {
            let preparedSource = try await Self.prepareSourceTracks(
                from: sourceURL,
                writer: writer
            )
            sourceReader = preparedSource.reader
            preparedSourceTracks = preparedSource.tracks
        } else {
            sourceReader = nil
            preparedSourceTracks = []
        }
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
        var sourceTrackStates: [SourceTrackWriterState] = []
        if let sourceReader {
            sourceTrackStates = preparedSourceTracks.map {
                SourceTrackWriterState(
                    receiver: writer.inputReceiver(for: $0.input),
                    provider: sourceReader.outputProvider(for: $0.output)
                )
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? Tx3gCaptionError.cannotStartWriter
        }
        writer.startSession(atSourceTime: .zero)
        if let sourceReader, !sourceReader.startReading() {
            writer.cancelWriting()
            throw sourceReader.error ?? Tx3gCaptionError.cannotStartReader
        }

        while trackStates.contains(where: { $0.nextIndex < $0.samples.count })
            || sourceTrackStates.contains(where: { !$0.isFinished }) {
            for index in sourceTrackStates.indices where !sourceTrackStates[index].isFinished {
                try Task.checkCancellation()
                if let sourceSample = try await sourceTrackStates[index].provider.next() {
                    try await sourceTrackStates[index].receiver.append(sourceSample)
                } else {
                    sourceTrackStates[index].receiver.finish()
                    sourceTrackStates[index].isFinished = true
                }
            }
            for index in trackStates.indices where trackStates[index].nextIndex < trackStates[index].samples.count {
                try Task.checkCancellation()
                let sample = trackStates[index].samples[trackStates[index].nextIndex]
                trackStates[index].nextIndex += 1
                let readySample = try Self.makeSampleBuffer(
                    text: sample.text,
                    startTime: sample.startTime,
                    endTime: sample.endTime,
                    formatDescription: trackStates[index].formatDescription
                )
                try await trackStates[index].receiver.append(readySample)
            }
        }
        for trackState in trackStates {
            trackState.receiver.finish()
        }
        if let sourceReader, sourceReader.status != .completed {
            writer.cancelWriting()
            throw sourceReader.error ?? Tx3gCaptionError.readerFailed
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            CaptionLogger.error(
                "tx3g writer failed: \(writer.error?.localizedDescription ?? "unknown writer failure")"
            )
            throw writer.error ?? Tx3gCaptionError.writerFailed
        }
    }

    private static func prepareSourceTracks(
        from sourceURL: URL,
        writer: AVAssetWriter
    ) async throws -> (reader: AVAssetReader, tracks: [PreparedSourceTrack]) {
        let asset = AVURLAsset(url: sourceURL)
        let reader = try AVAssetReader(asset: asset)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var preparedTracks: [PreparedSourceTrack] = []

        for (mediaType, tracks) in [(AVMediaType.video, videoTracks), (.audio, audioTracks)] {
            for track in tracks {
                let formatDescriptions = try await track.load(.formatDescriptions)
                guard let formatDescription = formatDescriptions.first else {
                    throw Tx3gCaptionError.missingSourceFormatDescription
                }
                let input = AVAssetWriterInput(
                    mediaType: mediaType,
                    outputSettings: nil,
                    sourceFormatHint: formatDescription
                )
                input.expectsMediaDataInRealTime = false
                input.languageCode = try await track.load(.languageCode)
                input.extendedLanguageTag = try await track.load(.extendedLanguageTag)
                if mediaType == .video {
                    input.mediaTimeScale = try await track.load(.naturalTimeScale)
                    input.transform = try await track.load(.preferredTransform)
                }
                guard writer.canAdd(input) else { throw Tx3gCaptionError.cannotAddInput }
                writer.add(input)

                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                guard reader.canAdd(output) else { throw Tx3gCaptionError.cannotAddSourceOutput }
                preparedTracks.append(PreparedSourceTrack(input: input, output: output))
            }
        }
        return (reader, preparedTracks)
    }

    private static func prepareTrack(
        _ track: CaptionLanguageTrack,
        terminalPadding: TimeInterval
    ) throws -> PreparedTrack? {
        let segments = track.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !segments.isEmpty else { return nil }

        let formatDescription = try makeFormatDescription()
        let input = AVAssetWriterInput(
            mediaType: .text,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = 1_000
        input.extendedLanguageTag = track.languageIdentifier
        input.languageCode = iso639_2TCode(for: track.languageIdentifier)

        var samples: [Sample] = []
        var previousEnd = 0.0
        for segment in segments {
            if segment.startTime > previousEnd {
                samples.append(
                    Sample(
                        text: "",
                        startTime: previousEnd,
                        endTime: segment.startTime
                    )
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

    private static func makeFormatDescription() throws -> CMFormatDescription {
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
            kCMTextFormatDescriptionRect_Top: 0,
            kCMTextFormatDescriptionRect_Left: 0,
            kCMTextFormatDescriptionRect_Bottom: 0,
            kCMTextFormatDescriptionRect_Right: 0,
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
            mediaType: kCMMediaType_Text,
            mediaSubType: kCMTextFormatType_3GText,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw Tx3gCaptionError.cannotCreateFormatDescription(status)
        }
        return formatDescription
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
