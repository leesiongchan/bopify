# Live free-release acceptance — 2026-10-14

Tested the mounted `Bopify-0.1.0-rc.2.dmg` from code commit `3c67e66`,
app version 0.1.0/build 250. The DMG checksum matched the prior release evidence:
`f570a2972ae48e3db4787c028b0d3d587949ddd03102447f1458fea097c2266b`.
Fresh strict/deep signature and capability verification passed: arm64, ad-hoc,
hardened runtime, sandbox/network/user-selected read-only capabilities, no
signing team or debugger entitlement. No installation or publication occurred.

## Observed results

| Check | Evidence | Result |
| --- | --- | --- |
| Existing sign-in restoration | `restore found=true`, credentials restored, connection ready at 21:31:38 +0800 | Passed for this Mac and saved grant |
| Audible playback | User: “audio works” | Passed |
| Audio-output switching | User: “it works” after switching/disconnect instructions | Passed for the reported interaction; exact devices and disconnect sequence unspecified |
| Sleep/wake playback | User: “audio resumes automatically”; macOS power records show actual sleep and wake | Passed for this short cycle |

Power records show software sleep at 21:42:47, dark wake at 21:42:49,
a second software sleep at 21:43:06, dark wake at 21:43:07, and full wake at
21:43:14 +0800. This does not establish an uninterrupted 30-second deep sleep,
long suspension, expired-session recovery or every audio-device configuration.
The app did not log a new connection-state transition during that sleep/wake
window; its sleep/wake callbacks do not themselves emit boundary logs. The user
confirmation establishes audible resumption, not execution of every recovery path.

## Diagnostics still requiring assessment

A session loss at 21:38:21.078929 returned to ready at 21:38:24.419507 +0800,
a 3.340578-second recovery. Engine teardown, recreation and player restoration
completed automatically. The reason was `Legacy`; the initiating cause is not
established and cannot be attributed to output switching from these logs.
Four playback error records describe this one recovery. A separate earlier
librespot error is privacy-redacted; its content and causal relationship are unknown.

Apple framework error records include failed `com.apple.linkd.autoShortcut`
registration (NSCocoaErrorDomain 4097), a CFBundle missing factory, TCP resets,
AppKit/Core Animation transaction diagnostics, transient missing/default audio
device lookups, and display/window diagnostics around wake. In particular,
`NSCGSTransactionCreatedDuringCommitError` appears in a diagnostic explaining
an invalid transaction during a Core Animation commit. No root cause or fix was
established in this acceptance run; successful playback does not prove these
messages harmless. The previously investigated `layoutSubtreeIfNeeded` warning
was not observed in this captured session, which does not close that issue.

## Evidence and remaining gates

Private local evidence is under `/private/tmp/bopify-live-rc2/`: `session.json`,
`runtime.ndjson`, `log-stream.stderr` and `diagnostic-summary.json`. Unified-log
privacy redaction stayed enabled. Raw account/runtime logs are not committed.
The diagnostic collector was stopped; the app remains open from the read-only
mounted image so playback is not interrupted.

Fresh OAuth consent, explicit real-account logout/re-consent, installation and
signing-update continuity, longer sleep/network loss, visual artwork recovery,
clean-Mac quarantine installation and hosted GitHub Actions remain unverified.
Paid Developer ID/notarization is outside the chosen free distribution route.
No production code, saved credentials, output settings or source branch was
edited by the test runner. No merge, push, tag or GitHub Release was performed.
