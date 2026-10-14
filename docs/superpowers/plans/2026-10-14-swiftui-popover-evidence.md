# SwiftUI Popover Evidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Determine whether a fully declarative SwiftUI window reproduces the existing popover transaction diagnostic, without changing Bopify.

**Architecture:** A separate SwiftUI App owns its Window scene and popover. Public AppKit notifications observe lifecycle only; they do not construct or mutate the window/popover. Process-scoped OSLog evidence distinguishes a clean observation, reproduced diagnostic and invalid run.

**Tech Stack:** Swift 6, SwiftUI, OSLog, public AppKit lifecycle observation, Python standard library. No dependencies.

**Spec:** [Approved SwiftUI-first design](../specs/2026-10-14-swiftui-first-migration-design.md), execution sequence 1. Approved in chat after commit `c3a7369`.

## Global Constraints

- Keep the existing macOS 14 minimum pending an explicit decision to raise it.
- No Spotify session, output device, credential or installed app needs to change.
- Keep warning reproduction results separate from migration results.
- Submission of an Apple report needs separate authorization.
- Work in `/Users/leesiongchan/.codex/worktrees/7e93/bopify`; do not change production UI or the running app.

## Review Focus

- Missing popover closure must invalidate a run rather than count as diagnostic-free; Task 1 tests it.
- A real outside-click dismissal must be distinguished from binding changes and performClose; Task 1 observes it.
- Unavailable log access or missing markers must invalidate evidence; Task 1 validates both.
- A clean run on one OS must not imply an OS-specific fix; Task 2 records the exact OS and outstanding comparison.
- A failed subprocess must not truncate the matrix or become a passing summary; Task 2 tests aggregation with synthetic results.

### Task 1: Declarative-window fixture with validated evidence

**Files:** Create `docs/superpowers/verification/SwiftUIScenePopoverTransactionRepro.swift`.

**Interfaces (new, fixture-only):** CLI `SwiftUIScenePopoverTransactionRepro binding|outside|control|missing-close`. Emit `RESULT: mode=… lifecycleValidated=… diagnostics=… invalidTransactions=…`. Exit 0 for valid evidence without target diagnostics, 1 for valid evidence with them, 2 for invalid lifecycle/log evidence or arguments, 77 for unavailable outside-click automation. No shipping interface changes.

- [ ] Implement an `@main` SwiftUI App with one unique `Window`, fixed fixture content and a `.popover(isPresented:)`. Observe NSPopover didShow/didClose weakly and SwiftUI content appearance/disappearance. Use the existing diagnostic needles and Logger subsystem from `SwiftUIPopoverTransactionRepro.swift`; capture all process log entries after fixture start, not only matches.
- [ ] Validate ordered, exactly-once start/show-request/show/close-request/close/collection markers in both memory and OSLog. Missing-close intentionally leaves the popover open and must exit 2. Control presents no popover and must prove its own start/window/collection markers. Use bounded waits for lifecycle events; a timeout is invalid evidence.
- [ ] Binding mode changes only the SwiftUI binding. Outside mode clicks a clearly identified blank point in the fixture's own window through public event automation; require didClose without a binding-dismiss request or direct NSPopover close call. If trust/input delivery is unavailable, return 77 and retain the unverified gate; do not enable permissions automatically or click another app.
- [ ] Compile: `xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor -warnings-as-errors -target arm64-apple-macosx14.0 -module-cache-path /private/tmp/bopify-scene-popover-cache docs/superpowers/verification/SwiftUIScenePopoverTransactionRepro.swift -o /private/tmp/SwiftUIScenePopoverTransactionRepro`. Expect exit 0. Run missing-close and malformed arguments; both must return 2. Run control, then binding/outside serially and inspect complete logs. A diagnostic result is an observation, not a failed implementation.
- [ ] Commit the fixture after reviewing that AppKit is used only for observation, test input and process termination, never host ownership.

### Task 2: Reproducible matrix and bounded conclusion

**Files:** Create `docs/superpowers/verification/run-swiftui-scene-popover-probe.py`, `docs/superpowers/verification/test_scene_popover_runner.py`, and `docs/superpowers/verification/2026-10-14-swiftui-scene-popover-evidence.md`.

**Interfaces (new):** Runner CLI `python3 docs/superpowers/verification/run-swiftui-scene-popover-probe.py --output <absolute-directory>`. Build the Task 1 fixture as an isolated .app with a unique fixture bundle identifier and a macOS 14 minimum. Run binding/outside/control six times each, serially, with a 30-second per-process timeout. Persist complete stdout/stderr, source SHA-256, OS/compiler versions and per-run exit status. Summary JSON records `valid_clean`, `reproduced`, `invalid`, or `unavailable` for each run; never collapse these into one pass flag.

- [ ] Write Python unittest cases for result parsing/aggregation: validated exit 0 is clean; validated exit 1 is reproduced; missing RESULT/markers, exit 2 and timeout are invalid; exit 77 is unavailable. Assert an invalid/unavailable run remains visible when other runs are clean. These tests cover our evidence boundary, not OSLog or SwiftUI.
- [ ] Implement the runner using subprocess argument arrays and task-owned output paths. Continue collecting remaining modes after individual failures. Return 2 if any run is invalid, 77 if any required run is unavailable, otherwise 1 if any reproduces and 0 if all are clean. Keep all per-run statuses despite summary precedence.
- [ ] Run `python3 -m unittest discover -s docs/superpowers/verification -p test_scene_popover_runner.py`; expect all tests pass. Run the runner with `--output /private/tmp/bopify-scene-popover-evidence`. Inspect every result and complete warning stack. Capture fixture-only before/after screenshots where capture permission is available; record missing screenshots explicitly.
- [ ] Write the evidence report: matrix counts by mode, exact OS build, lifecycle validity and artifact locations. Compare with existing host/panel results without claiming an ownership cause from a negative sample. A second supported OS remains a gate if unavailable. Leave both existing production AppKit findings open unless direct evidence resolves them.
- [ ] Run `git diff --check`, inspect the diff for accidental product changes and commit fixture/runner/tests/report. Do not submit feedback, publish a release or alter the running rc2 app.

## Handoff and later work

Execute this plan before the separate recovery-menu plan. A reproduced warning does not block menu qualification; invalid evidence requires fixing the fixture before interpreting its results. No window-shell replacement follows automatically. macOS 15 gesture migration and Library Access scene migration remain deferred decisions.
