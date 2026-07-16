# Contributing

Thanks for your interest in improving OnDeviceCaptionKit.

## Local Setup

1. Clone the repository.
2. Open a terminal in the repository root.
3. Run package tests:

```bash
swift test
```

## Development Guidelines

- Keep transcription and export behavior deterministic where tests can observe it.
- Preserve the privacy contract: user audio is transcribed on device, and network use is limited to user-approved Apple speech model downloads.
- Keep UI, localization strings, settings, save panels, recording, and microphone capture in consuming apps.
- Add or update Swift Testing coverage for behavior changes.
- Do not add third-party dependencies without explicit discussion.
- Do not add tests that depend on a real microphone, screen capture, network, external services, or live Speech recognition.

## Pull Requests

1. Create focused changes with clear commit messages.
2. Add or update tests for behavior changes.
3. Update documentation when public API, privacy behavior, or export behavior changes.
4. Ensure `swift test` passes before opening the PR.

## Reporting Issues

When filing a bug, include:
- macOS version and Swift/Xcode version.
- Output format (`embeddedMovCaptions` or `srtSidecar`).
- Recognition provider if known (`modern` or `legacy`).
- `CaptionError.code` or `CaptionExportResult.warningCode`, if available.
- A minimal reproducible sample or synthetic caption segments when possible.
