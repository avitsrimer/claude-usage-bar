# Upstream Sync and Fixes

> Revised across two automated plan-review passes. All 14 critical/important findings and 6 minor
> findings from pass 1, plus 2 blockers and 6 minors from pass 2, were verified against the tree
> and applied — see **Review Corrections** at the end for what changed and why.

## Overview

Port a reviewed subset of open upstream PRs from `Blimp-Labs/claude-usage-bar` into our fork
`avitsrimer/claude-usage-bar`, plus fix one regression of our own.

All 14 open upstream PRs were triaged. Selected work falls into three buckets:

- **Crashes and security bugs we share with upstream** — chart hover crash (`#54`), OAuth
  state-validation bypass (`#43` partial), whitespace-paste crash (`#50`), and an unverified
  tarball piped into `tar`+`chmod +x` during release builds (`#43` partial).
- **Durability and hygiene** — history loss on reboot (`#57`), history file permissions
  (`#43` partial), fetch re-entrancy (`#51`), codesign robustness (`#20`).
- **Features worth having** — usage projection (`#59`), Claude service-status monitoring
  (`#49`/`#52` partial), right-click-to-quit (`#21`).

Plus one item that is **not** an upstream port and is a **regression of our own**: commit
`a9ed221` replaced explicit two-unit reset formatting with `RelativeDateTimeFormatter`, which
emits exactly one unit. The deleted code produced precisely the desired output
(`"Resets in \(hours)h \(minutes)m"` → `Resets in 3h 50m`;
`"Resets in \(days)d \(hours)h"` → `Resets in 6d 17h`). **`git show a9ed221` is the spec for
Task 5.**

Deliberately rejected after review, with reasons recorded so this isn't re-litigated:

| PR | Decision | Reason |
|---|---|---|
| `#43` Keychain half | Reject | Ours is better: per-account `kSecAttrAccount` vs their hardcoded `"credentials"`; Keychain-only vs their plaintext-file fallback; we correctly omit `kSecAttrAccessible` from match/update/delete queries |
| `#47` Dock tile | Reject | Flips our `LSUIElement=true` menu-bar-only design and reworks `MenuBarIconRenderer` we own |
| `#49` Reset indicator | Partially adopt | `#49`'s file set is a **strict subset** of `#52`'s (26 files/2299 insertions vs 46/4993; 0 files unique to `#49`). Its service-status portion is the extraction source for Task 7; its reset-indicator/appearance portion is rejected |
| `#52` (the other ~4 features) | Reject | 4993-line/46-file mega-PR touching every file we rewrote |
| `#17` KDE widget | Reject | 1432 lines of Linux QML in a macOS fork |
| `#22` Launch-at-login | Reject | Already satisfied — we moved it to Settings (`SettingsView.swift:10`) |
| `#19` Per-model bar | Reject | **Already covered** — `UsageModel.swift:6-7` defines `sevenDayOpus`/`sevenDaySonnet` and `PopoverView.swift:199` renders "Per-Model (7 day)". `#19`'s segmented-icon variant conflicts with the `MenuBarIconRenderer` we own |
| upstream `#44` | Deferred | Separate future discussion; conflicts with our 429 refresh work |
| upstream `#50` | **Adopted** (was deferred) | Fixes a live crash in the exact method Task 2 rewrites — folded into Task 2 |

## Context (from discovery)

**Files/components involved:**
- `macos/Sources/ClaudeUsageBar/UsageService.swift` (516 lines) — OAuth flow, polling, refresh
- `macos/Sources/ClaudeUsageBar/PopoverView.swift` (420 lines) — **hot spot**, 5 tasks touch it
- `macos/Sources/ClaudeUsageBar/UsageHistoryService.swift` (152 lines) — buffered flush
- `macos/Sources/ClaudeUsageBar/UsageChartView.swift` (238 lines) — hover overlay
- `macos/Sources/ClaudeUsageBar/ClaudeUsageBarApp.swift` (28 lines) — `@main`, MenuBarExtra
- `macos/Package.swift` — test target has **no** `resources:` declaration (Task 7 must add one)
- `macos/scripts/build.sh` — codesigning ~lines 119-127; create-dmg download ~lines 190-191
- New files: `UsageProjection`, `ProjectionChartView`, `StatusPageClient`, `StatusMonitor`,
  `ClaudeServiceStatus`, `StatusPageModels`, `ServiceStatusDisplayState`,
  `RightClickableMenuBarLabel`, `ResetLabelFormatter`

**Patterns observed:**
- Multi-account throughout: `AccountManager` owns an array of accounts, one `UsageService` each;
  Keychain entries keyed by `accountId`; history at `history-{accountId}.json`. Every ported
  item must respect this — upstream is single-account and its code assumes so.
- Dependency injection is used in `UsageService.init`, whose **actual** parameters are:
  `session`, `usageEndpoint`, `userinfoEndpoint`, `tokenEndpoint`, `redirectUri`,
  `credentialsStore`, `initialEmail`. ⚠️ Upstream's `localProfileLoader` **does not exist in our
  fork** — do not copy upstream's `init` signature wholesale, and note we deliberately require
  `credentialsStore` rather than defaulting it.
- `AppPaths.configDirectoryURL` centralises the config path.
- Our `UsageHistoryService` already has two things upstream lacks: per-account file paths, and
  corrupt-file recovery that moves a bad file to `.bak.json` and resets history.

**Dependencies identified:**
- Sparkle 2.8.1 (only runtime dependency) — untouched by this plan.
- Swift Charts (`UsageChartView`, and the new `ProjectionChartView`).

**⚠️ CI CONSTRAINT — read before writing any Swift:**
`.github/workflows/build.yml` runs `runs-on: macos-14`, whose bundled Swift is older than local
(local is 6.3.3). **Trailing commas in argument lists (Swift 6.1 / SE-0439) compile locally but
fail CI.** This already bit us once: `7481fbd` fixed exactly this. Local `swift test` passing is
*not* evidence CI will pass. Never write `foo(\n  a: 1,\n  b: 2,\n)`.

