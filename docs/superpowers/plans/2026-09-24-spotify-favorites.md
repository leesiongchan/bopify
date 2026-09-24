# Spotify Favorites Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the redesigned player's heart reflect and change the current track's real Spotify-library state without interrupting local playback.

**Architecture:** Add a narrow Foundation-based library client and a persistent main-actor favorite model. Extend the existing PKCE service for explicit incremental consent and scope-aware access, preserving the streaming token and engine on failure. Keep library errors separate from playback phase.

**Tech Stack:** Existing Swift 6/Swift Testing, Foundation URLSession, Observation, Keychain/PKCE auth; one internal `BopifyLibrary` package target, no new third-party package.

**Spec:** [Approved mini-player design](../specs/2026-09-24-liquid-glass-mini-player-design.md); integrated by the [main implementation plan](2026-09-24-liquid-glass-mini-player.md).

**Status:** Proposed execution plan. Request/response shapes were checked against official documentation on 2026-09-24. Compatibility of the current first-party streaming client with these endpoints has not been verified live.

## Global Constraints

- “Favorite means Spotify saved-track state, consistent with `PRD.md`, not a local-only heart toggle.”
- “Permission or network failure produces a concise non-blocking message, not a silently successful heart.”
- “Keep library saved-state operations separate from playback.”
- Preserve macOS 14 minimum, Swift 6 strict concurrency, existing local audio path, and existing serialized engine lifecycle.
- Never expose tokens in logs, documents, screenshots, commands, or tests. Network fixtures use fake credentials.
- No automatic consent, unrelated scopes, registered-app creation, second account flow, or credentials replacement merely to bypass a 403.
- This plan is required for full mini-player completion. A failure can leave an honest unavailable state while independent UI work continues, but cannot be reported as finished favorites.

## Review Focus

1. A response for track A must not change the heart after the player confirms track B (Task 3).
2. Concurrent refresh and sign-out must not resurrect credentials or issue library calls after sign-out (Tasks 1–3).
3. Denied/insufficient incremental consent must preserve the working streaming session (Task 1).
4. Malformed contains responses, 403 and 429 must not silently become “not saved” or trigger consent/retry loops (Task 2).
5. A timed-out mutation may have succeeded remotely; reconciliation must prevent a false confirmed heart while leaving playback usable (Task 3).

## Provider contract and the remaining feasibility check

For one current track, use `URLComponents` and a single `uris` query value:

| Action | Request | Verified success response |
| --- | --- | --- |
| Read | `GET https://api.spotify.com/v1/me/library/contains?uris=spotify:track:…` | 200, JSON array of one Boolean |
| Save | `PUT https://api.spotify.com/v1/me/library?uris=spotify:track:…` | 200, empty body |
| Remove | `DELETE https://api.spotify.com/v1/me/library?uris=spotify:track:…` | 200, empty body |

The required `uris` parameter belongs in the **query for all three requests**, not a mutation JSON body. Restrict this client to `.track` inputs; unsupported content receives an unavailable heart.

Start with `user-library-read` and `user-library-modify`, matching the track-only PRD. Current Spotify documentation/OpenAPI lists additional follow/playlist scopes for the unified multi-resource endpoints without explaining resource-conditional scope behavior. Therefore the two scopes are a minimal candidate, not a proven sufficient grant for Bopify's client. Do not broaden to follow or playlist permissions automatically.

After this plan's boundary tests, use explicit in-app consent and verify contains against the real account. A user-driven save/remove round trip must confirm the backend state and restore the track's initial saved status. A 403 can also reflect client/account restrictions; it is not proof that another scope will fix the problem. If the first-party client is rejected, report the exact sanitized status/grants. The alternative is a separate registered-app PKCE client and separate token store with account matching; that changes the approved auth design and needs its own concrete review. Do not implement that fallback silently.

## File map

