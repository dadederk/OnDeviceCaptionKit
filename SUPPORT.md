# Support

Use GitHub Issues for reproducible OnDeviceCaptionKit bugs, documentation problems, and focused feature requests.

## Before Filing

- Check the README, architecture doc, changelog, and contributing guide for current package scope.
- Reduce the issue to the smallest audio/video input or synthetic segment set that reproduces it.
- Confirm whether the problem is package transcription/export behavior or consuming-app UI, recording, or fallback messaging.

## Include In Bug Reports

- macOS, Swift, and Xcode version.
- Output format: `embeddedMovCaptions` or `srtSidecar`.
- Recognition provider if known: `modern` or `legacy`.
- Locale and asset-download state if relevant.
- `CaptionError.code` or `CaptionExportResult.warningCode`, if available.
- Minimal synthetic caption segments, fixture details, or reproduction steps.

Questions about UI, localization strings, save panels, settings, recording, microphone capture, screen capture, or Mestre-specific behavior belong with the consuming app unless OnDeviceCaptionKit's transcription or export result is wrong.