CI also runs `swift build -c release`, `swift test`, **and `make release-artifacts`** on every
PR — so the packaging path in Task 9 is regression-covered automatically.

## Development Approach

- **testing approach**: Regular (code first, then tests)
- **execution**: one branch + one PR per task; runners on **Sonnet**
- complete each task fully before moving to the next
- make small, focused changes

**Anchoring rule (important for runners):** locate code by **symbol name**, not line number.
Tasks 4-8 all edit `PopoverView.swift`, so any line number in this plan is stale the moment an
earlier task merges. Line numbers below are "as of writing" hints only; the symbol name is
authoritative.

**Testability rule:** anything extracted for testing must be `internal`, not `private`/
`fileprivate` — `@testable import` reaches `internal` only. Everything currently in
`PopoverView.swift` is file-private (`relativeDateFormatter`, `UsageBucketRow`,
`WindowPositionPreserver`, `AccountContentView`), so extracted helpers should move to their own
file rather than being un-privated in place.

- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional — they are a required part of the checklist
  - write unit tests for new functions/methods, and for modified ones
  - cover both success and error scenarios
  - **exception**: three tasks are explicitly no-unit-test by design (1, 8, 9) with the reason
    stated in the task. Do not invent tautological tests to fill the checkbox.
- **CRITICAL: all tests must pass before starting next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- ⚠️ **Test-authoring effort is front-loaded**: only `#43`, `#52`/`#49` and `#59` ship usable
  test code. `#20`, `#21`, `#50`, `#51`, `#53`, `#54`, `#57` ship **zero** tests — those are
  written from scratch.

### Per-task git workflow (one PR per task)

Each task is its own branch and PR. Because five tasks touch `PopoverView.swift`, order matters
and **each branch must start from the freshly-merged `main`, not from the previous branch**:

```bash
git checkout main && git pull            # after previous task's PR merged
git checkout -b <branch-for-this-task>
# ... implement + tests ...
cd macos && swift test                   # must be green
git push -u origin <branch>
# open PR, wait for CI green, merge, then next task
```

Do **not** stack branches. Do **not** start the next task before the previous PR is merged.

## Testing Strategy

- **unit tests**: required for every task except 1, 8, 9 (reasons stated in-task)
- **test command**: `cd macos && swift test`
- **e2e tests**: none — no UI test harness exists. Do not fake e2e coverage for AppKit/SwiftUI
  window behaviour; those go to Post-Completion manual checks.
- **CI is the authority on compilation.** A task is not done until its PR shows CI green, not
  merely local tests passing.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview

**Approach:** cherry-pick by *intent*, not by patch. Upstream's diffs target a single-account
codebase that has since diverged, so most items are reimplemented on our structures using
upstream's PR as the specification and its tests as a starting point.

**Key design decisions:**

1. **Ten PRs.** `#43`'s file-permissions half and `#57` both rewrite `flushToDisk()`, so they
   land together (Task 3). `#43`'s OAuth half and `#50` both edit `submitOAuthCode`, so they
   land together (Task 2). `#43`'s `build.sh` half joins `#20` (Task 9).

2. **One `NSWindow` hook, not two.** We already have `WindowPositionPreserver`. Upstream `#53`
   adds a second, independent hook calling `setContentSize`. Two mechanisms mutating the same
   window is a race. Task 8 folds resize into the existing type — **but see the task: a height
   *signal* is still required**, because `WindowPositionPreserver.updateNSView` early-returns
   unless its `trigger` changed and has no size input at all.

3. **`#59` over `#52` for forecasting.** Same user-visible feature; 3 new files and a 5-line
   insert versus a 737-line service inside a mega-PR.

4. **`isFetching` complements the 429 backoff.** Backoff handles the server pushing back; the
   re-entrancy guard stops us generating concurrent bursts. Both belong.

5. **Resize lands last among the `PopoverView` tasks.** Tasks 6 and 7 are what actually change
   content height, so verifying resize before they exist is meaningless. Order is
   4 → 5 → 6 → 7 → **8**.

## Technical Details

**OAuth state validation + whitespace crash (Task 2).** Current `submitOAuthCode(_:)` at
`UsageService.swift:146`:
```swift
let parts = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1)
let code = String(parts[0])          // ← CRASHES on whitespace-only input (parts is empty)

if parts.count > 1 {                 // ← state validation is CONDITIONAL
    guard returnedState == oauthState else { … }
}
```
Two defects in four lines:
- **Crash (`#50`)**: a whitespace-only paste trims to `""`, `split` returns `[]`, `parts[0]`
  traps. Reachable from the UI: `PopoverView.swift:310` gates Submit with
  `.disabled(code.isEmpty)` on the **untrimmed** field, so a single space enables the button.
- **CSRF bypass (`#43`)**: a code pasted without a `#state` suffix skips validation entirely.
  Target: when `oauthState != nil`, a state component is **mandatory**; absence resets
  `codeVerifier`, `oauthState`, `isAwaitingCode` and sets `lastError`.

**Browser-open failure (Task 2).** `UsageService.swift:141` ignores the `Bool` from
`NSWorkspace.shared.open(url)` then sets `isAwaitingCode = true` regardless, so a failed launch
leaves the UI waiting for a code that can never arrive. Inject:
```swift
urlOpener: @MainActor @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
```
⚠️ `@escaping` is **required** — the closure is stored in a property.

