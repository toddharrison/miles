# 0013. Project structure and deployment target

- Status: accepted
- Date: 2026-11-06

## Context

ADR 0012 requires the core logic to be separable from the UI. The user's machines run macOS 27, and the app targets the Apple Foundation Models framework by default (ADR 0003).

## Decision

- **Xcode project** for the app (signing, entitlements, app bundle), with a **local Swift package** holding the logic.
- Package modules: `MilesCore`, `MilesAI`. App target: `MilesApp`. A command-line target, `miles-cli`, uses the package for scanning, querying and restoring without the UI.
- Filesystem access goes through a protocol so tests can fake iCloud placeholders, missing drives and similar cases. Tests use Swift Testing against temporary directory trees.
- **Minimum deployment target is macOS 27.** Older macOS versions are not supported.
- The core package does not depend on SwiftUI or AppKit.

## Consequences

- The UI can be replaced or extended without touching logic, and the CLI doubles as a debugging and test tool.
- Requiring macOS 27 lets the default AI providers be used without fallbacks. Any Mac the portable drive visits must also run macOS 27 to open the app copy.
- The CLI is extra surface to maintain, accepted for faster testing and debugging.
