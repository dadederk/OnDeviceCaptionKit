# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Unicode TX3G tracks use the generic `Sans-Serif` authored fallback family while native players remain responsible for applying system caption-appearance preferences.

## [0.3.3] - 2026-08-16

### Changed
- Package OSLog output now uses the host bundle identifier and the `subtitles` category so consuming-app caption logs share one correctly capitalized subsystem and category.
- TX3G diagnostics now use consistent capitalization and distinguish payload decoding from playback validation.

### Fixed
- Authored Unicode TX3G under the modern subtitle handler instead of the legacy text handler, making embedded languages playable in QuickTime and AVPlayer.
- Applied the source video's presentation dimensions to each subtitle track and its default text region.
- Added playback, handler, decoded-cue, language, and media-sample fixture coverage so a metadata-only but unplayable caption track can no longer pass package validation.

## [0.3.2] - 2026-08-15

### Changed
- Unicode MOV export now authors caption-only `tx3g` tracks before combining them with source video and audio through an AVFoundation passthrough composition.
- Unicode embedding timeouts now scale with source duration and file size within bounded limits, with phase, workload, and elapsed-time diagnostics that do not log caption text or filenames.

### Fixed
- Prevented production recordings with sparse or discontinuity media samples from stalling the grouped writer and falling back to multilingual SRT after a fixed timeout.
- Restored a shared alternate caption group after passthrough export so every language remains selectable while compressed video and audio payloads stay byte-identical.

## [0.3.1] - 2026-08-14

### Fixed
- Replaced a timing-sensitive cleanup admission assertion with deterministic synchronization so the supported Xcode CI matrix remains stable.

## [0.3.0] - 2026-08-14

### Added
- Added `CaptionLanguageTrack` with canonical BCP-47 language identifiers and validated monotonic segments.
- Added multilingual Unicode `tx3g` MOV export through `CaptionPipeline.exportCaptions(tracks:videoURL:format:progressHandler:)`.
- Added `CaptionExportResult.deferredSRTTracks` so every nonempty language falls back together when Unicode embedding fails.
- Added atomic multilingual SRT bundles with canonical language suffixes through `CaptionPipeline.writeSRT(tracks:besideVideoAt:)`.

### Changed
- Unicode MOV export validates exact language tags, text, and millisecond timing before returning the staged movie.
- Multilingual MOV muxing forwards compressed video and audio sample buffers through one grouped AVAssetWriter pass without re-encoding.
- Existing single-language APIs continue to use the CEA-608/SRT compatibility pipeline.

### Fixed
- Split modern time-indexed finalized passages into readable cues while preserving their exact attributed audio ranges.
- Failed modern recognition atomically when any recognized nonblank run lacks valid timing instead of collapsing or dropping transcript text.
- Preserved short legacy-recognizer speech that was previously discarded, restored pause boundaries, and based cue ranges on recognized-word timing instead of surrounding silence.
- Bounded legacy cues by duration and readable text length without dropping recognized words.

## [0.2.1] - 2026-08-12

### Fixed
- Prevented preferred silent-gap chunk boundaries from moving so early that a later caption movie exceeds the four-caption AVFoundation limit.

## [0.2.0] - 2026-08-12

### Added
- Added async `writeSRT` overloads for writing beside a video or to an explicit destination.
- Added explicit background execution semantics for transcription, embedding, asset preparation, and file writing.

### Changed
- Adopted Swift 6.2 Approachable Concurrency with inferred isolated conformances and nonisolated nonsending defaults.
- Public async entry points and protocol requirements now carry explicit concurrency annotations; rebuild client modules when adopting 0.2.0.
- Replaced protected synchronous state with `Synchronization.Mutex` and checked `Sendable` conformances where SDK types permit them.
- Made caption export progress cleanup cancellation-safe and retained bounded timeout return when AVFoundation ignores cancellation.
- Parent cancellation now propagates as `CancellationError` instead of being converted into an SRT fallback result.

### Fixed
- Fixed a race that could start timeout work after its parent task was already cancelled.
- Kept timeout completion independent from potentially blocking AVFoundation cancellation.
- Bounded blocking cleanup work and failed fast to the existing fallback when cleanup capacity is saturated.
- Kept temporary caption and output files owned by in-flight work until AVFoundation has stopped using them.
- Restored a short timeout for each caption-movie write and the final passthrough export.
- Atomically bounded cleanup-capable timeout races while allowing timeout work without SDK cleanup to proceed independently.
- Deferred temporary-file deletion until every late AVFoundation operation has released its file-ownership lease.
- Replaced cross-task `AVCaption` transfers with checked-Sendable text and timing snapshots.
- Added cooperative cancellation during legacy Speech result processing and prevented pre-cancelled recognition from starting.

### Deprecated
- Deprecated synchronous `writeSRT` entry points; they remain available for 0.2.x source compatibility.

## [0.1.0] - 2026-07-16

### Added
- Initial public release of OnDeviceCaptionKit.
- Added on-device caption transcription with modern SpeechAnalyzer support and legacy SFSpeechRecognizer fallback.
- Added SRT sidecar generation with deterministic timestamp formatting and caption text wrapping.
- Added CEA-608 MOV closed-caption embedding using AVFoundation.
- Added host-app capability helpers for supported locales, preferred provider, and speech asset download requirements.
- Added typed errors, warning codes, and injectable Speech authorization boundary for app localization and tests.