| Path | Responsibility |
| --- | --- |
| `Packages/BopifyCore/Sources/BopifyAuth/{SpotifyAuthService,TokenClient}.swift` | Scope-aware token access, incremental consent, safe single refresh. |
| Existing `Packages/BopifyCore/Tests/AuthTests/{SpotifyAuthServiceTests,TokenClientTests}.swift` | Auth, grant, refresh and cancellation regressions. |
| **new** `Packages/BopifyCore/Sources/BopifyDomain/LibraryService.swift` | Small service/error contract. |
| **new** `Packages/BopifyCore/Sources/BopifyLibrary/SpotifyLibraryClient.swift` | Exact HTTP boundary. |
| **new** `Packages/BopifyCore/Sources/BopifyLibrary/FavoriteModel.swift` | Current-track saved-state lifecycle and pending mutation. |
| `Packages/BopifyCore/Package.swift`, `Bopify/Bopify.xcodeproj/project.pbxproj` | Internal library target/product and app linkage. |
| **new** `Packages/BopifyCore/Tests/LibraryTests/{SpotifyLibraryClientTests,FavoriteModelTests}.swift` | Request/response and model race tests. |
| `Bopify/Bopify/AppEnvironment.swift`, `Views/MiniPlayerView.swift`, `Localizable.xcstrings`; **new** `Views/FavoriteButton.swift` | Lifetime, track observation, accessible action, localized non-blocking notices. |

The extra internal target is justified by its independent HTTP/service/model tests and separate error lifecycle. It depends on BopifyDomain; authentication is injected as a closure, so it does not depend on Rust or implement another token store.

## Task 1: Preserve streaming while adding scope-aware library authorization

**Interfaces:** Add to SpotifyAuthService:

```swift
public func validAccessToken(requiredScopes: Set<String>) async throws -> String
public func authorizeAdditionalScopes(_ additionalScopes: Set<String>) async throws -> TokenSet
```

Keep existing `validAccessToken()` and `signIn()` callers working. Create the domain file with the complete `LibraryError` and `LibraryService` declarations shown in Task 2 before using them here. The scope-aware getter never opens a browser; only the explicit authorization method may do so.

- [ ] **Write failing refresh-scope and consent-preservation tests.** Extend TokenClient's refresh signature to `refresh(refreshToken: String, grantedScopes: Set<String> = [])`; add tests before implementation:

```swift
@Test func omittedRefreshScopePreservesTheExistingGrant() async throws {
    StubProtocol.handler = { _ in
        (200, Data(#"{"access_token":"NEW_FAKE","expires_in":3600}"#.utf8))
    }
    let tokens = try await makeClient().refresh(
        refreshToken: "OLD_FAKE", grantedScopes: ["streaming", "user-library-read"])
    #expect(tokens.grantedScopes == ["streaming", "user-library-read"])
}
```

Also return an explicit `scope: "streaming"` and assert it replaces, rather than unions with, old grants. In SpotifyAuthServiceTests, use the existing fake callback/store pattern: declined consent and an inadequate returned scope set must leave the old TokenSet unchanged. Two suspended token consumers must produce one refresh request; sign-out during refresh must prevent the save. Run AuthTests to observe the expected failures.

- [ ] **Implement scope checks and shared refresh.** The scope-aware getter validates grants before returning a token; after refresh validate the refreshed grants again. Add a private pending refresh task tagged with the auth generation. Concurrent callers await the same task; sign-out cancels it and invalidates its generation. Retain the existing store-write generation check. Refresh omission retains old grants; explicit response grants stay authoritative. For initial code exchange, preserve the current conservative behavior if `scope` is absent: do not claim library authorization without evidence.

```swift
let required: Set<String> = ["streaming"].union(additionalScopes)
    .union(currentTokens?.grantedScopes ?? [])
// Build the authorization request from required; keep current tokens intact
// through browser/callback/exchange and validate the result before saving.
guard required.isSubset(of: candidate.grantedScopes) else {
    throw LibraryError.authorizationRequired
}
```

`currentTokens` and `candidate` above are local TokenSet values in `authorizeAdditionalScopes`. Reuse existing PKCE/callback/state verification instead of copying a second flow. Preserve currentTokens and the running engine when the user cancels, the callback fails, grants are insufficient, or exchange fails. Generation invalidation by real sign-out still wins. Saving a successful upgraded token must not rebuild an already-running audio engine.

- [ ] **Verify and commit.** Run the complete AuthTests suite, including overlapping refresh and generation tests. Use sanitized event categories for logging. Suggested subject: `Add on-demand library authorization without replacing playback`.

