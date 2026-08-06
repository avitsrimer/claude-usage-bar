# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

macOS menu bar app (Swift/SwiftUI) that displays Claude API usage (5h and 7d rate limits) as a dual-bar icon. Supports multiple accounts, usage history charts, and threshold notifications. Requires macOS 14+. Single runtime dependency: Sparkle 2.8.1 for auto-updates.

## Commands

```bash
# Build & run
make app                # build release binary + create .app bundle + codesign
make install            # build + copy to /Applications

# Testing
cd macos && swift test  # run all unit tests

# Release artifacts
make release-artifacts  # build once, create both ZIP and DMG
make verify-release     # inspect packaged artifacts

# Dev with mock server
python3 scripts/mock-server.py  # start mock API (10 scenarios for edge cases)

# Cleanup
make clean
```

## CI constraint: Swift toolchain

CI (`macos-14` runner, `.github/workflows/build.yml`) runs a Swift toolchain older than 6.1 — older
than most local installs. Trailing commas in argument/parameter lists (Swift 6.1 / SE-0439) compile
locally but fail CI; this has broken CI twice (`7481fbd`, and repeatedly flagged during the
upstream-sync work). A local `swift test` pass is not proof CI will pass — avoid trailing commas in
argument lists, and be wary of other newer-Swift syntax (e.g. `@Observable`, `nonisolated(unsafe)`)
that may not exist on the CI toolchain. `.github/workflows/build.yml` runs a `swift --version` step
so the CI toolchain version is recorded rather than inferred.

## Architecture

Multi-account service pattern with SwiftUI reactive state:

**AccountManager** (`AccountManager.swift`) — top-level service locator owned by `@main`. Holds an array of accounts, instantiates one `UsageService` per account, and exposes the active account's service to views.

**UsageService** (`UsageService.swift`) — per-account workhorse. Handles OAuth PKCE flow (browser-based, user pastes code), token storage in Keychain, polling the `GET /api/oauth/usage` endpoint, and token refresh on 401/429. Publishes `@Published` properties consumed by views.

**UsageHistoryService** (`UsageHistoryService.swift`) — buffers incoming data points in memory and flushes to `history-{accountId}.json` on every `recordDataPoint()` call (immediate, not timer-based — durable across reboot/force-quit). Writes `0600` via a temp file + `replaceItemAt(_:withItemAt:options: [.usingNewMetadataOnly])`. Handles 30-day retention, downsampling for chart rendering, and corrupt-file recovery (moves a bad file to `.bak.json` and resets history).

**NotificationService** (`NotificationService.swift`) — threshold-based macOS notifications. Defers `UNUserNotificationCenter` setup until the user explicitly requests permission (avoids startup prompt).

**MenuBarIconRenderer** (`MenuBarIconRenderer.swift`) — draws the dual-bar mini icon representing 5h and 7d utilization percentages.

**Service-status monitoring** (`StatusMonitor.swift`, `StatusPageClient.swift`, `ClaudeServiceStatus.swift`, `StatusPageModels.swift`, `ServiceStatusDisplayState.swift`) — polls Anthropic's status page and surfaces outage/maintenance state in the popover. `StatusMonitor` is a single app-wide `ObservableObject` instance owned by `ClaudeUsageBarApp`, not per-account (status is account-independent, unlike everything else here), and is off by default behind a `showServiceStatus` `@AppStorage` toggle in `SettingsView`. `StatusPageClient`/`StatusPageModels` fetch and decode the statuspage.io summary JSON; `ClaudeServiceStatus` models the resulting status; `ServiceStatusDisplayState.make(snapshot:lastError:)` maps that into what `PopoverView` renders.

**UsageProjection / ProjectionChartView** (`UsageProjection.swift`, `ProjectionChartView.swift`) — projects the 5-hour usage trend forward from recent history and estimates a run-out time, rendered as a small chart in `PopoverView` alongside the usage bars. `UsageProjection` is pure math over plain values (no service dependency) and handles sparse/empty history without dividing by zero.

**ResetLabelFormatter** (`ResetLabelFormatter.swift`) — formats the "Resets in …" countdown with two-unit precision (`3h 50m`, `6d 17h`) via `DateComponentsFormatter`, used by `PopoverView`'s `UsageBucketRow`. The "last updated" label elsewhere intentionally stays on `RelativeDateTimeFormatter` (single-unit reads better for staleness).

**UI layer** — `PopoverView.swift` (main popover with tabs), `SettingsView.swift` (polling interval, thresholds, accounts, service-status toggle), `UsageChartView.swift` (Swift Charts line+fill with 1h/6h/1d/7d/30d range selector).

**Data persistence paths** — all local data lives under `~/.config/claude-usage-bar/` via `AppPaths.swift`. Tokens go to Keychain at 0600 permissions.

## Release Process

Releases are tag-driven via GitHub Actions:
1. Push a semver tag (e.g., `v1.2.3`) to trigger `.github/workflows/release.yml`
2. CI builds the release binary, creates ZIP + DMG, signs the Sparkle appcast (EdDSA), and deploys to GitHub Pages

Do not manually create releases — the workflow handles everything including appcast generation.

## Testing

The mock server (`scripts/mock-server.py`) provides 10 scenarios covering edge cases like token expiry, 429 rate limit responses, and different usage levels. Use it when testing OAuth flows or error handling without hitting the real API.
