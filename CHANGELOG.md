# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-16

### Added
- Initial public release of OnDeviceCaptionKit.
- Added on-device caption transcription with modern SpeechAnalyzer support and legacy SFSpeechRecognizer fallback.
- Added SRT sidecar generation with deterministic timestamp formatting and caption text wrapping.
- Added CEA-608 MOV closed-caption embedding using AVFoundation.
- Added host-app capability helpers for supported locales, preferred provider, and speech asset download requirements.
- Added typed errors, warning codes, and injectable Speech authorization boundary for app localization and tests.
