import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import Testing
@testable import OnDeviceCaptionKit

@Suite(.serialized)
struct CaptionEmbedderTests {
    @Test("Caption chunking distributes captions evenly across movies")
    func givenNineCaptionsWhenChunkingThenSplitsThreeByThree() {
        // Given — mirrors a typical short recording with nine CEA-608 events
        let ranges = CaptionEmbedder.captionChunkRanges(
            in: Array(repeating: AVCaption("x", timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30))),
            count: 9),
            maxCaptionsPerChunk: 4
        )

        // Then — 3+3+3 avoids a trailing single-caption movie that splices mid-display
        #expect(ranges.map { $0.count } == [3, 3, 3])
    }

    @Test("Caption embedding timeout budget scales with chunk count")
    func givenChunkCountWhenComputingBudgetThenIncludesExportStepAndMargin() {
        let budget = CaptionEmbeddingTimeoutBudget.totalTimeout(
            chunkCount: 3,
            perStepTimeout: 10,
            margin: 2
        )

        #expect(budget == 42)
    }

    @Test("Caption chunking keeps extra captions in trailing movies")
    func givenSevenCaptionsWhenChunkingThenSplitsThreeThenFour() {
        let ranges = CaptionEmbedder.captionChunkRanges(
            in: Array(repeating: AVCaption("x", timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30))),
            count: 7),
            maxCaptionsPerChunk: 4
        )

        #expect(ranges.map { $0.count } == [3, 4])
    }

    @Test("Caption conversion trims text, skips empty text, and normalizes line breaks")
    func givenMessySegmentsWhenMakingCaptionsThenTextIsNormalized() throws {
        // Given
        let muxer = CaptionEmbedder()
        let segments = [
            CaptionSegment(index: 1, startTime: 0, endTime: 1, text: "  Line one\nLine two  "),
            CaptionSegment(index: 2, startTime: 1, endTime: 2, text: "   \n"),
            CaptionSegment(index: 3, startTime: 2, endTime: 3, text: "Next")
        ]

        // When
        let captions = try muxer.makeClosedCaptions(
            from: segments,
            frameDuration: CMTime(value: 1, timescale: 30)
        )

        // Then
        #expect(captions.map(\.text) == ["Line one", "Line two", "Next"])
    }

    @Test("Caption conversion adjusts zero starts and keeps ranges monotonic")
    func givenZeroStartAndOverlappingSegmentsWhenMakingCaptionsThenTimingIsValid() throws {
        // Given
        let muxer = CaptionEmbedder()
        let frameDuration = CMTime(value: 1, timescale: 30)
        let segments = [
            CaptionSegment(index: 1, startTime: 0, endTime: 0.2, text: "First"),
            CaptionSegment(index: 2, startTime: 0.1, endTime: 0.4, text: "Second"),
            CaptionSegment(index: 3, startTime: 0.4, endTime: 0.4, text: "Third")
        ]

        // When
        let captions = try muxer.makeClosedCaptions(from: segments, frameDuration: frameDuration)

        // Then
        #expect(captions.count == 3)
        #expect(CMTimeCompare(captions[0].timeRange.start, .zero) > 0)
        #expect(CMTimeCompare(captions[0].timeRange.end, captions[1].timeRange.start) <= 0)
        #expect(CMTimeCompare(captions[1].timeRange.end, captions[2].timeRange.start) <= 0)
        #expect(CMTimeCompare(captions[2].timeRange.duration, .zero) > 0)
    }

    @Test("Caption conversion splits long text into CEA-608-sized chunks")
    func givenLongSegmentWhenMakingCaptionsThenTextIsChunked() throws {
        // Given
        let muxer = CaptionEmbedder()
        let longText = String(repeating: "word ", count: 20).trimmingCharacters(in: .whitespaces)
        let segments = [
            CaptionSegment(index: 1, startTime: 0, endTime: 8, text: longText)
        ]

        // When
        let captions = try muxer.makeClosedCaptions(from: segments)

        // Then
        #expect(captions.count > 1)
        #expect(captions.allSatisfy { $0.text.count <= 32 })
        #expect(captions.map(\.text).joined(separator: " ") == longText)
    }

    @Test("Caption conversion preserves long real-world text after CEA-608 conformance")
    func givenLongRealWorldSegmentsWhenMakingCaptionsThenTextIsNotCropped() throws {
        // Given
        let muxer = CaptionEmbedder()
        let segments = [
            CaptionSegment(
                index: 1,
                startTime: 0.000,
                endTime: 8.430,
                text: "Mandir of a video where I'm trying to do some text to."
            ),
            CaptionSegment(
                index: 2,
                startTime: 8.430,
                endTime: 16.470,
                text: "Speech either way speech to text recognition and then I can write some subtitles that."
            ),
            CaptionSegment(
                index: 3,
                startTime: 16.470,
                endTime: 18.780,
                text: "You can show and hide in the video."
            )
        ]

        // When
        let captions = try muxer.makeClosedCaptions(from: segments)

        // Then
        let expectedText = segments.map(\.text).joined(separator: " ")
        #expect(collapsedConsecutiveTexts(in: captions).joined(separator: " ") == expectedText)
        #expect(captions.allSatisfy { $0.text.count <= 32 })
    }

    @Test("Caption conformance handles long real-world sentences", .timeLimit(.minutes(1)))
    func givenLongSentencesWhenMakingCaptionsThenConformanceCompletes() throws {
        // Given
        let muxer = CaptionEmbedder()
        let segments = [
            CaptionSegment(
                index: 1,
                startTime: 0,
                endTime: 6,
                text: "Welcome to this demonstration of the new screen recording feature with embedded subtitles."
            ),
            CaptionSegment(
                index: 2,
                startTime: 6,
                endTime: 12,
                text: "In this section, we will explore how captions are generated automatically from the microphone audio."
            ),
            CaptionSegment(
                index: 3,
                startTime: 12,
                endTime: 18,
                text: "The captions should align with the spoken words and remain readable on screen."
            ),
            CaptionSegment(
                index: 4,
                startTime: 18,
                endTime: 22,
                text: "Thank you for watching this short demonstration of the feature."
            )
        ]

        // When
        let captions = try muxer.makeClosedCaptions(from: segments)

        // Then
        #expect(!captions.isEmpty)
    }

    @Test("Caption muxer writes a readable closed-caption track into a MOV")
    func givenTinyMOVWhenEmbeddingCaptionsThenClosedCaptionTrackIsReadable() async throws {
        // Given
        let sourceURL = try await makeTinyMOV()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let muxer = CaptionEmbedder()
        let segments = [
            CaptionSegment(index: 1, startTime: 0, endTime: 1, text: "Hello")
        ]

        // When
        let captionedURL = try await muxer.embedClosedCaptions(from: segments, into: sourceURL)
        defer { try? FileManager.default.removeItem(at: captionedURL) }

        let asset = AVURLAsset(url: captionedURL)
        let captionTracks = try await asset.loadTracks(withMediaType: .closedCaption)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        // Then
        #expect(captionTracks.count == 1)
        #expect(videoTracks.count == 1)

        let captionTrack = try #require(captionTracks.first)
        let languageCode = try await captionTrack.load(.languageCode)
        let extendedLanguageTag = try await captionTrack.load(.extendedLanguageTag)
        #expect(languageCode == "eng")
        #expect(extendedLanguageTag == "en-US")
    }

    @Test(
        "Caption muxer embeds captions into a video+audio MOV without deadlocking",
        .timeLimit(.minutes(1))
    )
    func givenMOVWithAudioWhenEmbeddingCaptionsThenAllTracksArePresent() async throws {
        // Given
        let sourceURL = try await makeTinyMOV(includeAudio: true)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let muxer = CaptionEmbedder()
        let segments = [
            CaptionSegment(index: 1, startTime: 0, endTime: 1, text: "Hello"),
            CaptionSegment(index: 2, startTime: 1, endTime: 2, text: "World")
        ]

        // When
        let captionedURL = try await muxer.embedClosedCaptions(from: segments, into: sourceURL)
        defer { try? FileManager.default.removeItem(at: captionedURL) }

        let asset = AVURLAsset(url: captionedURL)
        let captionTracks = try await asset.loadTracks(withMediaType: .closedCaption)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        // Then
        #expect(captionTracks.count == 1)
        #expect(videoTracks.count == 1)
        #expect(audioTracks.count == 1)
    }

    @Test(
        "Caption muxer embeds captions into an export-session muxed MOV without deadlocking",
        .timeLimit(.minutes(1))
    )
    func givenExportMuxedMOVWhenEmbeddingCaptionsThenCompletes() async throws {
        // Given a pipeline that mirrors production: a screen MOV (video + system audio)
        // and a mic-only track muxed via AVAssetExportSession, then caption embedding.
        let screenURL = try await makeTinyMOV(includeAudio: true)
        defer { try? FileManager.default.removeItem(at: screenURL) }
        let micURL = try await makeAudioOnlyM4A()
        defer { try? FileManager.default.removeItem(at: micURL) }

        let muxedURL = try await muxExportSessionVideo(videoURL: screenURL, micAudioURL: micURL)
        defer { try? FileManager.default.removeItem(at: muxedURL) }

        let muxer = CaptionEmbedder()
        let segments = [
            CaptionSegment(index: 1, startTime: 0, endTime: 1, text: "Hello"),
            CaptionSegment(index: 2, startTime: 1, endTime: 2, text: "World")
        ]

        // When
        let captionedURL = try await muxer.embedClosedCaptions(from: segments, into: muxedURL)
        defer { try? FileManager.default.removeItem(at: captionedURL) }

        let asset = AVURLAsset(url: captionedURL)
        let captionTracks = try await asset.loadTracks(withMediaType: .closedCaption)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        // Then
        #expect(captionTracks.count == 1)
        #expect(videoTracks.count == 1)
    }

    @Test(
        "Caption muxer embeds captions into a MOV with a near-empty second audio track",
        .timeLimit(.minutes(1))
    )
    func givenMOVWithShortSilentAudioTrackWhenEmbeddingCaptionsThenCompletes() async throws {
        // Reproduces production: a screen recording whose system-audio track is
        // nearly empty (a few packets of silence) while the mic track runs the full
        // length and the video is comparatively long.
        let sourceURL = try await makeMOVWithVideoAndTwoAudioTracks(
            videoFrameCount: 16,
            videoFrameSpacingSeconds: 1.0,
            shortAudioChunkCount: 3,
            fullAudioChunkCount: 480
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let muxer = CaptionEmbedder()
        let segments = [
            CaptionSegment(index: 1, startTime: 0, endTime: 1, text: "Hello"),
            CaptionSegment(index: 2, startTime: 1, endTime: 2, text: "World"),
            CaptionSegment(index: 3, startTime: 2, endTime: 3, text: "Again")
        ]

        // When
        let captionedURL = try await muxer.embedClosedCaptions(from: segments, into: sourceURL)
        defer { try? FileManager.default.removeItem(at: captionedURL) }

        let asset = AVURLAsset(url: captionedURL)
        let captionTracks = try await asset.loadTracks(withMediaType: .closedCaption)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        // Then
        #expect(captionTracks.count == 1)
        #expect(videoTracks.count == 1)
        #expect(audioTracks.count == 2)
    }

    private func muxExportSessionVideo(videoURL: URL, micAudioURL: URL) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptionEmbedderTests-muxed-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        try? FileManager.default.removeItem(at: outputURL)

        let videoAsset = AVURLAsset(url: videoURL)
        let micAsset = AVURLAsset(url: micAudioURL)
        let composition = AVMutableComposition()

        let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first
        guard let videoTrack else { throw CaptionEmbeddingTestError.cannotAddVideoInput }

        let syncRange = try await videoTrack.load(.timeRange)
        guard let videoCompositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CaptionEmbeddingTestError.cannotAddVideoInput
        }
        try videoCompositionTrack.insertTimeRange(syncRange, of: videoTrack, at: .zero)

        if let systemAudioTrack = try await videoAsset.loadTracks(withMediaType: .audio).first,
           let systemCompositionTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let systemRange = try await systemAudioTrack.load(.timeRange)
            try systemCompositionTrack.insertTimeRange(systemRange, of: systemAudioTrack, at: .zero)
        }

        if let micTrack = try await micAsset.loadTracks(withMediaType: .audio).first,
           let micCompositionTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let micRange = try await micTrack.load(.timeRange)
            try micCompositionTrack.insertTimeRange(micRange, of: micTrack, at: .zero)
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptionEmbeddingTestError.writerFailed
        }
        try await exportSession.export(to: outputURL, as: .mov)
        return outputURL
    }

    private func makeMOVWithVideoAndTwoAudioTracks(
        videoFrameCount: Int,
        videoFrameSpacingSeconds: Double,
        shortAudioChunkCount: Int,
        fullAudioChunkCount: Int
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptionEmbedderTests-twoAudio-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        try? FileManager.default.removeItem(at: outputURL)

        let frameRate: Int32 = 30
        let sampleRate = 44_100.0
        let framesPerChunk = Int(sampleRate) / Int(frameRate)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 16,
                AVVideoHeightKey: 16
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16
            ]
        )
        guard writer.canAdd(videoInput) else { throw CaptionEmbeddingTestError.cannotAddVideoInput }
        writer.add(videoInput)

        func makeAudioInput() throws -> AVAssetWriterInput {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 1,
                    AVSampleRateKey: sampleRate,
                    AVEncoderBitRateKey: 64_000
                ]
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw CaptionEmbeddingTestError.cannotAddAudioInput }
            writer.add(input)
            return input
        }

        let shortAudioInput = try makeAudioInput()
        let fullAudioInput = try makeAudioInput()

        guard writer.startWriting() else {
            throw writer.error ?? CaptionEmbeddingTestError.cannotStartWriter
        }
        writer.startSession(atSourceTime: .zero)

        let pixelBuffer = try makePixelBuffer(width: 16, height: 16)

        func appendAudio(_ input: AVAssetWriterInput, chunk: Int) async throws {
            let time = CMTime(
                value: CMTimeValue(chunk * framesPerChunk),
                timescale: CMTimeScale(sampleRate)
            )
            let buffer = try makeSilentAudioSampleBuffer(
                presentationTime: time,
                sampleRate: sampleRate,
                frameCount: framesPerChunk
            )
            try await waitUntilReady(input)
            guard input.isReadyForMoreMediaData, input.append(buffer) else {
                writer.cancelWriting()
                throw writer.error ?? CaptionEmbeddingTestError.cannotAppendFrame
            }
        }

        // Audio is dense (30 chunks/second); video is sparse (one frame every
        // `videoFrameSpacingSeconds`). Interleave both by presentation time so the
        // writer keeps every input ready, mirroring a near-static screen recording.
        let chunkDuration = Double(framesPerChunk) / sampleRate
        let totalChunks = max(shortAudioChunkCount, fullAudioChunkCount)
        var nextVideoFrame = 0
        for index in 0..<totalChunks {
            let chunkTime = Double(index) * chunkDuration
            while nextVideoFrame < videoFrameCount,
                  Double(nextVideoFrame) * videoFrameSpacingSeconds <= chunkTime {
                let videoTime = CMTime(seconds: Double(nextVideoFrame) * videoFrameSpacingSeconds, preferredTimescale: 600)
                try await waitUntilReady(videoInput)
                guard videoInput.isReadyForMoreMediaData,
                      adaptor.append(pixelBuffer, withPresentationTime: videoTime) else {
                    writer.cancelWriting()
                    throw writer.error ?? CaptionEmbeddingTestError.cannotAppendFrame
                }
                nextVideoFrame += 1
                if nextVideoFrame == videoFrameCount { videoInput.markAsFinished() }
            }

            if index < shortAudioChunkCount {
                try await appendAudio(shortAudioInput, chunk: index)
                if index == shortAudioChunkCount - 1 { shortAudioInput.markAsFinished() }
            }

            if index < fullAudioChunkCount {
                try await appendAudio(fullAudioInput, chunk: index)
                if index == fullAudioChunkCount - 1 { fullAudioInput.markAsFinished() }
            }
        }
        if nextVideoFrame < videoFrameCount { videoInput.markAsFinished() }

        await finishWriting(writer)
        guard writer.status == .completed else {
            throw writer.error ?? CaptionEmbeddingTestError.writerFailed
        }
        return outputURL
    }

    private func makeAudioOnlyM4A() async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptionEmbedderTests-mic-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: outputURL)

        let sampleRate = 44_100.0
        let chunks = 30
        let framesPerChunk = Int(sampleRate) / 30

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: sampleRate,
                AVEncoderBitRateKey: 64_000
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw CaptionEmbeddingTestError.cannotAddAudioInput }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? CaptionEmbeddingTestError.cannotStartWriter
        }
        writer.startSession(atSourceTime: .zero)

        for chunk in 0..<chunks {
            let time = CMTime(value: CMTimeValue(chunk * framesPerChunk), timescale: CMTimeScale(sampleRate))
            let buffer = try makeSilentAudioSampleBuffer(
                presentationTime: time,
                sampleRate: sampleRate,
                frameCount: framesPerChunk
            )
            try await waitUntilReady(input)
            guard input.isReadyForMoreMediaData, input.append(buffer) else {
                writer.cancelWriting()
                throw writer.error ?? CaptionEmbeddingTestError.cannotAppendFrame
            }
        }

        input.markAsFinished()
        await finishWriting(writer)
        guard writer.status == .completed else {
            throw writer.error ?? CaptionEmbeddingTestError.writerFailed
        }
        return outputURL
    }

    private func makeTinyMOV(
        includeAudio: Bool = false,
        durationSeconds: Int = 1,
        frameRate: Int32 = 30
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptionEmbedderTests-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        try? FileManager.default.removeItem(at: outputURL)

        let frameCount = max(30, durationSeconds * Int(frameRate))
        let sampleRate = 44_100.0
        let framesPerChunk = Int(sampleRate) / Int(frameRate)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 16,
                AVVideoHeightKey: 16
            ]
        )
        videoInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16
            ]
        )

        guard writer.canAdd(videoInput) else {
            throw CaptionEmbeddingTestError.cannotAddVideoInput
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if includeAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 1,
                    AVSampleRateKey: sampleRate,
                    AVEncoderBitRateKey: 64_000
                ]
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw CaptionEmbeddingTestError.cannotAddAudioInput
            }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw writer.error ?? CaptionEmbeddingTestError.cannotStartWriter
        }
        writer.startSession(atSourceTime: .zero)

        let pixelBuffer = try makePixelBuffer(width: 16, height: 16)

        // Interleave the two tracks so the writer keeps both inputs ready. Feeding
        // video to completion before audio would itself deadlock the writer.
        for frame in 0..<frameCount {
            let videoTime = CMTime(value: CMTimeValue(frame), timescale: frameRate)
            try await waitUntilReady(videoInput)
            guard videoInput.isReadyForMoreMediaData,
                  adaptor.append(pixelBuffer, withPresentationTime: videoTime) else {
                writer.cancelWriting()
                throw writer.error ?? CaptionEmbeddingTestError.cannotAppendFrame
            }

            if let audioInput {
                let audioTime = CMTime(
                    value: CMTimeValue(frame * framesPerChunk),
                    timescale: CMTimeScale(sampleRate)
                )
                let buffer = try makeSilentAudioSampleBuffer(
                    presentationTime: audioTime,
                    sampleRate: sampleRate,
                    frameCount: framesPerChunk
                )
                try await waitUntilReady(audioInput)
                guard audioInput.isReadyForMoreMediaData, audioInput.append(buffer) else {
                    writer.cancelWriting()
                    throw writer.error ?? CaptionEmbeddingTestError.cannotAppendFrame
                }
            }
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await finishWriting(writer)

        guard writer.status == .completed else {
            throw writer.error ?? CaptionEmbeddingTestError.writerFailed
        }

        return outputURL
    }

    private func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        for _ in 0..<100 where !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeSilentAudioSampleBuffer(
        presentationTime: CMTime,
        sampleRate: Double,
        frameCount: Int
    ) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw CaptionEmbeddingTestError.cannotCreateAudioBuffer
        }

        let dataByteCount = frameCount * 2
        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataByteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataByteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw CaptionEmbeddingTestError.cannotCreateAudioBuffer
        }

        status = CMBlockBufferFillDataBytes(
            with: 0,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: dataByteCount
        )
        guard status == kCMBlockBufferNoErr else {
            throw CaptionEmbeddingTestError.cannotCreateAudioBuffer
        }

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw CaptionEmbeddingTestError.cannotCreateAudioBuffer
        }

        return sampleBuffer
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw CaptionEmbeddingTestError.cannotCreatePixelBuffer
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, 0x2F, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }

    private func readCaptions(from url: URL, expectedCount: Int) async throws -> [AVCaption] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .closedCaption).first else {
            throw CaptionEmbeddingTestError.cannotCreateCaptionReader
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let provider = reader.outputCaptionProvider(for: output)
        guard reader.startReading() else {
            throw reader.error ?? CaptionEmbeddingTestError.cannotStartReader
        }
        defer { reader.cancelReading() }

        var captions: [AVCaption] = []
        while mergedConsecutiveCaptions(in: captions).count < expectedCount {
            guard let group = try await provider.next() else {
                throw CaptionEmbeddingTestError.readerFailed
            }
            captions.append(contentsOf: provider.captionsNotPresentInPreviousGroups(in: group))
        }
        return Array(mergedConsecutiveCaptions(in: captions).prefix(expectedCount))
    }

    private func collapsedConsecutiveTexts(in captions: [AVCaption]) -> [String] {
        mergedConsecutiveCaptions(in: captions).map(\.text)
    }

    private func mergedConsecutiveCaptions(in captions: [AVCaption]) -> [AVCaption] {
        // A new CEA-608 chunk can repeat the decoder's current visible state at its boundary.
        var merged: [AVCaption] = []
        for caption in captions {
            guard let previous = merged.last, previous.text == caption.text else {
                merged.append(caption)
                continue
            }

            let mergedRange = CMTimeRange(
                start: min(previous.timeRange.start, caption.timeRange.start),
                end: max(previous.timeRange.end, caption.timeRange.end)
            )
            merged[merged.count - 1] = AVCaption(caption.text, timeRange: mergedRange)
        }
        return merged
    }
}

private enum CaptionEmbeddingTestError: Error {
    case cannotAddVideoInput
    case cannotAddAudioInput
    case cannotStartWriter
    case cannotAppendFrame
    case cannotCreatePixelBuffer
    case cannotCreateAudioBuffer
    case cannotCreateCaptionReader
    case cannotStartReader
    case readerFailed
    case writerFailed
}
