# Separate Spotify client for library access

Status: design for review, 2026-09-28. Based on the user's approval to separate Web API library access from librespot playback. Implementation and live account verification await the public Spotify Developer Dashboard client ID.

## Problem and outcome

Bopify currently authorizes playback and Web API library requests under librespot's shared client ID. A live saved-track request returned HTTP 429 with `Retry-After: 16` and no `QUOTA_EXCEEDED` marker. The shared ID is a plausible source of contention, but that response does not prove where the rate pressure came from. The just-merged cooldown prevents Bopify's favorite checks from continuing HTTP requests during Spotify's stated wait; it does not give library traffic an app-specific identity.

Use the user's Spotify Developer Dashboard client ID for Liked Songs and favorite read/write calls. Keep the existing librespot client ID for playback. The browser's consent page for library access should identify the user's Dashboard app. Playback remains usable if library authorization is absent, denied, or rate limited.

## Authentication and storage

The playback `SpotifyAuthService` remains unchanged in purpose and retains its existing Keychain service (`my.snsoft.bopify`). Add a second `SpotifyAuthService` with the Dashboard ID and `KeychainTokenStore(service: "my.snsoft.bopify.library")`. Never reuse a playback token for a Web API request under the Dashboard app. The public Dashboard client ID belongs in source as a named constant after the user supplies it; no client secret is needed for the existing PKCE flow.

Add a library authorization entry point that can acquire requested scopes when the library store is empty and can widen an existing library grant. It must request only the library scopes required by the user's action: `user-library-read` for Liked Songs, and read plus `user-library-modify` for favorite changes. It must not include `streaming`. Continue validating returned scopes, PKCE state, and the callback. The current loopback listener uses an OS-assigned port and `/login`; the Dashboard app must register `http://127.0.0.1/login` without a port. Spotify permits a dynamic port for a registered loopback IP literal.

`AppEnvironment` composes one `SpotifyLibraryClient` with the library auth service's token provider. Favorite and liked-song models keep sharing that client and its 429 cooldown. Opening the player restores the library token only when a library request needs it; missing consent presents the existing enable action. A failed library authorization preserves playback state. Sign-out clears both Keychain items and invalidates both pending auth generations; quit preserves both items. A late library authorization after sign-out cannot restore credentials or browsing state. An existing playback grant with library scopes is not silently migrated: the Dashboard app requires its own explicit consent once.

## App behavior and limits

Liked Songs and favorite operations continue using the existing fixed Web API endpoints and read/write scope checks. Browsing never starts playback. The selected song still plays through the existing librespot session. The library cooldown and distinct quota response remain in force. No automatic reauthorization opens a browser; the existing Enable actions initiate it.

The dashboard app may be in Development Mode. Spotify limits authorized users and Web API traffic there, and its quotas are counted across that developer account's Development Mode apps. A separate ID can isolate Web API rate traffic from the shared librespot ID, but it cannot guarantee that Spotify will accept every request. A client ID alone is not a secret or a rate-limit bypass.

## Verification

1. Controlled auth tests: library consent with an empty store requests only library scopes and its Dashboard ID; widening the grant retains read scope, omits streaming, uses a distinct Keychain service, and rejects stale completion after sign-out.
2. Composition tests: playback restore succeeds while library consent is absent; enabling liked songs and favorites uses the second auth service; failed consent leaves playback active; sign-out clears both token stores; quit preserves them.
3. Request tests: the library client presents a Dashboard-issued token to `GET /me/tracks` and favorite endpoints, preserves fixed-origin and redirect protections, and shares the cooldown. Playback still receives its librespot-issued token.
4. Native checks: Enable Liked Songs opens the Dashboard app's consent, then Cover Flow loads individual saved tracks without starting playback. Existing Cover Flow, favorite, remote mirror, and transport probes remain green.
5. Live check after Dashboard ID and callback registration: authorize once, fetch one saved-track page, and record the HTTP outcome and sanitized rate-limit classification. Do not print tokens, response bodies, or song titles.

## Sources

- [Spotify authorization with PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow), consulted 2026-09-28: desktop apps can obtain user-scoped Web API tokens without storing a client secret.
- [Spotify redirect URIs](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri), consulted 2026-09-28: loopback IP literals may use a dynamic port when the registered URI omits the port.
- [Spotify rate limits](https://developer.spotify.com/documentation/web-api/concepts/rate-limits), consulted 2026-09-28: 429 and `Retry-After` behavior.
- [Spotify quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes), consulted 2026-09-28: Development Mode limits and `QUOTA_EXCEEDED` marker.
- [Bopify playback spike](2026-09-21-spike-findings.md), observed 2026-09-21: a Dashboard ID failed at playback `login5` while librespot's client ID worked.
