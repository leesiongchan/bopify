# Library authorization and setup diagnostics

Status: approved by the user on 2026-11-03, design and written spec. Third of four reliability specs. It adds code −7 to the FFI contract introduced in `2026-11-03-connection-resilience-design.md`.

## Intent and scope

The user kept today's rule: a library authorization loss returns to setup and stops playback (introduced in be774f6). This spec makes sure only a *confirmed* loss does that, makes setup failures diagnosable, and blocks setup until both sign-ins belong to the same Spotify account.

Verified defects:

- **One HTTP 401 tears down playback.** `SpotifyLibraryClient` turns any 401 into `authorizationRequired` with no refresh or retry. `PlayerRootView` then calls `requireLibrarySetup()`, which stops recovery, Now Playing, lyrics and the player. Token-generation races and the logout flag also surface as `authorizationRequired`.
- **A transient refresh failure blocks launch.** `finishSetup` refreshes the library token; a network, 5xx or Keychain failure sends the user to setup.
- **A deleted dashboard app retries forever.** A refresh answered with `invalid_client` maps to `.unknown`, then `LibraryError.unavailable`, so the client keeps retrying.
- **Every consent failure shows the same message.** "Approve all four" appears even when the port is in use, the user declined, the network failed or Keychain failed. An unknown Client ID or an unregistered redirect URI leaves setup waiting forever.
- **Setup can succeed without working access.** Setup checks only scopes. A user missing from the app's User Management passes, then sees generic shelf errors (Spotify returns 403).
- **No account check.** Nothing compares the library account with the playback account, so likes and saves can go to a different account than the one playing.

Dashboard refresh tokens expire six months after consent regardless of use, so every user eventually reaches the confirmed-loss path.

Out of scope:
- persisting library data to disk;
- the Liked Songs revisit refetch;
- `market` and `is_playable`;
- session reads for Spotify-owned playlists;
- changing callback port 8898, since every registered redirect URI depends on it.

## Approaches

Losses are classified where the evidence exists. `SpotifyLibraryClient.request` is the only place that sees both the token and the 401, so the refresh-and-retry lives there; the token provider alone cannot do it.

For the account check, the comparison runs in Rust before the Connect task starts. No playback or restore begins on a mismatch, and the playback username never crosses the FFI boundary. Calling `/v1/me` with the playback token was rejected: it is unverified, and it runs on Spotify's shared desktop client, which Spotifast reports is rate-limited from the first Web API request.

## Loss classification

- **`TokenClient`:**
  - `invalid_client` becomes the new `PlayerError.clientRejected`;
  - `invalid_grant` stays `authExpired`.
- **`SpotifyAuthService`:** a token-generation race or the logout flag throws `CancellationError` instead of `authExpired`.
- **Make the scoped `validAccessToken(requiredScopes:rejecting:)` public**, and add `LibraryAuthorization.validAccessToken(requiredScopes:rejecting:)`.
- **Confirmed loss** keeps today's teardown through `requireLibrarySetup`. It now carries a `LibrarySetupReason` that the setup screen shows. The reasons:
  - `invalid_grant` on refresh;
  - a 401 again after a forced refresh;
  - missing scopes;
  - no grant, or a corrupt grant;
  - `clientRejected`;
  - `/v1/me` 403;
  - account mismatch (code −7).
- **Transient**, with no teardown: network errors, 5xx, 429, a locked Keychain, races. Shelves show their existing retryable errors.
- **Launch gating.** `finishSetup` gates only on a stored grant with the required scopes. A transient refresh failure at launch proceeds to `connect()`.

## `SpotifyLibraryClient`

- **Token provider** becomes `(scopes, rejecting: String?)`.
- **On 401:** request a forced refresh that rejects the failed token, then retry once. A second 401 is `authorizationRequired`.
- **On a GET 5xx:** retry once after 800 ms, respecting cancellation and the shared cooldown. PUT and DELETE are never retried automatically.
- **Success:** accept any 2xx response.

## Setup diagnostics

- **Per-cause consent messages** replace the single `librarySetup.consentFailed`:

  | Cause | Message |
  |---|---|
  | `authDenied` | declined |
  | EADDRINUSE | "Port 8898 is in use by another app. Close it and try again." (new `CallbackError.portInUse`) |
  | missing scopes | current text |
  | `clientRejected` | "Spotify doesn't recognise this Client ID." |
  | offline | offline |
  | Keychain errors | existing `PlayerError` text |

- **Client ID probe on Save.**
  - `POST https://accounts.spotify.com/api/token` with `grant_type=authorization_code`, a dummy code, the redirect URI and a random verifier.
  - Only `invalid_client` blocks the save. Every other answer, including network failure, proceeds.
  - This behaviour was observed on 2026-11-02 and is undocumented by Spotify, so it is best-effort. It does not detect an unregistered redirect URI.