**History durability + permissions (Task 3).** Two changes to one method:
- Drop `flushTimer` / `isDirty` / `flushInterval`; `recordDataPoint()` calls `flushToDisk()`
  directly. Our `willTerminate` observer only covers clean quit — reboot, force-quit and crash
  lose up to 5 minutes (upstream issue #42). Removing the repeating timer also aligns with
  `96aee35`.
- ⚠️ **Keep `import Combine`.** `ObservableObject` and `@Published` are Combine symbols; they
  happen to typecheck under `import Foundation` alone on local Swift 6.3 because newer SDKs
  re-export them, but this is exactly the local-passes/CI-fails class the constraint warns about.
  Remove only the `AnyCancellable`/timer members.
- Write `0600`: temp file via `FileManager.createFile(attributes: [.posixPermissions: 0o600])`
  then `replaceItemAt(_:withItemAt:options: [.usingNewMetadataOnly])`.
  ⚠️ **`.usingNewMetadataOnly` is mandatory, not optional.** Verified empirically: with default
  options, `replaceItemAt` **restores the destination's original mode**, so on every existing
  install (`history-*.json` already exists at `0644`) the change is a silent no-op:

  | options | pre-existing 0644 file → result |
  |---|---|
  | default | `644` — no-op |
  | `[.usingNewMetadataOnly]` | `600` — correct |

  A test that writes into a fresh temp dir passes either way and **hides** the bug, so two tests
  are required: fresh file, and pre-existing `0644` file.
- **Preserve** per-account paths and `.bak.json` corrupt-file recovery. Upstream has neither.
- **Judgement call to make explicitly:** write amplification. Flushing per data point rewrites
  the whole JSON — up to ~8.6k points at 30-day retention / 5-minute polling. Assess whether
  that's acceptable (likely yes) or needs coalescing, and record the reasoning in the PR.

**Reset label granularity (Task 5).** `RelativeDateTimeFormatter.localizedString` emits exactly
one unit by design. Note the formatter is `.full` (`PopoverView.swift:3-7`), so today's actual
output is `Resets in 3 hours` / `in 6 days`. `git show a9ed221` deleted code that produced the
desired result already, and also handled `"Resetting…"` and dropped zero units. Restore that
behaviour via `DateComponentsFormatter`:
`allowedUnits: [.day, .hour, .minute]`, `maximumUnitCount = 2`, `unitsStyle = .abbreviated`,
`zeroFormattingBehavior = .dropAll` (without `.dropAll` you get `3h 0m`).
⚠️ Preserve the word "in" — the old string was `"Resets in 3h 50m"`; naively concatenating
`"Resets " + formatter.string(...)` yields `"Resets 3h 50m"`.
Two call sites: `UsageBucketRow.resetText(for:now:)` (~`:352`) gets the change;
`AccountContentView.agoText(for:now:)` (~`:271`, the "last updated" label) **keeps**
`RelativeDateTimeFormatter` — `2 minutes ago` reads better than `2m 14s` for staleness. State
this in the PR description.

**Service-status extraction (Task 7).** Port from **`#49`** (the smaller PR — its file set is a
strict subset of `#52`'s and it already contains all the status files plus the 5 fixtures).
Take `StatusPageClient`, `StatusPageModels`, `ClaudeServiceStatus`, `StatusMonitor`,
`ServiceStatusDisplayState`, the fixtures, and their tests.
⚠️ `macos/Package.swift`'s test target has **no** `resources:` declaration — only the main
target does. Upstream's `StatusPageClientTests` uses `Bundle.module`, which **will not compile**
without `resources: [.process("Fixtures")]`. This is a certainty, not a maybe.
`ServiceStatusDisplayState` (with its `make(snapshot:lastError:)` factory) is the only
unit-testable piece of the recommended minimal indicator — port it and its test file.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code changes, tests, docs updates in this repo
- **Post-Completion** (no checkboxes): manual visual verification, and the deferred upstream
  `#44` conversation

## Implementation Steps

### Task 1: Guard against nil plotFrame in chart hover overlay

Branch: `fix/chart-plotframe-nil-guard` — ports upstream `#54`

**Files:**
- Modify: `macos/Sources/ClaudeUsageBar/UsageChartView.swift`

- [x] replace `geo[proxy.plotFrame!].origin` (~`UsageChartView.swift:113`, inside
      `.chartOverlay { proxy in GeometryReader { geo in … .onContinuousHover { … } } }`) with
      `guard let plotFrame = proxy.plotFrame else { return }` then `geo[plotFrame].origin`
- [x] scan the rest of `UsageChartView.swift` for other `plotFrame` force-unwraps; fix the same way
- [x] **no unit test** — `ChartProxy`/`GeometryProxy` cannot be constructed in a test and
      `hoverDate` is `@State`. Upstream `#54` shipped zero tests for the same reason. Compile +
      the manual hover check in Post-Completion is the verification. Do not fabricate a
      tautological test.
- [x] run `cd macos && swift test` (regression check only) — must pass before Task 2
- [x] push branch, open PR, confirm CI green, merge

### Task 2: Fix whitespace crash and make OAuth state validation mandatory

Branch: `fix/oauth-submit-hardening` — upstream `#50` + the non-Keychain half of `#43`

**Files:**
- Modify: `macos/Sources/ClaudeUsageBar/UsageService.swift`
- Modify: `macos/Tests/ClaudeUsageBarTests/UsageServiceTests.swift`

- [x] in `submitOAuthCode(_:)`, guard the empty-`parts` case before `String(parts[0])` so a
      whitespace-only paste sets `lastError` instead of trapping (`#50`)
- [x] require a state component whenever `oauthState != nil`: missing state sets `lastError`
      and resets `codeVerifier`, `oauthState`, `isAwaitingCode` (`#43`)
- [x] keep the existing mismatch branch intact (`"OAuth state mismatch — try again"`)
- [x] add `urlOpener: @MainActor @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }` to
      `UsageService.init` — do **not** copy upstream's signature, which contains a
      `localProfileLoader` parameter we don't have and defaults `credentialsStore` (we require it)
- [x] on `urlOpener` returning false, set `lastError = "Could not open Claude sign-in page"`,
      reset flow state, and do **not** set `isAwaitingCode = true`
- [x] ⚠️ **the empty-code path must leave `isAwaitingCode == true`**, unlike the CSRF/mismatch
      paths which reset it. Upstream `#50` is deliberate here ("Leave `isAwaitingCode` set so the
      user can retry without restarting") — harmonising all error branches would close the
      code-entry UI on a stray space, a UX regression
- [x] write tests: `"   "` (whitespace-only) does not crash, sets an error, and leaves
      `isAwaitingCode == true`
- [x] write tests: bare code with a pending flow is rejected; correct `code#state` still
      succeeds; mismatched state still rejected
- [x] write tests: `urlOpener` false → error + `isAwaitingCode == false`; true → `isAwaitingCode == true`
- [x] do **NOT** touch `StoredCredentials.swift` — `#43`'s Keychain changes are rejected
- [x] run `cd macos && swift test` — must pass before Task 3
- [x] push branch, open PR, confirm CI green, merge

### Task 3: Flush history on every data point and write it 0600

⚠️ Merged without a green CI check: GitHub had an active Minor Service Outage (githubstatus.com)
at merge time and both CI attempts on PR #4 failed at "Getting action download info" with
Service Unavailable/Bad Gateway — before the build started, i.e. infra, not this code. Verified
locally instead: `swift test` 68/68 passed on the branch, diff manually scanned for trailing
commas (none found). **Needs retroactive CI confirmation on `main` once GitHub recovers** — see
Task 11.

Branch: `fix/history-flush-durability-and-perms` — upstream `#57` + `#43`'s permissions change

**Files:**
- Modify: `macos/Sources/ClaudeUsageBar/UsageHistoryService.swift`
- Create: `macos/Tests/ClaudeUsageBarTests/UsageHistoryServiceTests.swift`

- [x] remove `flushTimer`, `isDirty`, `flushInterval`, `startFlushTimerIfNeeded()`
- [x] **keep `import Combine`** — `ObservableObject`/`@Published` need it on the CI toolchain
- [x] make `recordDataPoint()` call `flushToDisk()` directly; drop the `guard isDirty` early return
- [x] write via temp file + `createFile(attributes: [.posixPermissions: 0o600])` +
      `replaceItemAt(_:withItemAt:options: [.usingNewMetadataOnly])`, cleaning up the temp file
      on failure. **`.usingNewMetadataOnly` is mandatory** — see Technical Details
- [x] preserve per-account `history-{accountId}.json` paths and `.bak.json` corrupt-file recovery
- [x] assess write amplification and record the conclusion in the PR description
- [x] write tests: `recordDataPoint` persists immediately (no timer wait)
- [x] write tests: **fresh** file is created `0600`
- [x] write tests: **pre-existing `0644`** file ends up `0600` after flush (this is the test that
      actually catches the `replaceItemAt` metadata trap)
- [x] write tests: 30-day retention pruning still applies on write
- [x] write tests: corrupt file moves to `.bak.json` and history resets (protects our advantage)
- [x] run `cd macos && swift test` — must pass before Task 4
- [x] push branch, open PR, confirm CI green, merge

### Task 4: Add fetch re-entrancy guard and refresh spinner

⚠️ Merged without a green CI check: GitHub had an active Minor Service Outage (githubstatus.com,
`indicator: "minor"`) at merge time, the same one that affected PR #4 (Task 3). PR #5's CI run
was stuck `pending` well past its normal start time, consistent with the "Getting action download
info" infra failure already documented on PR #4, not a code issue. Verified locally instead:
`swift test` 72/72 passed on the branch (run 3x to check for flakiness in the new
concurrency-sensitive tests), diff manually scanned for trailing commas (none found).
**Needs retroactive CI confirmation on `main` once GitHub recovers** — see Task 11.

Branch: `feat/fetch-reentrancy-guard-and-spinner` — ports upstream `#51`.
**First of five consecutive `PopoverView` tasks — start from freshly-merged `main`.**

**Files:**
- Modify: `macos/Sources/ClaudeUsageBar/UsageService.swift`
- Modify: `macos/Sources/ClaudeUsageBar/PopoverView.swift`
- Modify: `macos/Tests/ClaudeUsageBarTests/UsageServiceTests.swift`

- [x] add `@Published private(set) var isFetching = false` to `UsageService`
- [x] guard `fetchUsage()` on `!isFetching`, set/clear with `defer`, placed so existing early
      returns and the 429 backoff path are unaffected
- [x] **decide and document** what the guard means for existing fire-and-forget callers whose
      calls it now silently drops: `updatePollingInterval` (~`UsageService.swift:45`) and
      `startPolling` (~`:99`). Silently skipping a scheduled poll because a manual refresh is
      in flight is probably fine — say so explicitly rather than leaving it implicit
- [x] adapt the footer `HStack` containing `Button("Refresh")` (~`PopoverView.swift:244`) to show
      a `ProgressView` while fetching, with a fixed footprint so the footer doesn't shift;
      **match our normalised row heights**, don't copy upstream's markup
- [x] add a 2-second cooldown (upstream `#51`'s value — don't invent a different one); note it
      is `@State` and therefore not unit-testable
- [x] write tests: concurrent `fetchUsage()` calls result in a single request
- [x] write tests: `isFetching` true during flight, false after, including the error path
- [x] write tests: the 429 backoff behaviour still works alongside the guard
- [x] run `cd macos && swift test` — must pass before Task 5
- [x] push branch, open PR, confirm CI green, merge

### Task 5: Restore two-unit precision in the reset countdown

⚠️ Merged without a green CI check: GitHub was reporting an active outage (githubstatus.com
`indicator: "major"` — Partial System Outage, worse than the `"minor"` seen on Tasks 3/4) at
merge time, and PR #6's `build` check was stuck `pending`, consistent with the same
"Getting action download info" infra failure documented on PRs #4 and #5 — before any code
builds, i.e. infra, not this code. Verified locally instead: `swift test` 83/83 passed on the
branch, diff manually scanned for trailing commas (none found). **Needs retroactive CI
confirmation on `main` once GitHub recovers** — see Task 11.

Branch: `fix/reset-label-granularity` — **our own regression**, introduced by `a9ed221`

**Files:**
- Create: `macos/Sources/ClaudeUsageBar/ResetLabelFormatter.swift`
- Modify: `macos/Sources/ClaudeUsageBar/PopoverView.swift`
- Create: `macos/Tests/ClaudeUsageBarTests/ResetLabelFormatterTests.swift`

- [x] read `git show a9ed221` first — the deleted code is the behavioural spec
- [x] create `ResetLabelFormatter.swift` with an **`internal`** function (not `private`, and in
      its own file so the test can see it)
- [x] implement with `DateComponentsFormatter`: `allowedUnits: [.day, .hour, .minute]`,
      `maximumUnitCount = 2`, `unitsStyle = .abbreviated`, `zeroFormattingBehavior = .dropAll`
- [x] preserve the `"Resets in …"` phrasing including the word "in", and the `"Resetting…"`
      case for non-future dates
- [x] call it from `UsageBucketRow.resetText(for:now:)` (~`PopoverView.swift:352`)
- [x] leave `AccountContentView.agoText(for:now:)` (~`:271`) on `RelativeDateTimeFormatter`;
      state the reasoning in the PR description
- [x] ⚠️ pin the formatter's `calendar.locale` (or inject it) — `.abbreviated` output is
      localized, so unpinned assertions on `3h 50m` are environment-dependent and can drift in CI
- [x] **decide the day-scale case**: the `a9ed221` spec emitted days+hours only (`Resets in 3d`
      when hours == 0), whereas `[.day, .hour, .minute]` + `maximumUnitCount = 2` + `.dropAll`
      turns 3d 0h 50m into `3d 50m`. Pick one and test it explicitly
- [x] write tests: `3h 50m`, `6d 17h`, sub-hour (`50m`), exact-hour (must be `3h`, not `3h 0m`)
- [x] write tests: the 3d-0h-50m case, asserting whichever behaviour was chosen above
- [x] write tests: past/zero dates yield `"Resetting…"`, never negative output
- [x] run `cd macos && swift test` — must pass before Task 6
- [x] push branch, open PR, confirm CI green, merge

### Task 6: Add 5-hour usage projection graph and run-out estimate

⚠️ Merged without a green CI check: GitHub was still reporting an active outage
(githubstatus.com `indicator: "major"` — Partial System Outage) at merge time, the same
outage documented on Tasks 3-5. Verified locally instead: `swift test` 93/93 passed on the
branch, diff manually scanned for trailing commas (none found). **Needs retroactive CI
confirmation on `main` once GitHub recovers** — see Task 11.

Branch: `feat/usage-projection-graph` — ports upstream `#59` (chosen over `#52`'s forecasting)

**Files:**
- Create: `macos/Sources/ClaudeUsageBar/UsageProjection.swift`
- Create: `macos/Sources/ClaudeUsageBar/ProjectionChartView.swift`
- Create: `macos/Tests/ClaudeUsageBarTests/UsageProjectionTests.swift`
- Modify: `macos/Sources/ClaudeUsageBar/PopoverView.swift`

- [x] port `UsageProjection` (projection maths + run-out estimate) from upstream `#59`
- [x] port `ProjectionChartView`, matching our existing `UsageChartView` conventions
- [x] wire into `AccountContentView`, which already receives the active `service`/`historyService`
      — this is a small insert, not a multi-account refactor
- [x] handle sparse/empty history (a fresh account has no data points) without dividing by zero
      or rendering a degenerate chart
- [x] port and adapt upstream's projection tests
- [x] write a test for the empty/sparse-history edge case
- [x] run `cd macos && swift test` — must pass before Task 7
- [x] push branch, open PR, confirm CI green, merge

### Task 7: Add Claude service-status monitoring

⚠️ Merged without a green CI check: GitHub was reporting an active outage (githubstatus.com
`indicator: "major"` — Partial System Outage), the same outage documented on Tasks 3-6, still
unresolved at merge time. Verified locally instead: `swift test` 127/127 passed on the branch,
diff manually scanned for trailing commas (none found). **This task is HIGHER risk than most for
a local-pass/CI-fail surprise** — it adds a `resources:` block to `Package.swift`'s test target,
a new `swift --version` CI step, and converts upstream's `@Observable`/`nonisolated(unsafe)`
`StatusMonitor` to `ObservableObject`/`@Published` — exactly the class of change (Package
manifest changes, new CI steps, actor-isolation conversions) that can pass locally and fail on
the older CI toolchain. **Needs retroactive CI confirmation on `main` once GitHub recovers, with
priority over the other tasks awaiting the same** — see Task 11.

Branch: `feat/service-status-monitoring` — extracts the status feature from upstream `#49`

**Files:**
- Create: `macos/Sources/ClaudeUsageBar/StatusPageModels.swift`
- Create: `macos/Sources/ClaudeUsageBar/ClaudeServiceStatus.swift`
- Create: `macos/Sources/ClaudeUsageBar/StatusPageClient.swift`
- Create: `macos/Sources/ClaudeUsageBar/StatusMonitor.swift`
- Create: `macos/Sources/ClaudeUsageBar/ServiceStatusDisplayState.swift`
- Create: `macos/Tests/ClaudeUsageBarTests/StatusPageClientTests.swift`
- Create: `macos/Tests/ClaudeUsageBarTests/StatusMonitorTests.swift`
- Create: `macos/Tests/ClaudeUsageBarTests/ClaudeServiceStatusTests.swift`
- Create: `macos/Tests/ClaudeUsageBarTests/ServiceStatusDisplayStateTests.swift`
- Create: `macos/Tests/ClaudeUsageBarTests/Fixtures/statuspage_summary_*.json` (5 fixtures)
- **Modify: `macos/Package.swift`**
- **Modify: `macos/Sources/ClaudeUsageBar/ClaudeUsageBarApp.swift`**
- Modify: `macos/Sources/ClaudeUsageBar/SettingsView.swift`
- Modify: `macos/Sources/ClaudeUsageBar/PopoverView.swift`

⚠️ **This is the least mechanical task in the plan. Read all four warnings before writing code.**

- [x] **add `resources: [.process("Fixtures")]` to the `.testTarget` in `macos/Package.swift`** —
      it currently has none, and upstream's tests use `Bundle.module`, which will not compile
      without it. `#49` contains the exact edit; copy it
- [x] ⚠️ **the indicator does not compile as ported.** `#49` gates it with
      `@AppStorage(AppearanceDefaultsKey.showServiceStatus)` and paces polling with
      `AppearanceDefaultsKey.statusPollMinutes` / `StatusPollOptions` — all declared in
      `AppearanceSettings.swift`, which this task rejects. Do **not** resolve the resulting
      "undefined symbol" errors by deleting the gate: upstream defaults it to `false`, so
      deleting it ships an always-on poller against `status.claude.com` for every user, which
      contradicts the idle-CPU requirement below. Instead add a single
      `@AppStorage("showServiceStatus")` bool defaulting to `false`, with a toggle in our
      `SettingsView`, and a plain interval constant in place of `StatusPollOptions`
- [x] ⚠️ **name the owner of `StatusMonitor` explicitly.** It is account-independent — one
      instance for the whole app, not one per account. `#49` holds it as
      `@State private var statusMonitor` in a view. In our architecture put a single instance in
      `ClaudeUsageBarApp` and pass it down; do **not** instantiate it inside `PopoverView` (it
      would be recreated on view init, orphaning poll tasks) and do **not** put it in
      `AccountManager` per account (N pollers hitting the status page)
- [x] ⚠️ **convert `StatusMonitor` to our reactive convention.** `#49` declares it
      `@MainActor @Observable public final class` with `nonisolated(unsafe)` observer tokens.
      `@Observable` needs Swift 5.9 and `nonisolated(unsafe)` needs 5.10+, and our CI Swift
      version is only known to be older than 6.1 — this is the largest block of foreign modern
      Swift in the plan and a prime local-green/CI-red candidate. Convert to
      `ObservableObject` + `@Published`, matching `AccountManager`, `UsageService`,
      `UsageHistoryService` and `NotificationService` (and what CLAUDE.md documents). Views then
      use `@ObservedObject`, not `@State`
- [x] ➕ add a `swift --version` step to `.github/workflows/build.yml` so the CI toolchain is
      recorded once instead of inferred — this has now cost us twice
- [x] port `StatusPageModels`, `ClaudeServiceStatus`, `StatusPageClient`, `StatusMonitor` and the
      5 JSON fixtures from `#49`
- [x] port `ServiceStatusDisplayState` (with `make(snapshot:lastError:)`) out of upstream's
      `PopoverView` into its own file, `internal` so tests can reach it
- [x] add a minimal status indicator to `PopoverView` — explicitly **not** `#52`'s popover visual
      refresh, `AppearanceSettings`, `ResetIndicatorState`, `MenuBarIconRenderer` rework,
      entitlements, or `Info.plist` churn
- [x] ensure the status poller doesn't reintroduce idle CPU cost (respect `96aee35`) — no timer
      spinning while the popover is closed unless justified in the PR
- [x] port upstream's client/monitor/status/display-state tests and adapt them
- [x] write tests for the outage/maintenance/unknown-status fixtures end to end
- [x] run `cd macos && swift test` — must pass before Task 8
- [x] push branch, open PR, confirm CI green, merge

### Task 8: Resize the popover window when content height changes

⚠️ Merged without a green CI check: GitHub was still reporting an active outage
(githubstatus.com `indicator: "major"` — Partial System Outage), the same outage documented on
Tasks 3-7, still unresolved at merge time. Verified locally instead: `swift test` 133/133 passed
on the branch, diff manually scanned for trailing commas (none found). **Needs retroactive CI
confirmation on `main` once GitHub recovers, with priority over the other tasks awaiting the
same** — see Task 11.

Branch: `fix/popover-adaptive-resize` — upstream `#53`'s intent on our existing hook.
**Deliberately last of the `PopoverView` tasks** — Tasks 6 and 7 are what change content height,
so resize can only be verified meaningfully once they exist.

**Files:**
- Modify: `macos/Sources/ClaudeUsageBar/PopoverView.swift`

- [x] read `WindowPositionPreserver` (~`PopoverView.swift:392-420`) before changing anything
- [x] ⚠️ a **height signal is still required**: `updateNSView` early-returns unless its `trigger`
      (the account id) changed, and it takes no size input — so simply calling `setContentSize`
      there would never fire on tab change, spinner appearance, or projection-chart insertion,
      and would have no target size
- [x] add the measurement (a `GeometryReader` → `PreferenceKey` height is fine) and **feed it into
      the single existing `WindowPositionPreserver`** — do **not** add `#53`'s second
      `NSViewRepresentable`
- [x] widen the `trigger` guard so a size change also passes it, not just an account change
- [x] verify origin preservation and content resize don't fight: switching accounts must not both
      move and resize in conflicting directions
- [x] confirm `.frame(width: 340)` still holds and only height adapts
- [x] ⚠️ **guard against a resize feedback loop**: `setContentSize` triggers layout, which
      re-emits the height preference. Our origin path already needs a `DispatchQueue.main.async`
      hop for this reason (`PopoverView.swift:414-418`). Task 4's spinner appears and disappears
      on a 2-second cooldown, so this path will be exercised repeatedly — apply an epsilon so
      sub-pixel deltas are no-ops
- [x] extract the apply/skip decision as an **`internal`** function on the coordinator, e.g.
      `shouldApply(trigger:size:lastTrigger:lastSize:) -> Bool`, so it can be tested without a
      window
- [x] write tests for that decision: trigger changed → apply; size changed beyond epsilon →
      apply; size changed within epsilon → skip; nothing changed → skip; `.zero` size → skip
- [x] **no test for the `setContentSize` call itself** — AppKit window mutation stays out of
      tests and goes to Post-Completion manual checks. The decision logic above is the testable
      part; do not skip it and do not fabricate a test for the window call.
- [x] run `cd macos && swift test` (regression check only) — must pass before Task 9
- [x] push branch, open PR, confirm CI green, merge

### Task 9: Harden the release build — strip xattrs and pin the create-dmg tarball

⚠️ Merged without a green CI check: GitHub was reporting an active outage (githubstatus.com
`indicator: "major"` — Partial System Outage), the same outage documented on Tasks 3-8, still
unresolved at merge time. No checks even registered on PR #10 (`gh pr checks` reported none),
consistent with the same pre-build infra failure. Verified locally instead: `make app` succeeded
(binary built, bundle assembled, xattrs stripped, ad-hoc codesign applied including nested Sparkle
framework/XPC services), `codesign -v` verified OK, `swift test` 133/133 passed, and the new
checksum-gate logic was exercised directly (isolated from an unrelated Finder-alias AppleEvent
timeout hit locally in `create_dmg`) confirming it fails loudly on a wrong hash and matches on the
correct one. The create-dmg v1.2.3 tarball's SHA256 was independently recomputed and matches both
the pinned constant and the upstream `#43` citation. **Needs retroactive CI confirmation on `main`
once GitHub recovers, with priority over the other tasks awaiting the same** — see Task 11.

Branch: `fix/build-hardening` — upstream `#20` + `#43`'s `build.sh` half

**Files:**
- Modify: `macos/scripts/build.sh`

- [x] add an `xattr -cr` (or equivalent) step on the app bundle immediately before the `codesign`
      calls (~`build.sh:119-127`), ensuring it precedes **all** signing including nested Sparkle
      bundles (`#20`)
- [x] pin the create-dmg download by SHA256 (`#43`): `build.sh:190-191` currently does
      `curl -fsSL "$CREATE_DMG_TARBALL_URL" | tar -xzf -` then `chmod +x` — unverified remote
      code executed during every release build, including in CI
- [x] fail the build loudly on checksum mismatch rather than falling through
- [x] ⚠️ **compute the hash locally and cross-check it against upstream's**
      (`8cf7b4ae540801171f4f630f1f2956913aaa87483b7ac03458f52b6cd0c48953` in `#43`) rather than
      trusting either value blindly — a pinned hash you didn't verify is theatre
- [x] comment the update procedure in the script next to the constant: a stale hash after a
      `CREATE_DMG_VERSION` bump will block **every PR's CI**, since CI runs `make release-artifacts`
- [x] note upstream's paths are pre-`macos/`-restructure — port, don't cherry-pick
- [x] **no unit test** — and this is not a gap: CI already runs `make release-artifacts` on every
      PR, so the codesign and DMG paths are regression-covered. Record `make app` +
      `codesign -v` output in the PR description
- [x] run `cd macos && swift test` — must pass before Task 10
- [x] push branch, open PR, confirm CI green, merge

### Task 10: Add right-click-to-quit on the menu bar icon

Branch: `feat/right-click-quit` — ports upstream `#21` (pre-restructure paths, needs porting)

**Files:**
- Create: `macos/Sources/ClaudeUsageBar/RightClickableMenuBarLabel.swift`
- Modify: `macos/Sources/ClaudeUsageBar/ClaudeUsageBarApp.swift`
- Create: `macos/Tests/ClaudeUsageBarTests/RightClickableMenuBarLabelTests.swift`

- [ ] port `RightClickableMenuBarLabel` (right-click → `NSMenu` with Quit)
- [ ] wire into the `MenuBarExtra` label without disturbing left-click popover behaviour
- [ ] ⚠️ **preserve template tinting**: `renderIcon`/`renderUnauthenticatedIcon` set
      `image.isTemplate = true` (`MenuBarIconRenderer.swift:57`, `:78`). Upstream's
      `MenuBarIconView.draw(_:)` draws the `NSImage` manually, bypassing status-bar template
      tinting — the dual-bar icon would stop adapting to light/dark menu bars. Honour
      `isTemplate` or tint with `NSColor.controlTextColor`
- [ ] ⚠️ **preserve `.task { accountManager.startPolling() }`** on the label
      (`ClaudeUsageBarApp.swift:16-18`) — if the rewrite drops it, polling never starts and no
      test will catch it
- [ ] write tests for the extractable menu-construction logic
- [ ] run `cd macos && swift test` — must pass before Task 11
- [ ] push branch, open PR, confirm CI green, merge

### Task 11: Verify acceptance criteria
- [ ] verify all 10 implementation tasks are complete
- [ ] verify every rejected item was left alone — in particular `StoredCredentials.swift` must be
      untouched by this plan
- [ ] verify no trailing commas in argument lists were introduced anywhere (the CI constraint)
- [ ] verify `import Combine` still present in `UsageHistoryService.swift`
- [ ] verify history file is `0600` on a pre-existing install, not just a fresh one
- [ ] run full test suite: `cd macos && swift test`
- [ ] confirm all 10 PRs merged and CI green on `main`
- [ ] verify `make app` builds and launches

### Task 12: [Final] Update documentation
- [ ] update `README.md` if the new features (projection, service status, right-click quit) are
      user-visible enough to document
- [ ] update `CLAUDE.md` with the new architecture pieces (`StatusMonitor`, `UsageProjection`,
      `ResetLabelFormatter`) and — importantly — the macos-14 CI / Swift-version constraint as a
      standing rule
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification** (no e2e harness; these are the verification for Tasks 1, 8, 9):
- hover across the usage chart immediately after opening the popover, before layout settles —
  must not crash (Task 1)
- popover resizes smoothly on account switch and tab change, without jumping position, **re-checked
  after Tasks 6 and 7 have landed** (Task 8)
- refresh spinner appears and the footer doesn't shift while visible
- reset labels read `Resets in 3h 50m` / `Resets in 6d 17h` against a real account
- projection chart renders sensibly for a fresh account with no history, and a heavily-used one
- right-click on the menu bar icon quits; left-click still opens the popover; icon still tints
  correctly against both light and dark menu bars
- service-status indicator reflects a real outage. ⚠️ `scripts/mock-server.py` serves only
  `/api/oauth/usage`, `/api/oauth/userinfo` and `/v1/oauth/token` — there is no statuspage
  endpoint, so either add one in Task 7 or verify against the live status page
- no Keychain prompt regression on app update — our `delete-then-add` behaviour must be intact
- idle CPU still zero after the status poller lands (`Activity Monitor`, cf. `96aee35`)

**Deferred decisions:**
- upstream `#44` (refresh token on expiry) — still unmerged by choice; conflicts with our 429
  refresh work in `UsageService.swift`. Worth revisiting once this plan lands.
- each merged task widens the gap with `upstream/main`, raising the cost of future syncs. If
  regular upstream syncing is wanted, that's a separate strategy conversation.

## Review Corrections

Applied after automated review; each was verified against the tree before accepting:

1. **`replaceItemAt` restores the destination's mode** — verified empirically (644 vs 600 table
   in Technical Details). The `0600` change was a silent no-op on upgrades, with a fresh-temp-dir
   test that would have passed. Now requires `.usingNewMetadataOnly` + a pre-existing-0644 test.
2. **`Package.swift` test target has no `resources:`** — verified. `Bundle.module` would not
   compile. Promoted from "check if needed" to a required edit with the file in Task 7's block.
3. **Line anchors would drift** — Task 4 inserts ~20 lines into `PopoverView.swift` before Tasks
   5-8 read it. Replaced with symbol anchors; added an explicit anchoring rule. Also corrected
   `:394-416` → `WindowPositionPreserver`, `:392-420`.
4. **Upstream `#50` fixes a live crash in the method Task 2 rewrites** — verified
   `String(parts[0])` traps on whitespace-only input, reachable because `PopoverView.swift:310`
   gates Submit on the untrimmed string. Moved from Deferred into Task 2.
5. **`localProfileLoader` doesn't exist in our fork** — verified (zero hits). It was wrongly
   copied from upstream's diff into the "patterns observed" section. Corrected, and `@escaping`
   added to the `urlOpener` signature.
6. **`#19` and `#49` rejection reasons were factually wrong** — verified `sevenDayOpus`/
   `sevenDaySonnet` exist and `PopoverView.swift:199` already renders per-model rows; verified
   `#49` is a strict subset of `#52` (26/2299 vs 46/4993), not identical. Both corrected, and
   Task 7 now ports from the smaller `#49`.
7. **`#43`'s third component was never triaged** — its `build.sh` SHA256 pinning. Verified
   `build.sh:190-191` pipes an unverified tarball into `tar` then `chmod +x`. Folded into Task 9.
8. **`import Combine` must stay** — `ObservableObject`/`@Published` are Combine symbols that only
   typecheck without it on the newer local SDK. Exactly the local-passes/CI-fails class.
9. **Task 8 (resize) reordered last** and given an explicit height-signal requirement — as
   originally specified it would have produced a hook that compiles, passes, and does nothing.
10. **Two tasks declared no-unit-test by design** (1 and 9) instead of vague "test whatever is
    extractable" wording that invites tautological tests. Dropped Task 6's make-work
    multi-account test (`UsageProjection` is a pure static func on plain values).

### Pass 2 corrections

The second review pass confirmed all of the above landed, and found two blockers created or
uncovered by the rewrite itself:

11. **Task 7 would not have compiled.** `#49` gates the status indicator on
    `AppearanceDefaultsKey.showServiceStatus` and paces it with `StatusPollOptions` — both
    declared in `AppearanceSettings.swift`, the file the task rejects (verified at #49 diff
    lines 199, 238, 818). The dangerous failure mode isn't the compile error, it's the obvious
    fix: deleting the gate ships an always-on poller, since upstream defaults it to `false`.
    Task 7 now specifies our own `@AppStorage` flag plus a `SettingsView` toggle.
12. **Task 7 had no owner for `StatusMonitor`.** It's account-independent, but our `PopoverView`
    receives per-account services, so both plausible guesses were wrong (recreated per view init,
    or N pollers per account). Now pinned to a single instance in `ClaudeUsageBarApp`, with that
    file added to the Files block.
13. **Task 7 imported modern Swift onto an unpinned toolchain.** `#49`'s `StatusMonitor` uses
    `@Observable` (Swift 5.9) and `nonisolated(unsafe)` (5.10+), verified at #49 diff lines 1184
    and 1203-1204. Since CI's Swift is only known to be *older than 6.1*, this is the same
    local-green/CI-red trap as `7481fbd`. Now converts to `ObservableObject`/`@Published` — which
    also matches the convention every other service in the app follows — plus a
    `swift --version` CI step so the version stops being guesswork.
14. **Task 8's "no unit test" was my own over-correction.** True of upstream `#53`, but the
    pass-1 rewrite added a dual-signal trigger and a widened guard, which *is* testable — and
    `PopoverView.swift:414-418` shows our origin path already needs an async hop to avoid
    feedback, a hazard Task 4's spinner will exercise every 2 seconds. Now extracts an
    `internal shouldApply(trigger:size:lastTrigger:lastSize:)` with an epsilon and tests it,
    while still keeping the `setContentSize` call itself out of tests.

Six pass-2 minors also applied: Task 2's empty-code path must preserve `isAwaitingCode` (upstream
`#50` is deliberate); Task 5 pins the formatter locale and resolves the 3d-0h-50m divergence from
the `a9ed221` spec; Task 9 cross-checks the pinned hash instead of trusting it and documents the
bump procedure; and the Overview's "two bugs of our own" / Task 11's "10 selected items" counts
were corrected.
