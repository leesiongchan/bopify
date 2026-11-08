# Unified onboarding and Soloist startup recovery

Approved scope: the user's 2026-11-07 request to fix Soloist startup, integrate playback and library access into onboarding, redesign the setup experience, and remove obsolete windows/code.

## Observed startup cause

The private session PID identified an installed Spotify-signed Soloist process started at 16:04:13. Its parent was PID 1, no Bopify process was running, and the application's session flock was available. The old launcher refused every live PID and mapped this refusal to a generic key/connection error. A fresh synthetic-key launch demonstrated that the installed CLI supports the supplied flags and creates its loopback endpoint.

Spotify documents `soloist.pid`, `ws.addr`, and `ws.port` as runtime files, and a second process using the same data directory as a startup failure: https://developer.spotify.com/documentation/soloist/reference/command-line (accessed 2026-11-07).

## Recovery contract

Under the private session's exclusive application lock, automatically retire an orphan only after proving current-user ownership, parent PID 1, immutable Bopify installation location, Spotify static and running-code identity, exact data/cache arguments, and unchanged process birth identity. Never adopt a process, signal an arbitrary PID, or escalate to SIGKILL for a process not launched by this application lifetime. Preserve credentials and data. A busy live application or failed proof produces a specific recovery action.

Log fixed failure categories, exit status, and recovery milestones; never record arguments, key material, vendor payloads, or raw stderr. Distinguish storage, occupied session, launch, daemon exit, and endpoint timeout from key validation.

## Experience

Use the existing main-window record surface for three stages: Spotify sign-in; library app registration and authorization; Soloist key, automatic installation, and pairing. Reuse completed authorization and saved keys. A shared route controls content and window size so retained track metadata cannot hide setup or squeeze it into record geometry. Keep form identity stable during progress changes.

Delete separate Playback Engine and Library Access windows and standalone setup views. A single Setup menu action reopens the same inline surface; completed setup can return to listening without restarting audio. Keep an explicit per-session librespot recovery option while preserving Soloist as the next-launch default. Missing companion features or Spotify throttling must not block working local Soloist audio.

## Verification

Regression coverage must reproduce occupied/orphan session behavior and prove negative ownership checks. Run an opt-in real signed-CLI test with a synthetic key and disposable session, including orphan recovery, restart, and actual local protocol replies. Extend signed-app acceptance beyond download/version validation to daemon startup and restart. Verify native form entry, secure text, keyboard actions, scroll reachability, routing, cancellation, and completed setup. Real personal-key pairing and audible playback require interactive account acceptance and must not be represented by these credential-free checks.
