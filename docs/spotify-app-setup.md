# Spotify application setup

## The registered app is not used for playback

The app below was registered on the Spotify Developer Dashboard, but a
Developer Dashboard client ID cannot reach the streaming endpoint: three
spike runs (`docs/superpowers/specs/2026-09-21-spike-findings.md`) showed
`login5` rejecting it with a raw HTTP 400 even when the token and the
session both used it consistently. It is kept on record only in case a
future version needs Web API calls, which this slice does not.

- Client ID: `25bbd3bacca4412b80f17b892072af71`
- Redirect URI registered: `http://127.0.0.1/callback` (no port — loopback
  literals may use a dynamically assigned port)
- Scopes requested: `streaming`
- Quota: Development Mode. Hard ceiling of 5 allowlisted users; the owner
  must be added explicitly under Settings -> User Management.

## The configuration that actually works

- Client ID: librespot's first-party ID, `65b708073fc0480ea92a077233ca87bd`
  (`librespotClientID` in `SpotifyAuthService.swift`)
- Redirect URI: `http://127.0.0.1:<port>/login`
- Scope: `streaming`
- The account must have Spotify Premium. librespot is Premium-only.
