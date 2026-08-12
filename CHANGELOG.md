# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
