import AVFoundation
import Foundation

@available(macOS 26, *)
enum PassthroughCaptionTrackMuxingError: Error {
    case cannotAddTrack(AVMediaType)
    case cannotCreateExportSession
}

@available(macOS 26, *)
struct PassthroughCaptionTrackMuxer: Sendable {
    @concurrent
    func mux(
        captionsFrom captionURL: URL,
        withMediaFrom videoURL: URL,
        to outputURL: URL
    ) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let captionAsset = AVURLAsset(url: captionURL)

        for mediaType in [AVMediaType.video, .audio] {
            let tracks = try await videoAsset.loadTracks(withMediaType: mediaType)
            for track in tracks {
                let destination = try Self.addTrack(of: mediaType, to: composition)
                let timeRange = try await track.load(.timeRange)
                try destination.insertTimeRange(timeRange, of: track, at: .zero)
                destination.languageCode = try await track.load(.languageCode)
                destination.extendedLanguageTag = try await track.load(.extendedLanguageTag)
                if mediaType == .video {
                    destination.preferredTransform = try await track.load(.preferredTransform)
                } else if mediaType == .audio {
                    destination.preferredVolume = try await track.load(.preferredVolume)
                }
            }
        }

        let captionTracks = try await captionAsset.loadTracks(withMediaType: .text)
        for track in captionTracks {
            let destination = try Self.addTrack(of: .text, to: composition)
            let timeRange = try await track.load(.timeRange)
            try destination.insertTimeRange(timeRange, of: track, at: .zero)
            destination.languageCode = try await track.load(.languageCode)
            destination.extendedLanguageTag = try await track.load(.extendedLanguageTag)
        }

        try? FileManager.default.removeItem(at: outputURL)
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw PassthroughCaptionTrackMuxingError.cannotCreateExportSession
        }
        try await exportSession.export(to: outputURL, as: .mov)
        try Task.checkCancellation()
        try await Self.setCaptionAlternateGroup(in: outputURL)
    }

    private static func addTrack(
        of mediaType: AVMediaType,
        to composition: AVMutableComposition
    ) throws -> AVMutableCompositionTrack {
        guard let track = composition.addMutableTrack(
            withMediaType: mediaType,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw PassthroughCaptionTrackMuxingError.cannotAddTrack(mediaType)
        }
        return track
    }

    private static func setCaptionAlternateGroup(in outputURL: URL) async throws {
        let movie = AVMutableMovie(url: outputURL, options: nil)
        let captionTracks = try await movie.loadTracks(withMediaType: .text)
        for (index, track) in captionTracks.enumerated() {
            track.alternateGroupID = 1
            track.isEnabled = index == 0
        }
        try movie.writeHeader(to: outputURL, fileType: .mov, options: [])
    }
}