## Task 2: Implement the narrow library HTTP boundary

**Interfaces:** Consume the following domain contract introduced with Task 1; implement `SpotifyLibraryClient` with injected `URLSession` and `@Sendable (Set<String>) async throws -> String` token provider:

```swift
public enum LibraryError: Error, Equatable, Sendable {
    case authorizationRequired, forbidden, invalidResponse, unavailable
    case rateLimited(retryAfterSeconds: Int?)
}
public protocol LibraryService: Sendable {
    func savedState(for uri: SpotifyURI) async throws -> Bool
    func save(_ uri: SpotifyURI) async throws
    func remove(_ uri: SpotifyURI) async throws
}
```

- [ ] **Add the internal target and a request-recording test fixture.** BopifyLibrary depends on BopifyDomain; LibraryTests depends on BopifyLibrary. Use an ephemeral URLSession with a dedicated URLProtocol stub and a serialized test suite, following AuthTests' existing approach. Its test-local recorder holds request, status, headers and data; access shared mutable fixture state under a lock. Do not reuse the auth module's global handler across parallel suites.

- [ ] **Write request/response tests before implementing methods.** Assert host, path, query, verb, fake bearer header and empty body. The following is the concrete request oracle used inside the stub:

```swift
#expect(request.httpMethod == "PUT")
#expect(request.url?.host == "api.spotify.com")
#expect(request.url?.path == "/v1/me/library")
let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
#expect(parts?.queryItems == [URLQueryItem(name: "uris", value: "spotify:track:abc")])
#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TEST_TOKEN")
#expect(request.httpBody == nil && request.httpBodyStream == nil)
```

Use `[true]`, `[false]`, `[]`, `[true,false]`, malformed JSON and non-Boolean arrays for reads. Save/remove must accept empty 200. Add 400/401/403/429/500 and transport/cancellation cases. Missing scopes must fail before a request is emitted. Run `swift test --package-path Packages/BopifyCore --scratch-path /private/tmp/bopify-mini-player-tests --filter SpotifyLibraryClientTests` and observe red.

- [ ] **Implement three operations through one private request builder.** Use exact host and URLComponents, choose read/write scope at the boundary, and never accept a provider-supplied URL for authenticated calls. New private `request(method: String, uri: SpotifyURI, contains: Bool) async throws -> Data` performs the one request and validates HTTP status. Reject redirects to another host rather than allowing a bearer credential to follow them; use an internal URLSession redirect delegate or equivalent same-host policy. No generic Spotify API framework.

```swift
var components = URLComponents(string: "https://api.spotify.com/v1/me/library")!
if contains { components.path += "/contains" }
components.queryItems = [URLQueryItem(name: "uris", value: uri.rawValue)]
var request = URLRequest(url: components.url!)
request.httpMethod = method
request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
// Intentionally no mutation body.
```

`token` comes from the injected provider for the operation's required scopes. The client has a bounded URLSession timeout. Decode contains as `[Bool]`, require count one, and return that value. Map 401 to authorizationRequired, 403 to forbidden, 429 to rateLimited with a nonnegative parsed Retry-After seconds value, malformed/unexpected response to invalidResponse, and connection/5xx failure to unavailable. Preserve CancellationError. Use a fresh token through normal auth refresh before requests; do not add automatic 401 retries or consent loops in this first client.

- [ ] **Verify and commit.** Test a cross-host redirect sends no authenticated follow-up, unsupported URI kinds send no request, and all status mappings remain library-only errors. Run LibraryTests and existing AuthTests. Suggested subject: `Use Spotify unified library endpoints for saved tracks`.

## Task 3: Add reconciled favorite state and the real heart action

**Interfaces:** New `@MainActor @Observable public final class FavoriteModel` receives `any LibraryService`. Expose `uri: SpotifyURI?`, `saved: Bool?`, `isPending: Bool`, `error: LibraryError?` as private(set), and `select(_ uri: SpotifyURI?) async`, `toggle() async`, `clear()`.

