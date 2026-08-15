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
   +--> writeSRT(segments:besideVideoAt:) async
   +--> writeSRT(tracks:besideVideoAt:) async
   |
   +--> exportCaptions(segments:videoURL:format:)
   +--> exportCaptions(tracks:videoURL:format:)
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

CaptionLanguageTrack array
   |
   +--> SRTWriter
   |       |
   |       v
   |   Atomically adopted UTF-8 SRT bundle
   |
   +--> Tx3gCaptionTrackWriter
           |
           v
       Unicode text tracks
           |
           v
       Passthrough composition with source video/audio
           |
           v
       Caption alternate-group header repair
           |
           v
       Tx3gCaptionTrackReader validation
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

Multilingual MOV embedding fails
   |
   v
CaptionExportResult keeps original videoURL
and returns every nonempty deferredSRTTrack
```

The package preserves enough structured output for host apps to offer a sidecar fallback without losing successful transcription work.

## Concurrency Model

The package uses Swift 6.2 Approachable Concurrency without default main-actor isolation. Public transcription, embedding, asset-preparation, and async SRT-writing entry points are marked `@concurrent` so CPU, file, Speech, and AVFoundation work leaves caller isolation explicitly.

Synchronous state shared with Objective-C callbacks is protected by `Synchronization.Mutex`. SDK references without checked sendability are confined to small immutable transfer wrappers whose lifetime and access invariants are documented beside each conformance.

Caption embedding keeps a continuation-based timeout race instead of a task group. This is intentional: the timeout continuation can resume the caller even if an AVFoundation operation ignores task cancellation. `CaptionPipeline` owns the total export timeout when it supplies the shared cancellation holder, while the embedder retains a short timeout for every caption-movie write and the final passthrough export. Cleanup-capable races atomically reserve one of eight outstanding slots before starting, while an owned `OperationQueue` runs at most two potentially blocking SDK cancellation calls concurrently. A reservation remains held until both SDK cleanup and the losing operation finish, bounding queued cleanup and stuck-task retention during a timeout burst; further embedding work fails fast to the existing fallback until capacity returns. Pure timeout races without SDK cleanup do not consume these reservations. Temporary-file deletion is requested as soon as cancellation wins but is deferred by operation and cleanup leases until every task that may still be using or creating those files has finished and AVFoundation cancellation has returned. The losing timeout/progress tasks are cancelled, and the progress task is awaited before a successful export returns.