- **Consent timeout.** Both sign-ins time out after 10 minutes. The listener stops, the port is freed, and the user sees "Sign-in timed out" with Try again.
- **While waiting for the browser:**
  - show the hint "If Spotify says 'Invalid redirect URI', add http://127.0.0.1:8898/callback exactly";
  - offer an **Open again** action that reopens the same consent URL.
- **After library consent, call `GET /v1/me`** with no extra scope:
  - **403:** setup cannot finish. Show "Add this Spotify account under your app's User Management. The app owner needs Spotify Premium."
  - **200:** supplies the account `id`.
  - **Any other failure:** skips the account check without blocking.

## Account binding

- **When to check.** At launch and after consent, call `/v1/me` with a 5 s budget before `connect()`.
- **Passing the id.** Pass its `id` as an optional `expectedAccount` in the engine-create options. It is held in memory, reused across recovery rebuilds and never logged.
- **Rust (`Engine::new`):**
  - After `Spirc::new` returns and before the Connect task is spawned, compare `session.username()` with `expectedAccount`.
  - On a mismatch, drop the session and return −7 `AccountMismatch`. Add −7 to `contracts/ffi-error-codes.json`.
  - Log only `match=true|false`.
- **Swift:**
  - The recovery coordinator treats −7 as terminal: `.failed(.accountMismatch)`, with no automatic retry.
  - `AppEnvironment` observes that state and routes to `requireLibrarySetup(reason: .accountMismatch)`: "Library is connected to a different Spotify account than playback."
  - Actions:
    - **Reconnect library** reopens consent with `show_dialog=true`, so Spotify shows its page again and the user can switch account;
    - **Sign out**.
- **Skipped check.** When `/v1/me` is unavailable, `expectedAccount` is absent and no check runs.
- **Prerequisite.** Before implementing this section, verify live that librespot's canonical username equals the `/v1/me` `id` for the same account, including case. If it does not, stop and return to the user.
  - librespot does not expose `/v1/me`'s newer `account_id`. So this compares two live grants at one moment and is never persisted as a long-term link.

## Verification

Tests are written first:

- **Auth tests:**
  - `invalid_client` maps to `clientRejected` (`TokenClientTests`);
  - a race and the logout flag become cancellation;
  - a forced refresh with scopes.
- **`SpotifyLibraryClientTests`:**
  - 401 then success;
  - 401 twice is `authorizationRequired`;
  - one retry for a GET 5xx and none for PUT;
  - 201 and 204 are accepted.
  - This replaces `statusMappingAndNoRetries`.
- **`LoopbackCallbackListenerTests`:** an occupied port yields `portInUse`.
- **Probe classification:** `invalid_client` blocks; `invalid_grant`, other answers and a network error proceed.
- **Consent timeout,** using an injected clock.
- **App tests:**
  - a transient refresh failure at launch still connects;
  - a confirmed loss still tears down (`revokedAccessReturnsToSetupAndRequiresANewCompleteGrant` stays);
  - `/v1/me` 403 and −7 reach setup with the right reason;
  - a skipped check does not block.
- **Rust:**
  - a mismatch returns −7 without spawning the Connect task;
  - a matching or absent `expectedAccount` proceeds;
  - the contract entry.

Run the Swift package tests, the app tests, `scripts/test-native.sh`, clippy and a Release build. Manually verify setup with:
- an unknown Client ID;
- a missing redirect URI;
- port 8898 held by another process;
- a non-allowlisted account;
- a second account.

## Research

- Spotify, [Refreshing tokens](https://developer.spotify.com/documentation/web-api/tutorials/refreshing-tokens): Dashboard refresh tokens last six months from authorization and refreshing does not extend them. `invalid_grant` means "start the appropriate authorization code flow… instead of retrying".
- Spotify, [Quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes): non-allowlisted users can log in, but API requests receive 403; the app owner needs Premium.
- Spotify, [Redirect URIs](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri): exact match, loopback IP literals allowed. [RFC 6749 §4.1.2.1](https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2.1): the server must not redirect to an invalid redirect URI, so the app cannot observe a mismatch.
- Spotify, [Authorization code flow](https://developer.spotify.com/documentation/web-api/tutorials/code-flow): `show_dialog` forces the consent page.
- Spotify, [May 2026 changes](https://developer.spotify.com/documentation/web-api/references/changes/may-2026) and [February 2026 migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide): `/v1/me` keeps `id` and adds `account_id`.
- Spotifast v0.16.0 ([crmne/spotifast@3767d53](https://github.com/crmne/spotifast/tree/3767d53)): the Client ID probe in `src/auth.rs`, 403-to-AccountNotAllowed in `src/backend.rs`, and the account-match guard for playback credentials.