- [ ] **Write tests using a controlled service double.** A test-local actor implements LibraryService and stores read/mutation continuations keyed by URI. Tests explicitly resume them in the required order. Pin A→B→late-A, sign-out while loading, rollback on forbidden save, reconciliation after timeout, and repeated toggle while pending. A minimal non-racy service case:

```swift
private struct DeniedLibrary: LibraryService {
    func savedState(for uri: SpotifyURI) async throws -> Bool { false }
    func save(_ uri: SpotifyURI) async throws { throw LibraryError.forbidden }
    func remove(_ uri: SpotifyURI) async throws { throw LibraryError.forbidden }
}
@MainActor @Test func failedSaveRestoresConfirmedState() async {
    let model = FavoriteModel(service: DeniedLibrary())
    await model.select(SpotifyURI("spotify:track:abc")!)
    await model.toggle()
    #expect(model.saved == false)
    #expect(model.error == .forbidden)
    #expect(!model.isPending)
}
```

- [ ] **Implement track-scoped state.** `select` increments a generation, clears prior state, and publishes a response only when generation and URI still match. `toggle` requires a known saved value and no pending operation, captures URI/generation/confirmed state, then optimistically changes the display. On success, read contains to reconcile. On a definite rejection, restore confirmed state and expose the error. On network timeout or other ambiguous outcome, attempt a contains reconciliation; if that also fails, set saved to unknown rather than claiming either outcome. Sign-out clears/increments generation, and stale completions cannot restore it.

```swift
let requestGeneration = generation
let requestURI = uri
// After each await, before publishing any state:
guard generation == requestGeneration, uri == requestURI else { return }
```

Keep mutation serialization per current intent. Store and cancel in-flight model tasks on `clear()`; check cancellation and generation before starting any follow-up reconciliation request. A request already delivered to Spotify can still finish remotely after cancellation, but its result never changes a new track's heart or restores signed-out state. No provider calls are made from view body evaluation.

- [ ] **Wire app lifetime and consent explicitly.** Link BopifyLibrary to the app target. AppEnvironment creates one library client/model using the existing auth service's scope-aware closure; sign-out calls clear. MiniPlayerView observes only confirmed current track changes through `.task(id:)` and loads the favorite model; it is not recreated during mode changes. FavoriteButton reads saved/pending/error, exposes an accessible toggle value and help, and dispatches model.toggle. Unknown authorization presents a working “Enable Spotify favorites” action that invokes authorizeAdditionalScopes; denied consent leaves audio playing. Other unknown/error states offer Retry. Re-run contains when returning to the player after foreground changes; do not assume an external Spotify client cannot alter saved state.

- [ ] **Run native and live verification.** Check pending/failed/unknown states across expanded, queue and compact transitions; the compact layout may move Favorite to its context menu. Complete the real narrow-scope contains and user-driven save/remove round trip described above. Record only status, whether required grants were present, final saved-state agreement, and uninterrupted playback. If authorization fails, report the remaining constraint; do not add unrelated scopes or a second auth client automatically.
- [ ] **Run all affected tests and app build; commit** with subject `Reconcile the current track favorite with Spotify library state`.

## Self-review coverage

Task 1 owns consent/refresh/sign-out races. Task 2 owns HTTP shape, grants, redirects and status errors. Task 3 owns selected-track identity, mutation ambiguity, UI state, and live saved-state proof. The main plan owns visual composition and the rest of playback; this plan never issues play/pause/seek or remote Player API calls.

## Primary references checked 2026-09-24

- [Spotify — Check User's Saved Items](https://developer.spotify.com/documentation/web-api/reference/check-library-contains): contains query and Boolean-array response.
- [Spotify — Save Items to Library](https://developer.spotify.com/documentation/web-api/reference/save-library-items): PUT query and empty success response.
- [Spotify — Remove Items from Library](https://developer.spotify.com/documentation/web-api/reference/remove-library-items): DELETE query and empty success response.
- [Spotify — OpenAPI schema](https://developer.spotify.com/reference/web-api/open-api-schema.yaml): scope lists for the unified resource endpoints; resource-specific sufficiency remains a live check.
- [Spotify — PKCE flow](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow): documented registered-app authorization alternative, not proof of first-party client compatibility.
- [Spotify — Quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes): account/client access restrictions can also cause forbidden responses.
