import AVFoundation
import CoreMedia
import Foundation

@available(macOS 26, *)
enum Tx3gCaptionTrackReaderError: Error {
    case missingLanguageIdentifier
    case cannotAddOutput
    case cannotStartReader
    case malformedSample
    case cannotCopySampleBytes(OSStatus)
    case readerFailed
}

@available(macOS 26, *)
struct Tx3gCaptionTrackReader: Sendable {
    @concurrent
    func read(from url: URL) async throws -> [CaptionLanguageTrack] {
        let asset = AVURLAsset(url: url)
        let subtitleTracks = try await asset.loadTracks(withMediaType: .subtitle)
        let legacyTextTracks = try await asset.loadTracks(withMediaType: .text)
        let tracks = subtitleTracks + legacyTextTracks
        var results: [CaptionLanguageTrack] = []
        results.reserveCapacity(tracks.count)

        for track in tracks {
            try Task.checkCancellation()
            guard let languageIdentifier = try await track.load(.extendedLanguageTag) else {
                throw Tx3gCaptionTrackReaderError.missingLanguageIdentifier
            }
            let segments = try await readSegments(from: track, asset: asset)
            results.append(
                try CaptionLanguageTrack(
                    languageIdentifier: languageIdentifier,
                    segments: segments
                )
            )
        }
        return results
    }

    private func readSegments(
        from track: AVAssetTrack,
        asset: AVAsset
    ) async throws -> [CaptionSegment] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw Tx3gCaptionTrackReaderError.cannotAddOutput
        }
        let provider = reader.outputProvider(for: output)
        guard reader.startReading() else {
            throw reader.error ?? Tx3gCaptionTrackReaderError.cannotStartReader
        }

        var segments: [CaptionSegment] = []
        while let sample = try await provider.next() {
            try Task.checkCancellation()
            guard case .dataBuffer(let dataBuffer) = sample.content else { continue }
            guard let text = try Self.text(from: dataBuffer), !text.isEmpty else { continue }

            let startTime = sample.presentationTimeStamp.seconds
            let endTime = CMTimeAdd(sample.presentationTimeStamp, sample.duration).seconds
            guard startTime.isFinite, endTime.isFinite, endTime > startTime else {
                throw Tx3gCaptionTrackReaderError.malformedSample
            }
            segments.append(
                CaptionSegment(
                    index: segments.count + 1,
                    startTime: startTime,
                    endTime: endTime,
                    text: text
                )
            )
        }
        guard reader.status == .completed else {
            throw reader.error ?? Tx3gCaptionTrackReaderError.readerFailed
        }
        return segments
    }

    private static func text(from dataBuffer: CMReadOnlyDataBlockBuffer) throws -> String? {
        let bytes = try bytes(from: dataBuffer)
        guard bytes.count >= 2 else { return nil }
        let textLength = Int(bytes[0]) << 8 | Int(bytes[1])
        guard textLength > 0 else { return nil }
        guard bytes.count >= textLength + 2 else {
            throw Tx3gCaptionTrackReaderError.malformedSample
        }
        return String(decoding: bytes[2..<(textLength + 2)], as: UTF8.self)
    }

    private static func bytes(from dataBuffer: CMReadOnlyDataBlockBuffer) throws -> [UInt8] {
        try dataBuffer.withUnsafeBlockBuffer { blockBuffer in
            let count = CMBlockBufferGetDataLength(blockBuffer)
            guard count > 0 else { return [] }
            var bytes = [UInt8](repeating: 0, count: count)
            let status = bytes.withUnsafeMutableBytes { destination -> OSStatus in
                guard let baseAddress = destination.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: count,
                    destination: baseAddress
                )
            }
            guard status == noErr else {
                throw Tx3gCaptionTrackReaderError.cannotCopySampleBytes(status)
            }
            return bytes
        }
    }
}
