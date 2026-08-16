import AVFoundation
import Foundation
import Testing
@testable import OnDeviceCaptionKit

struct Tx3gCaptionTrackWriterTests {
    @available(macOS 26, *)
    @Test("Subtitle TX3G samples round-trip as playable Unicode language tracks")
    func unicodeTracksRoundTrip() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tx3g-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let original = try CaptionLanguageTrack(
            languageIdentifier: "en-US",
            segments: [
                CaptionSegment(index: 1, startTime: 0.25, endTime: 1.5, text: "Hello 👋\nworld"),
                CaptionSegment(index: 2, startTime: 2, endTime: 3.25, text: "中文 text"),
            ]
        )
        let arabic = try CaptionLanguageTrack(
            languageIdentifier: "ar-SA",
            segments: [
                CaptionSegment(index: 1, startTime: 0.25, endTime: 1.5, text: "مرحبًا بالعالم"),
                CaptionSegment(index: 2, startTime: 2, endTime: 3.25, text: "سطران\nمن النص"),
            ]
        )

        let presentationSize = CGSize(width: 1_920, height: 1_080)
        try await Tx3gCaptionTrackWriter().write(
            tracks: [original, arabic],
            to: outputURL,
            presentationSize: presentationSize
        )

        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .subtitle)
        #expect(tracks.count == 2)
        let tags = try await tracks.asyncMap { try await $0.load(.extendedLanguageTag) }
        #expect(Set(tags.compactMap { $0 }) == Set(["en-US", "ar-SA"]))
        let playable = try await tracks.asyncMap { try await $0.load(.isPlayable) }
        #expect(playable.allSatisfy { $0 })
        let sizes = try await tracks.asyncMap { try await $0.load(.naturalSize) }
        #expect(sizes.allSatisfy { $0 == presentationSize })
        let formatDescriptions = try await tracks.asyncMap {
            try await $0.load(.formatDescriptions)
        }
        for descriptions in formatDescriptions {
            let description = try #require(descriptions.first)
            let formatExtensions = try #require(
                CMFormatDescriptionGetExtensions(description)
            )
            let extensions = formatExtensions as NSDictionary
            let fontTable = try #require(
                extensions[kCMTextFormatDescriptionExtension_FontTable] as? [String: String]
            )
            #expect(fontTable["1"] == "Sans-Serif")
        }

        let decodedTracks = try await Tx3gCaptionTrackReader().read(from: outputURL)
        let decodedByTag = Dictionary(
            uniqueKeysWithValues: decodedTracks.map { ($0.languageIdentifier, $0.segments) }
        )
        #expect(decodedByTag["en-US"] == original.segments)
        #expect(decodedByTag["ar-SA"] == arabic.segments)

        let selectionGroup = try await asset.loadMediaSelectionGroup(for: .legible)
        let optionLanguageIdentifiers = Set(
            selectionGroup?.options.compactMap { $0.locale?.identifier } ?? []
        )
        #expect(optionLanguageIdentifiers.isSuperset(of: ["en-US", "ar-SA"]))
        let authoredOptions = selectionGroup?.options.filter {
            ["en-US", "ar-SA"].contains($0.locale?.identifier)
        } ?? []
        #expect(!authoredOptions.isEmpty)
        #expect(authoredOptions.allSatisfy { $0.isPlayable })
    }

    @Test("Language tracks require canonical tags and monotonic timing")
    func languageTrackValidation() throws {
        #expect(throws: CaptionLanguageTrackError.invalidLanguageIdentifier("en_US")) {
            try CaptionLanguageTrack(languageIdentifier: "en_US", segments: [])
        }
        #expect(throws: CaptionLanguageTrackError.invalidSegment(index: 2)) {
            try CaptionLanguageTrack(
                languageIdentifier: "en-US",
                segments: [
                    CaptionSegment(index: 1, startTime: 1, endTime: 2, text: "First"),
                    CaptionSegment(index: 2, startTime: 1.5, endTime: 3, text: "Overlap"),
                ]
            )
        }
    }

}

private extension Array {
    func asyncMap<Result>(_ transform: (Element) async throws -> Result) async rethrows -> [Result] {
        var results: [Result] = []
        results.reserveCapacity(count)
        for element in self {
            results.append(try await transform(element))
        }
        return results
    }
}
