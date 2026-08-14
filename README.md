# OnDeviceCaptionKit

<p align="center">
  <img src="images/OnDeviceCaptionKit.png" alt="OnDeviceCaptionKit logo" width="420">
</p>

[![Swift](https://img.shields.io/badge/swift-6.2%2B-F05138.svg)](https://swift.org)
![Platforms](https://img.shields.io/badge/platform-macOS%2026%2B-0A84FF.svg)
[![CI](https://github.com/dadederk/OnDeviceCaptionKit/actions/workflows/ondevicecaptionkit-tests.yml/badge.svg)](https://github.com/dadederk/OnDeviceCaptionKit/actions/workflows/ondevicecaptionkit-tests.yml)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

On-device caption transcription, multilingual SRT export, and selectable MOV caption embedding for Swift apps on macOS.

OnDeviceCaptionKit provides:
- On-device speech transcription through Apple's Speech framework.
- Modern `SpeechAnalyzer` transcription with legacy `SFSpeechRecognizer` fallback.
- SRT sidecar generation with deterministic timestamp and text wrapping behavior.
- CEA-608 closed-caption embedding for `.mov` files using AVFoundation.
- Unicode `tx3g` MOV embedding with multiple selectable BCP-47 language tracks.
- Typed errors and stable warning codes for host-app localization.

v1 scope is caption generation and export only. UI, localization copy, save panels, settings, logging policy, microphone capture, screen recording, and user-facing fallback messaging stay in the consuming app.

## Requirements

| Item | Requirement |
| --- | --- |
| Swift tools | 6.2+ |
| macOS | 26+ |
| Dependencies | None |

## Installation

Add OnDeviceCaptionKit to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/dadederk/OnDeviceCaptionKit.git", from: "0.3.0")
]
```

Then add the product to your target:

```swift
target(
    name: "YourApp",
    dependencies: [
        .product(name: "OnDeviceCaptionKit", package: "OnDeviceCaptionKit")
    ]
)
```

## Quick Start

OnDeviceCaptionKit is built around three common tasks: transcribe audio, write SRT, and embed captions into a MOV.

Transcribe audio on device:

```swift
import Foundation
import OnDeviceCaptionKit

let pipeline = CaptionPipeline(
    configuration: .init(
        transcription: CaptionTranscriptionConfiguration(
            locale: Locale(identifier: "en-US")
        )
    )
)

let result = try await pipeline.transcribe(from: audioURL)
let segments = result.segments
```

Write an SRT file:

```swift
try await pipeline.writeSRT(segments: segments, besideVideoAt: savedVideoURL)
```

Embed closed captions in a MOV:

```swift
let export = try await pipeline.exportCaptions(
    segments: segments,
    videoURL: videoURL,
    format: .embeddedMovCaptions
)

let captionedVideoURL = export.videoURL
```

Embed multiple Unicode caption tracks without re-encoding video or audio:

```swift
let tracks = [
    try CaptionLanguageTrack(languageIdentifier: "en-US", segments: originalSegments),
    try CaptionLanguageTrack(languageIdentifier: "es-ES", segments: spanishSegments),
]
let export = try await pipeline.exportCaptions(
    tracks: tracks,
    videoURL: videoURL,
    format: .embeddedMovCaptions
)
```

Asset consent example:

```swift
let locale = Locale(identifier: "en-US")

if let requirement = await CaptionPipelineCapabilities.requiresAssetDownload(for: locale) {
    // Show host-app UI explaining Apple's speech model download.
    // Continue only after explicit user consent.
    try await CaptionPipeline.prepareAssets(for: requirement.locale, consentGranted: true)
}
```

## API Overview

- `CaptionPipeline`: transcribe, export, and write-SRT orchestration.
- `CaptionPipeline.Configuration`: host-app configuration for transcription, authorization, and prepared speech assets.
- `CaptionSegment`: timed caption text with start/end times.
- `CaptionLanguageTrack`: one validated Unicode caption track with a canonical BCP-47 tag.
- `CaptionTranscriptionConfiguration`: locale, asset policy, transcript debug logging, and provider preference.
- `CaptionTranscriptionResult`: transcript segments plus the provider that produced them.
- `CaptionOutputFormat`: `.embeddedMovCaptions` or `.srtSidecar`.
- `CaptionExportResult`: exported video URL, source segments, deferred single- or multilingual SRT values, and warning code.
- `CaptionError`: stable error cases and `code` strings for host-app localization.
- `CaptionPipelineCapabilities`: provider, locale, and asset-download capability helpers.
- `SpeechAuthorizationProviding`: injectable speech authorization boundary for apps and tests.

Async transcription, asset preparation, caption embedding, and SRT writing use explicit background execution semantics. The synchronous SRT methods remain available for 0.2.x source compatibility but are deprecated in favor of the async overloads.

Cancelling transcription or caption export propagates `CancellationError`. Caption-embedding timeouts still return the documented SRT fallback result, while AVFoundation cleanup continues independently when an SDK operation is slow to cancel.

## Privacy and Network

- User audio is transcribed on device.
- The package requests Speech authorization only when transcription starts.
- Network access is limited to Apple speech model downloads, and only after the host app passes explicit consent to `prepareAssets`.
- Production logs contain counts and error codes only. Transcript text is logged only when a caller opts into debug transcript logging in debug builds.

## Caption Export Behavior

- The single-language compatibility API embeds CEA-608 closed captions.
- The multilingual API embeds Unicode `tx3g` tracks with exact extended language tags and validates them before returning.
- Multilingual embedding forwards compressed video and audio sample buffers without re-encoding them.
- Empty or whitespace-only caption text is skipped.
- Long caption text is split into row-sized CEA-608 events so AVFoundation does not silently truncate it.
- If MOV embedding fails after transcription succeeds, `CaptionExportResult` preserves the original video URL and returns deferred SRT segments so the host app can offer a fallback file.
- If multilingual MOV embedding fails, every nonempty language is returned in `deferredSRTTracks`; the package never adopts a partial track set.
- SRT output is UTF-8, uses `HH:MM:SS,mmm` timestamps, and avoids an extra trailing blank separator.
- Multilingual SRT bundles use the original video basename plus canonical suffixes such as `Recording.es-ES.srt` and stage the complete bundle before replacing sidecars.

## Architecture

For a diagram-first view of provider selection, speech asset preparation, SRT writing, MOV embedding, and fallback behavior, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Apps Using OnDeviceCaptionKit

- [Mestre!](https://accessibilityupto11.com/apps/mestre/) - macOS screen recorder with optional embedded captions and SRT export.
- Let us know if you'd like your app to be listed here.

## Xcode Integration

1. In Xcode, open your project and select `File > Add Package Dependencies...`
2. Enter `https://github.com/dadederk/OnDeviceCaptionKit.git`.
3. Choose a version rule and add the `OnDeviceCaptionKit` library product to your target.

## Troubleshooting

- Speech authorization fails: request authorization from a user-visible flow and localize `CaptionError.code` values in the host app.
- A locale is unavailable: use `CaptionPipelineCapabilities.supportedTranscriptionLocales()` and let the user choose a supported locale.
- Asset download requires consent: call `requiresAssetDownload(for:)`, explain the Apple speech asset download, then call `prepareAssets(for:consentGranted:)` after consent.
- MOV embedding fails: preserve the original video and use `deferredSRTSegments` to write an SRT fallback.
- Import problems in Xcode: confirm your target links the `OnDeviceCaptionKit` product and uses a compatible macOS deployment target.

## Development

Run tests from the repository root:

```bash
swift test
```

Deterministic tests use local AVFoundation fixtures and stubbed muxers. CI tests must not depend on a real microphone, screen capture, network, or live Speech recognition.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release history and breaking-change notes.

## Support

See [SUPPORT.md](SUPPORT.md) for issue-reporting guidance and package support boundaries.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for local setup and PR guidelines.

## License

MIT. See [LICENSE](LICENSE).
