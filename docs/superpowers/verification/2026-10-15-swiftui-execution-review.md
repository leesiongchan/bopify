# SwiftUI execution review

Fresh read-only review by gpt-6-astra covered `18157f8..1af804b`. No production regression or Critical issue was identified. One Important evidence-validation finding entered the single fix pass; no second review was requested.

## Fixed Important finding

The previous validators could accept outside-mode closure without click delivery evidence and accept reordered lifecycle logs. New negative assertions were observed failing against the prior validator (six assertions; no test errors), then all 11 parser tests passed against the correction. Both validators require ordered mode-specific markers, binding intent, actual tagged click delivery before outside closure, and no popover activity in the control. The mouse observer matches the fixture window number, blank click position and a per-process event tag.

The corrected Swift fixture compiled with Swift 6 warnings-as-errors targeting macOS 14. A fresh 18-run matrix validated six clean controls, six binding reproductions and six unavailable outside-click runs, with zero invalid runs. Missing-close and malformed-argument controls returned 2. Existing tooling tests passed 27/27. The production accessibility correction is unchanged from the reviewed version; its Debug build, 360 Swift tests and fake recovery probe passed before this verification-only fix.

Evidence: `/private/tmp/bopify-scene-review-all-red.log`, `/private/tmp/bopify-scene-popover-reviewed/`, `/private/tmp/bopify-swiftui-review-tooling-tests.log`.

## Resolved Minor findings (2026-10-15)

Both wording corrections were completed following the user's instruction:

- Updated the design to state that the declarative App/Window reproduction was tested, linked its evidence, and retained the outside-click qualification limit.
- Narrowed the production comment to the observed local accessibility element. Exported-client/VoiceOver verification remains open.

## Review limits and rulings

Actual menu selection, pending-action state changes, keyboard/Escape, long-label parity and macOS 14 runtime remain unqualified; no SwiftUI replacement shipped. VoiceOver/exported-client behavior remains a gate. Existing native recovery-probe internals are retained, and its passing direct-action checks do not establish public input parity. Historical framework diagnostics and shell migration remain unresolved.

Execution rulings, including their consequences:

- Task 1: Ruling: launch fixture modes with -- prefix — bare positional modes suppress normal SwiftUI window creation as document-open arguments; --control produced validated lifecycle — cost if wrong: fixture launch evidence would be invalid, never product changes. Added a 12-second lifecycle watchdog so silent startup cannot pass.
- Task 2: Ruling: require foreground/key-window activation for outside-click qualification and return 77 when denied — failing runs showed active=false/key=false; Apple cooperative activation does not guarantee focus, and forcing it would interfere with user — cost if wrong: outside-click evidence remains unavailable instead of a false pass. Preserve first matrix invalid runs separately.
- Ruling: retain direct fixture launch and mark denied input activation unavailable — LaunchServices reopening was tested but caused early popover dismissal before the requested binding close; removed that interference — cost if wrong: input acceptance remains open, not a product change.
- Task 1: Ruling: measure capsule with SwiftUI GeometryReader and record AX bounds independently — native AX frame is 91x26 for a correctly constrained 94x24 layout; AX frame is not a layout-size contract — cost if wrong: visual comparison remains required to catch overflow.
- Task 1: Ruling: defer replacing native-specific recovery-probe assertions when public menu input cannot be qualified — preserve existing action coverage rather than weaken it; standalone fixture records unavailable input independently — cost if wrong: migration acceptance needs later UI evidence. Task 2 candidate will stay outside production; --candidate-source permits the same fixture to compare it without editing shipping source.
- Task 2: Ruling: fix the native cell accessibility label while retaining the adapter — baseline local AXMenuButton is NSPopUpButtonCell and lacked the full restoration name; setting the cell label passed all nine visible states without changing layout/callbacks — cost if wrong: exported-client/VoiceOver verification remains open. This is a two-line native metadata correction, not the unqualified SwiftUI replacement.
- Final: Ruling: actual menu selection, pending-action updates, keyboard/Escape, long-label and macOS14 runtime parity remain gates — no SwiftUI replacement shipped — cost if wrong: future replacement needs fresh acceptance before release.
- Final: Ruling: VoiceOver/exported-client behavior remains unqualified — local cell-name correction proven, external client not tested — cost if wrong: assistive-client behavior may differ.
- Final: Ruling: retain native-specific recovery assertions — existing fake-engine coverage passed, public-input parity not claimed — cost if wrong: later migration still needs updated acceptance.
- Final: Ruling: historical diagnostics and shell migration stay unresolved — standalone SwiftUI still reproduces warning and shell contract remains — cost if wrong: OS-specific behavior needs another supported OS and validated fix.
