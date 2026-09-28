# Separate library OAuth verification

Status: implementation and controlled verification complete on `feat/separate-library-oauth`; live library acceptance awaits consent under the Dashboard app.

The app uses public Dashboard client ID `25bbd3bacca4412b80f17b892072af71` for Web API library access and stores its grant under `my.snsoft.bopify.library`. Playback retains librespot's ID and `my.snsoft.bopify`. Liked Songs requests `user-library-read`; favorites can widen that library grant to `user-library-modify`. Library consent never requests `streaming`. The two features continue sharing one library client and its 429 cooldown.

The Dashboard app must register `http://127.0.0.1/login` as a redirect URI. The existing loopback listener adds its dynamic port at runtime, as allowed for a loopback IP literal by [Spotify's redirect URI guidance](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri). Registration has not been confirmed in this environment. Library consent is initiated only by an existing Enable action, using Spotify's [PKCE flow](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow).

## Observed checks

- Full Swift package suite: 191 tests passed (96 playback, 34 library, 22 domain, 39 auth). Log: `/private/tmp/bopify-library-postreview-tests.log`.
- macOS app build: exit 0. Log: `/private/tmp/bopify-library-postreview-build.log`.
- Native `library`, `refinement`, and `mirror` probes: exit 0, run sequentially. The library probe covers explicit consent, one in-flight Enable action, read/write scope recovery, no playback from browsing, quit preserving both grants, sign-out clearing both grants, and late consent leaving browsing cleared.
- Focused auth tests cover empty library grant, scope widening, insufficient returned scope, sign-out during a pending callback, distinct Keychain services, lazy grant restoration without browser OAuth, and a stored playback scope never leaking into library consent. The latter failed before the scope filter and passed after it.
- The request test verifies read and write scope selection and a library-only bearer token at the Web API boundary. Existing tests verify fixed Spotify origin, redirect rejection, and one shared cooldown for Liked Songs and favorites after a 429.
- The independent review found a sign-out race: the UI still appeared signed in while library Keychain clearing suspended the main actor. A native regression failed on the old order and passed after publishing `.signedOut` before the first suspension. A concurrent read/favorite cooldown test also passes.
- The read-only `live-library` probe exited 77: `BLOCKED: existing session lacks library read authorization`. It did not open a browser or send a Web API request. No token, response body, or library content was printed. Log: `/private/tmp/bopify-library-live.log`.
- `git diff --check` passed. The main worktree's `Localizable.xcstrings` edits were untouched.

After the user confirms the callback is registered and invokes Enable Liked Songs in the app, rerun `--probe live-library` once. Record whether Spotify accepts the request or returns 429, including the sanitized rate-limit category and `Retry-After`. A separate client ID does not guarantee a larger allowance; see [Spotify's rate-limit guidance](https://developer.spotify.com/documentation/web-api/concepts/rate-limits) and [quota mode guidance](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).
