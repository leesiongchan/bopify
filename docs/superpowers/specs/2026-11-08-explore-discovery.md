# Explore discovery mechanics

Status: approved direction. The user approved the researched mechanics recommendation with “ok” on 2026-11-08. The earlier visual proposal is superseded; production appearance stays unchanged. Routine implementation details below follow that approval.

## Outcome

Explore opens a stable, varied recommendation feed, using current listening signals and established favourites. Selecting a song starts it on Soloist and adds a finite continuation from the displayed recommendations. Browsing alone never changes playback. Soloist remains the only audio engine; librespot supplies radio candidates through its metadata-only session.

## Discovery

- Collect recent tracks, short-term top tracks/artists, medium-term top tracks and liked-song seeds using existing grants. Deduplicate real track/artist URIs and interleave source groups; retain at most 12 seeds.
- Keep the existing station chooser as an anchor selection. The first anchor is automatic. An anchor feed combines up to three candidate radio sources per batch, preserving successes if another source fails.
- Preserve Spotify's order within candidate sources, combine sources fairly, remove duplicate/excluded URIs, demote recent tracks, and prefer no more than two songs by the same primary artist in a four-song window. Relax the artist preference when the remaining catalog is sparse. Do not claim never-heard status from limited history.
- Never silently replace discovery with saved tracks when radio is unavailable. Saved tracks are seeds; actual radio availability remains an external constraint.
- Publish an initial three-song window from the first healthy radio so a stalled source cannot hold the shelf empty. Append the fairly ranked remainder as the batch completes, preserving displayed order and selection. Near the end, append candidates from remaining seeds. Refresh after one hour on a subsequent hidden-to-visible reveal, not during an active browsing session. All cache invalidation and retries respect visibility, cancellation and account generation.
- Retain bounded automatic retries for transient radio failures; terminal missing-radio responses and authorization/throttle failures remain explicit.

## Playback

Extend `PlayRequest` with `followingTrackURIs: [SpotifyURI] = []`. Explore supplies the selected song and up to 20 following recommendations. Other callers retain their current behavior.

Use acknowledged Soloist local `play` to start the chosen song immediately. A temporary owned loopback WebSocket correlates its acknowledgement without interfering with polling. Require a matching post-request granular track event and fresh active snapshot before preparing continuation, supporting either event order. An owned background task then uses the existing matching-account/device correlation proof and documented Web API `uris` playback body to install the selected track plus followers on the explicitly verified Soloist device, preserving the observed playback position. Enforce bounds, track-only URIs, auth/socket/load/occurrence checks and cancellation before each mutation. Selection failures throw; background continuation failures publish a rejected-command event and diagnostic. Neither path claims an installed recommendation context after rejection.

Library consent requests the already-declared playback-control scopes together with library scopes; metadata validity still requires only read/library scopes. For an older grant, an intent-only callback may request missing playback permission after an explicit Explore song selection. Never invoke consent from launch or background warmup. Canceling the selection cancels its owned consent; a changed grant invalidates the old metadata/device proof before fresh verification. The selected song continues playing if authorization is declined.

Soloist's local API cannot replace previously auto-appended recommendations, so recommendation tracks must not be written into the manual queue. The replaceable Web API playback context prevents accumulated auto-queue duplicates; Bopify issues no manual-queue clear operations. This is finite continuation, not an unlimited radio guarantee. No undocumented offset/trackset command or separate OAuth flow is introduced. If a verified continuation context cannot be installed, leave the selected song playing and report the failure.

## Verification and limits

Use deterministic failing regression tests before implementation, followed by only the affected library, protocol, model and app checks. Verify a signed local test build and final diff. Preserve all earlier onboarding/regression work in this isolated worktree. Do not read saved credentials, send real playback commands, or replace the running app for verification. Authenticated candidate retrieval and queue behavior still require a live account test before claiming provider-wide reliability.

## Research

- Spotify top items and time ranges: https://developer.spotify.com/documentation/web-api/reference/get-users-top-artists-and-tracks
- Recommendation restrictions: https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api
- Soloist local protocol and acknowledgements: https://developer.spotify.com/documentation/soloist/reference/websocket-api
- Explicit device and URI-list playback: https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback
- Familiarity/discovery balance: https://research.atspotify.com/publications/algorithmic-balancing-of-familiarity-similarity-discovery-in-music-recommendations
