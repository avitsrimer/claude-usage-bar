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

## Architecture

Multi-account service pattern with SwiftUI reactive state:

**AccountManager** (`AccountManager.swift`) — top-level service locator owned by `@main`. Holds an array of accounts, instantiates one `UsageService` per account, and exposes the active account's service to views.

**UsageService** (`UsageService.swift`) — per-account workhorse. Handles OAuth PKCE flow (browser-based, user pastes code), token storage in Keychain, polling the `GET /api/oauth/usage` endpoint, and token refresh on 401/429. Publishes `@Published` properties consumed by views.

**UsageHistoryService** (`UsageHistoryService.swift`) — buffers incoming data points in memory and flushes to `~/.config/claude-usage-bar/history.json` every 5 minutes. Handles 30-day retention and downsampling for chart rendering.

**NotificationService** (`NotificationService.swift`) — threshold-based macOS notifications. Defers `UNUserNotificationCenter` setup until the user explicitly requests permission (avoids startup prompt).

**MenuBarIconRenderer** (`MenuBarIconRenderer.swift`) — draws the dual-bar mini icon representing 5h and 7d utilization percentages.

**UI layer** — `PopoverView.swift` (main popover with tabs), `SettingsView.swift` (polling interval, thresholds, accounts), `UsageChartView.swift` (Swift Charts line+fill with 1h/6h/1d/7d/30d range selector).

**Data persistence paths** — all local data lives under `~/.config/claude-usage-bar/` via `AppPaths.swift`. Tokens go to Keychain at 0600 permissions.

## Release Process

Releases are tag-driven via GitHub Actions:
1. Push a semver tag (e.g., `v1.2.3`) to trigger `.github/workflows/release.yml`
2. CI builds the release binary, creates ZIP + DMG, signs the Sparkle appcast (EdDSA), and deploys to GitHub Pages

Do not manually create releases — the workflow handles everything including appcast generation.

## Testing

The mock server (`scripts/mock-server.py`) provides 10 scenarios covering edge cases like token expiry, 429 rate limit responses, and different usage levels. Use it when testing OAuth flows or error handling without hitting the real API.
