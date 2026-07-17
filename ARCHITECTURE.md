# OnDeviceCaptionKit Architecture

This document describes the current OnDeviceCaptionKit package architecture with a diagram-first view.

## Caption Pipeline

```text
CaptionPipeline
   |
   +--> transcribe(from:)
   |       |
   |       v
   |   Provider selection
   |       |
   |       +--> ModernSpeechProvider (SpeechAnalyzer)
   |       |
   |       +--> LegacySpeechProvider (SFSpeechRecognizer)
   |
   +--> writeSRT(segments:besideVideoAt:)
   |
   +--> exportCaptions(segments:videoURL:format:)
```

The pipeline coordinates transcription and export while keeping UI, localization copy, file pickers, recording, and fallback messaging in the consuming app.

## Provider Selection

```text
Configuration provider preference
   |
   v
CaptionPipelineCapabilities
   |
   v
Modern provider when available
   |
   v
Legacy provider fallback when needed
```

The provider boundary keeps Speech framework differences isolated from host apps. Tests use injectable authorization and provider seams so package behavior stays deterministic without live microphone or speech recognition dependencies.

## Asset Preparation

```text
Locale
   |
   v
requiresAssetDownload(for:)
   |
   +--> nil: transcription can proceed
   |
   +--> requirement: host app asks for consent
                  |
                  v
          prepareAssets(for:consentGranted:)
```

Speech asset downloads are Apple-managed and require explicit host-app consent before preparation.

## Export Flow

```text
CaptionSegment array
   |
   +--> SRTWriter
   |       |
   |       v
   |   UTF-8 .srt sidecar
   |
   +--> CaptionEmbedder
           |
           v
       CEA-608 caption events in .mov
```

SRT writing owns timestamp formatting and text wrapping. MOV embedding owns CEA-608 event preparation and AVFoundation muxing.

## Failure and Fallback Boundary

```text
Transcription succeeds
   |
   v
MOV embedding fails
   |
   v
CaptionExportResult keeps original videoURL
and returns deferredSRTSegments
```

The package preserves enough structured output for host apps to offer a sidecar fallback without losing successful transcription work.
