import Foundation

public enum CaptionLanguageTrackError: Error, Equatable, Sendable {
    case invalidLanguageIdentifier(String)
    case duplicateLanguageIdentifier(String)
    case mismatchedTimeline(String)
    case invalidSegment(index: Int)
}

public struct CaptionLanguageTrack: Equatable, Sendable {
    public let languageIdentifier: String
    public let segments: [CaptionSegment]

    public init(languageIdentifier: String, segments: [CaptionSegment]) throws {
        let canonicalIdentifier = Locale(identifier: languageIdentifier).identifier(.bcp47)
        guard canonicalIdentifier == languageIdentifier,
              canonicalIdentifier != "und",
              Locale(identifier: canonicalIdentifier).language.languageCode != nil else {
            throw CaptionLanguageTrackError.invalidLanguageIdentifier(languageIdentifier)
        }

        var previousEnd: TimeInterval = 0
        for segment in segments {
            guard segment.startTime.isFinite,
                  segment.endTime.isFinite,
                  segment.startTime >= previousEnd,
                  segment.endTime > segment.startTime else {
                throw CaptionLanguageTrackError.invalidSegment(index: segment.index)
            }
            previousEnd = segment.endTime
        }

        self.languageIdentifier = canonicalIdentifier
        self.segments = segments
    }

    static func validateCollection(_ tracks: [CaptionLanguageTrack]) throws {
        var identifiers = Set<String>()
        for track in tracks where !identifiers.insert(track.languageIdentifier).inserted {
            throw CaptionLanguageTrackError.duplicateLanguageIdentifier(track.languageIdentifier)
        }
        guard let original = tracks.first else { return }
        for track in tracks.dropFirst() {
            guard track.segments.count == original.segments.count,
                  zip(track.segments, original.segments).allSatisfy({ translated, source in
                      translated.index == source.index
                          && translated.startTime == source.startTime
                          && translated.endTime == source.endTime
                  }) else {
                throw CaptionLanguageTrackError.mismatchedTimeline(track.languageIdentifier)
            }
        }
    }
}
