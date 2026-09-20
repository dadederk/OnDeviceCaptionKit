# Agent Guidance

OnDeviceCaptionKit is a Swift 6.2 macOS package for on-device transcription and caption export. This file is for any coding agent working in the repository; contributors do not need a personal skill installation.

## Start Here

1. Read `ARCHITECTURE.md` for pipeline, provider, export, and concurrency boundaries. Use `CONTRIBUTING.md` for contribution rules and `README.md` for public API behavior.
2. Inspect the nearest source and tests before changing behavior.
3. Run `swift test` after code changes. For concurrency-sensitive or release-facing changes, also run `swift build -c release -Xswiftc -warnings-as-errors` and `swift test --enable-code-coverage -Xswiftc -warnings-as-errors`, as CI does.

## Boundaries

- Preserve the privacy contract: user audio stays on device; Apple speech model downloads require host-app consent.
- Keep UI, localization copy, file pickers, recording, microphone capture, and fallback presentation in consuming apps.
- Preserve provider selection, structured fallback results, SRT output, and embedding behavior. Keep tests deterministic and independent of live Speech recognition, hardware, network, and external services.
- Follow the concurrency model in `ARCHITECTURE.md`: no default main-actor isolation, explicit `@concurrent` public work, and bounded cleanup for embedding timeouts. Do not simplify cancellation or temporary-file lifetime rules without focused tests.
- Keep public APIs source-compatible unless a breaking change is explicitly intended. Do not add third-party dependencies without discussion.

## Optional Skills

When available, consult `swift-concurrency` for isolation and cancellation, `swift-testing-expert` for Swift Testing, and `swift-api-design-guidelines-skill` for public API design. These are personal/global aids, not repository dependencies. The checked-in docs and tests remain authoritative for contributors without them.
