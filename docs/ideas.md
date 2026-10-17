# Bopify product ideas

Updated October 17, 2026. Direction: explore distinctive features and technical opportunities while preserving Bopify's compact native player experience.

These are candidates for exploration. Saved listening spaces are the leading product idea; the first useful experiment is restoring a saved context, track and timestamp across switches and app restarts.

The fresh creative shortlist emphasizes a small record crate, temporary song detours and alternate recordings. These explore listening rituals and musical discovery. Among smaller AI additions, turning independent music writing into a listening trail remains a product candidate, while a typed playback assistant is the smaller experiment.

## Existing capabilities

Bopify already supports local playback, queue selection, shuffle and repeat, radio through Explore, Recents, Liked Songs, a floating player and play-here handoff. The original PRD lists some of these as future work, so source code is the baseline for new ideas.

Playback works without a personal developer app. Favorites, Liked Songs and Spotify listening history require the user to supply a Spotify Web API Client ID. See [README](../README.md#library-setup).

## Initial shortlist

### Saved listening spaces

Keep named listening sessions such as Coding, Album exploration and Evening. Leave an album midway through, listen to something else, then return to the saved track and timestamp.

The existing [recovery snapshot](../Packages/BopifyCore/Sources/BopifyDomain/PlaybackRecovery.swift) captures playback identity, context, position, volume, shuffle and repeat. [PlayRequest](../Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift) accepts a context, starting track and position. These provide a credible foundation for persistent sessions, although recovery snapshots currently live only in memory.

Exact queue and shuffle-order restoration is a separate technical challenge. A context reload uses its current contents, and the public engine has no arbitrary queue-import command. Persistent sessions must not imply preservation of a frozen queue until that behavior is demonstrated.

**Validation:** save two album sessions, switch between them, restart Bopify and recover each saved position. Assess exact queue restoration separately.

**Tradeoff:** strong fit with a small player, with additional native work if the promise expands to exact queue preservation.

One Spotify Community proposal describes the same interrupted-session problem. It is an individual demand signal, not evidence of broad adoption. [Save and quickly resume the last 3 playback sessions](https://community.spotify.com/forum/en/discussion/7508249/save-and-quickly-resume-the-last-3-playback-sessions-playback-history).

### Listening inbox

Drop Spotify links onto the menu bar to collect music for later. Mark items unplayed, started or finished so recommendations become a manageable listening backlog.

The current [SpotifyURI parser](../Packages/BopifyCore/Sources/BopifyDomain/SpotifyURI.swift) accepts colon-delimited Spotify URIs rather than normal HTTPS share links. Supporting shared links is a useful foundation; the distinctive hypothesis is whether an inbox helps people work through albums they intended to hear.

**Validation:** capture several album links, start one, restart the app and recover its progress without manually creating a Spotify playlist.

**Tradeoff:** smaller initial experiment than complete session preservation, but adds collection management to a deliberately compact utility.

Spotify-link handling is established functionality in [Spotifast Getting Started](https://spotifast.rocks/getting-started/); the inbox workflow would need to earn its place independently.

### Native macOS music actions

Expose actions such as Resume listening space, Save current position and Play Spotify link through Shortcuts and Spotlight. Saved sessions would give the integration a purpose beyond ordinary transport controls.

**Validation:** invoke a saved session through Spotlight and compose a Shortcut that sets its volume and starts playback, without opening a full player window.

**Tradeoff:** useful platform integration that becomes more compelling after saved sessions or bookmarks exist.

Apple demonstrates app actions in Shortcuts and Spotlight in [Develop for Shortcuts and Spotlight with App Intents, WWDC25](https://developer.apple.com/videos/play/wwdc2025/260/).

Basic external controls already exist in the [Spotifast Raycast extension](https://www.raycast.com/Seigiard/spotifast), making Bopify-specific actions the more interesting part of this direction.

## AI opportunities

### AI DJ with blended transitions and spoken hosting

**Status:** set aside. Retained as a researched option.

Create a personal radio experience that blends song endings into the next track and adds occasional spoken hosting. The requested experience includes both overlapping music and an AI voice; a generated playlist alone would not satisfy it.

A candidate interaction is to choose a session theme and hosting frequency, then hear short introductions between groups of songs. Separate controls for transition intensity and host frequency could let the player stay quiet when desired. This is a product hypothesis, with scope still to be agreed.

**Audio architecture:** preload two playback lanes and schedule their gain changes through a native mixer. Generate the host script ahead of time, synthesize it into a separate voice lane and lower the music temporarily while speech plays. Keep text generation away from real-time audio rendering. Musical transition decisions and DSP need their own evaluation; begin with controlled crossfades before taking on beatmatching, pitch changes or stem separation.

Bopify's [Rust engine](../rust/crates/bopify-core/src/engine.rs) currently constructs one librespot player and sends its output to Rodio. The [public playback interface](../Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift) exposes no second deck, decoded-audio mixer, crossfade, speech renderer or ducking controls. Existing volume control alone cannot deliver this experience.

For a local-audio probe, Apple provides scheduled audio-file and buffer playback through [AVAudioPlayerNode](https://developer.apple.com/documentation/avfaudio/avaudioplayernode), and speech synthesis can deliver buffers for further processing through [AVSpeechSynthesizer write toBufferCallback](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write%28_%3Atobuffercallback%3A%29). These are candidate building blocks, not evidence that the complete transition system or desired voice quality is solved.

**Spotify boundary:** the public Developer Policy prohibits segueing, mixing or overlapping Spotify Content with other audio, including other Spotify Content. It also prohibits ingesting Spotify Content into AI models. Both song-to-song blending and music under a generated host encounter this boundary. [Spotify Developer Policy, section III](https://developer.spotify.com/policy).

Spotify supports catalog mixing in specific products including rekordbox, Serato and djay. That establishes that supported integrations exist, not that Bopify has the same access. [Spotify Premium Integrates With Leading DJ Software in 51 Markets, September 24, 2025](https://newsroom.spotify.com/2025-09-24/dj-software-integration-premium/).

Two paths need a decision before implementation:

- **Keep Spotify as the music source:** investigate permission and integration access that explicitly covers blending and spoken overlays. Ordinary playback through librespot does not establish that permission. This preserves the product's music source but leaves a significant external dependency.
- **Probe with local audio cleared for this use:** evaluate transitions and generated hosting on music and input metadata permitted for that processing. This offers a self-contained technical question, but local-file playback is a new subsystem outside Bopify's current Spotify scope.

**Validation if a local-audio probe is selected:** use two or three cleared tracks and one generated introduction. Listen for clicks, gaps, clipping, intrusive speech and awkward vocal overlap; verify that pause and skip stop pending speech and transitions. If generation is late or fails, music playback must continue without waiting. Measure timing and resource use before adding adaptive transition analysis.

**Tradeoff:** the highest-ambition audio direction in this list, with source access and mix quality as separate risks. First-party competition already includes Spotify's music-and-commentary DJ, so a Bopify version needs a clear independent benefit such as user control over hosting and transitions. [Your Personalized DJ Experience Is Expanding With 4 New Languages and More Markets, May 7, 2026](https://newsroom.spotify.com/2026-05-07/dj-expansion-4-new-languages/).

### Music writing into listening trails

Paste an independently published review or guide and turn its mentioned albums and tracks into a listening list. For example, a guide to Japanese jazz could become an ordered set of album cards with links back to the original writing. This extends the listening inbox into a bridge between reading about music and hearing it.

The model extracts names and their supporting passages from the supplied article. Ordinary application code searches Spotify, presents candidate matches and attaches confirmed results to the trail. Spotify results never return to the model. Preserve the source's order initially; an AI-generated history lesson or invented recommendation rationale would be unnecessary scope.

**Why AI helps:** identifying the artist, release and relationship between them in prose is more useful than extracting every link. Apple lists entity extraction and text understanding among its on-device model's capabilities. [Generating content and performing tasks with Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models).

**First experiment:** use short, user-supplied text from independent sources that permit the intended processing. Extract candidates with evidence, then let the user confirm catalog matches. A later browser-share flow could accept article URLs; arbitrary web fetching, paywalls and long-document processing are separate work. Treat article text as data, with no ability to issue playback commands.

**Validation:** hand-label the releases in ten short texts, measure correct extractions and false additions, and check ambiguous titles and unavailable releases. Every proposed item must have supporting source text; uncertain catalog matches require a choice. Compare time spent building the list with manual copying and searching.

**Dependencies and tradeoff:** Spotify catalog search needs library API setup and a new search client; it is not currently an exposed app capability. Catalog availability and title ambiguity can prevent exact matches. Search supports field filters. [Spotify Search reference](https://developer.spotify.com/documentation/web-api/reference/search).

New Development Mode apps have a maximum of ten results per search request. [February 2026 Web API Dev Mode Changes Migration Guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide).

A concert poster could later supply an artist list through image extraction, using the same catalog-matching boundary. Apple's system-model image prompting is a macOS 27 direction, beyond Bopify's macOS 26 baseline. Use independently supplied posters, never Spotify screenshots or album artwork as model inputs. [Build AI-powered scripts with the fm CLI and Python SDK, WWDC26](https://developer.apple.com/videos/play/wwdc2026/334/).

### Typed playback assistant

Accept requests such as "resume Coding at 25 percent volume and pause in 40 minutes" or "go back 30 seconds." Show an editable action preview, then execute it through ordinary playback controls. Saved-space commands depend on listening spaces; relative seeking offers a smaller first experiment.

The model sees the user's command, supported action names and user-authored space labels paired with opaque local identifiers. Application code reads the current position, calculates relative seeks, validates volume and timer limits, and resolves identifiers after generation. Do not send track metadata, playback history or Spotify responses to the model.

**Why AI helps:** it can combine familiar actions from varied phrasing. Apple guided generation can constrain output to defined Swift structures and enumerations. Structural validity does not establish that a command was understood correctly. [Generating Swift data structures with guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation).

The existing [PlayerModel command path](../Packages/BopifyCore/Sources/BopifyPlayback/PlayerModel.swift) serializes playback operations and checks readiness, ownership and engine epoch. A language interpreter should submit known actions through that path. It should have no shell, arbitrary network or unrestricted tool access.

**Validation:** compare interpretation with expected actions on a small set of commands, paraphrases, negations and unsupported requests. Include "do not resume," missing space names and ambiguous time expressions. Measure latency and correction effort against a small deterministic command palette; retain AI only if the added phrasing flexibility is useful.

**Tradeoff:** the smallest AI candidate, but basic transport commands may be faster with shortcuts. Compound requests and personally named spaces provide the stronger reason to use it. Keep this typed: Spotify explicitly prohibits voice-control applications. [Spotify Developer Policy, section III, effective May 15, 2025](https://developer.spotify.com/policy).

### Find bookmarked moments by meaning

Mark a moment and write a private note such as "the long guitar buildup" or "rainy train ride." Later, find it with a phrase such as "that slow guitar entrance" and return to the saved timestamp. This combines precise playback bookmarks with recall based on the user's own words.

Store user-authored notes separately from playback references. The model compares a query with those notes and returns opaque bookmark identifiers. Application code then loads the corresponding Spotify identity and position. Model input excludes automatically imported titles, artists, artwork, listening history and Spotify identifiers; pasted Spotify content is not an eligible note source.

**First experiment:** manual notes and timestamp bookmarks, followed by semantic retrieval over a small note collection. The existing [PlayRequest](../Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift) provides a track-and-position load primitive. The model should be able to return no match.

**Validation:** create a hand-labeled set of notes and queries, compare first-result relevance with keyword search, and verify that weak matches do not trigger playback. Include similarly worded notes and requests with no saved counterpart.

**Tradeoff:** distinctive for people who annotate musical moments, but depends on a note-taking habit. Validate the manual bookmark workflow before adding semantic search. No audio analysis or embedding of Spotify content is part of this proposal.

## Further opportunities without AI

### Listening sessions with a deliberate ending

Offer "pause in 25 minutes" and "finish this song, then stop." These fit a focused player and give saved spaces useful session boundaries without requiring a language model.

Timed pause can use existing playback commands. Accurate stop-at-end behavior needs a native guard before automatic advancement; reacting only to Swift's end-of-track event could briefly start the next track. Sleep and wake handling must define whether elapsed time continues and must never unexpectedly resume music.

**Validation:** exercise timed pause across sleep and wake, remote-device takeover and app restart. For stop-at-end, verify that no audio from the next song begins. The [connection monitor](../Bopify/Bopify/PlaybackConnectionMonitor.swift) already observes sleep and wake for recovery; the timer and ending controls would be new behavior.

**Tradeoff:** modest visual scope with meaningful native timing work. Useful on its own and as a foundation for compound typed commands.

### Listening postcards

Share a normal Spotify link with a personal note and an optional instruction such as "listen from 2:17." A saved moment becomes a recommendation with a reason attached, without a social feed or a hosted service.

**Validation:** copy a postcard and confirm that its Spotify link opens normally in another app and the timestamp remains readable as text. Do not assume Spotify supports timestamp deep links. Bopify-specific bookmark links would need a separate design.

**Tradeoff:** a small extension to manual bookmarks, with uncertain demand. Start with text and links; artwork generation or image cards add little to the first experiment. Existing [Track](../Packages/BopifyCore/Sources/BopifyDomain/Track.swift) and playback position provide the necessary local inputs.

### Safe behavior when headphones disconnect

Let users opt into pausing when a selected personal listening device disappears, avoiding an unexpected switch to speakers. Require a deliberate resume after reconnection initially.

This needs investigation at the audio boundary. The [Rust engine](../rust/crates/bopify-core/src/engine.rs) uses the default Rodio output and exposes no output-selection or device-rebinding interface. macOS exposes the default output device through Core Audio, but detecting changes and preventing an audible fallback need hardware validation. [AudioHardwareSystem defaultOutputDevice](https://developer.apple.com/documentation/coreaudio/audiohardwaresystem/defaultoutputdevice).

**Validation:** test Bluetooth loss, wired unplugging and manual default-device changes. Measure whether any sound reaches speakers before pausing. If a pause arrives after fallback, describe the feature as best-effort until the native path can enforce a stronger guarantee.

**Tradeoff:** useful daily behavior rather than a distinctive headline feature; native routing complexity makes it a separate probe.

## Listening rituals and musical discovery

### Personal record crate

Keep a deliberately small shelf of pinned albums or playlist contexts. Press Pick one and Bopify selects a record from that shelf, reveals it and starts playback. Named crates such as Sunday morning or Loud guitars make choosing music a single decision. The creative hypothesis is that a small collection can feel more inviting than another large library.

This differs from the listening inbox: crates are reusable favorites, with no unread status or completion tracking. It also differs from saved spaces: choosing a record starts that context rather than restoring a stored listening position.

**First experiment:** pin album or playlist contexts explicitly, persist a small local collection and select one item randomly on request. Existing [PlayRequest](../Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift) can load these contexts. Pinning the album behind an arbitrary track needs more metadata: the current [Track model](../Packages/BopifyCore/Sources/BopifyDomain/Track.swift) has an album title, not an album URI.

**Validation:** build a small crate, restart the app and play a selected context. Compare the number of actions and perceived choice effort with opening Explore or browsing a playlist. No recommendation model or listening-history analysis is required.

**Tradeoff:** modest new state and a compact interaction, with enough overlap with favorites that the one-decision experience must provide the value.

### Borrow one song

While listening to an album, open a track as a temporary detour. A return action takes the listener back to the album and timestamp they left. The intended eventual flow is to return automatically after that song ends.

This is a small interaction built on the saved-position foundation, rather than a separate collection of named sessions. The first probe can use an explicit Return button. Automatic return requires native completion handling before Spotify advances to another song; it cannot rely solely on a delayed Swift end-of-track event.

The existing [recovery snapshot](../Packages/BopifyCore/Sources/BopifyDomain/PlaybackRecovery.swift) and [load request](../Packages/BopifyCore/Sources/BopifyDomain/PlaybackEngine.swift) provide context, track and position primitives. They do not preserve a frozen shuffle queue.

**Validation:** take a detour from the middle of an album, return and recover the saved position. Define cancellation when the listener deliberately starts a different session, signs out or transfers playback. Evaluate automatic return separately.

**Tradeoff:** useful everyday behavior with little interface, but automatic continuation is more involved than saving a bookmark.

### Other takes of this song

Open a compact shelf of other recordings of the current composition: studio, live, acoustic or cover versions when the data identifies them. Play one sequentially, with a return point to the original listening context. This could make a familiar track a doorway into a different performance.

MusicBrainz distinguishes a composition from its recordings and models links between them. Those relationships are a candidate source for verified alternatives; matching only song-title strings would confuse unrelated songs. [MusicBrainz Work](https://musicbrainz.org/doc/Work).

**First experiment:** use a small manually verified set of recording-to-work matches, show available linked recordings and confirm the Spotify catalog match for each. Treat release editions and remasters separately from genuinely different performances. Missing work links or ambiguous catalog matches should produce an incomplete shelf rather than invented alternatives.

**Validation:** check familiar standards, a studio/live pair, a cover and unrelated songs with the same title. Measure correct relationships and playable catalog matches before building general discovery.

**Tradeoff:** the strongest new music-discovery hypothesis, with a substantial metadata-matching dependency. MusicBrainz supports recording, work and relationship queries, but Bopify has no client or cross-catalog identity layer yet. [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API).

### Follow the people behind a recording

Turn a credit into a listening trail: choose a bassist, producer or composer, inspect another credited recording and decide what to hear next. Keep the first view to a few useful credits with an explicit source, rather than a large graph.

MusicBrainz relationships represent connections such as production credits, band membership and samples; recording-level relationships can identify personnel. [MusicBrainz Relationships](https://musicbrainz.org/doc/Relationships).

**First experiment:** a user-invoked external credits lookup or a manually verified small collection. Integrated trails require a matching layer between the playing recording, external credits and playable Spotify items. The current [Track model](../Packages/BopifyCore/Sources/BopifyDomain/Track.swift) supplies names and duration, not personnel or recording identifiers.

**Validation:** verify credits against a small set of recordings and make ambiguous editions visible. Check whether listeners actually follow a credit to another recording, rather than simply opening and dismissing the panel.

**Tradeoff:** a richer musical rabbit hole, with data coverage and matching costs similar to Other takes. These are alternative first uses of a shared metadata subsystem, not two features to build together by default.

### Hold to peek

Hold a configurable shortcut to reveal a compact Now Playing card over the current app; release it to dismiss. The user can check the track and progress without changing keyboard focus or leaving their work.

The current [StatusPanel](../Bopify/Bopify/MenuBar/StatusPanel.swift) already supports nonactivating presentation, but normal opening [makes the panel key](../Bopify/Bopify/MenuBar/StatusItemController.swift). A peek needs a separate show-and-hide path and global key-down/key-up handling. No global hotkey registration currently exists.

**Validation:** hold and release the shortcut while typing in another app and while using a fullscreen app. Verify that focus and typed input stay with the original app and that the overlay dismisses when focus or key state is lost. Test modifier conflicts and accessibility without adding playback gestures to the first probe.

**Tradeoff:** the smallest new interaction candidate, useful as polish rather than a major discovery feature. Sleeve already offers a shortcut-driven Now Playing HUD; Bopify's hypothesis is the specific hold-and-release interaction. [What is new in Sleeve 2](https://replay.software/updates/whats-new-in-sleeve-2).

## Priorities for further exploration

These priorities reflect product fit and dependency scope, not measured user demand or implementation estimates.

| Candidate | Reason to explore | Main uncertainty | Suggested order |
| --- | --- | --- | --- |
| Personal record crate | Makes choosing from a small collection one decision | Added value over favorites and Explore | Strongest fresh compact-player candidate |
| Borrow one song | Makes interruptions reversible | Automatic return before native advancement | Small probe using saved-position primitives |
| Other takes | Reveals alternate performances of a composition | Recording and catalog identity matching | Strongest fresh discovery candidate |
| Follow recording credits | Makes discovery follow musicians and producers | Credit coverage and recording identity | Alternative metadata probe to Other takes |
| Hold to peek | Checks Now Playing without taking keyboard focus | Reliable global hold-and-release behavior | Small interaction probe |
| Saved listening spaces | Strong fit with compact playback and existing recovery state | Reliable resume across context changes | First product probe |
| Typed playback assistant | Small AI task with a defined action set | Added value over shortcuts and deterministic parsing | First AI feasibility probe |
| Music writing into listening trails | Turns independent discovery into playable collections | Extraction quality, catalog matching and setup friction | Strongest new AI product bet |
| Listening inbox | Useful foundation for trails and album progress | Whether users want another collection | Validate alongside trails |
| Bookmarked moments with semantic recall | Combines precise position with personal memory | Whether people write enough useful notes | Manual bookmarks before AI |
| Deliberate endings | Makes listening sessions controllable | Native stop-before-advance behavior | Supporting playback work |
| Native macOS music actions | Makes distinctive features available systemwide | Value depends on the actions being exposed | After a core workflow exists |
| Listening postcards | Makes sharing more personal | Frequency of use | Small follow-up to bookmarks |
| Headphone disconnect behavior | Practical daily improvement | Native fallback timing | Independent hardware probe |

## Research constraints

Generic song annotations have less room to differentiate after Spotify introduced Playlist Notes on August 17, 2026. [Spotify Gets More Personal With Playlist Notes](https://newsroom.spotify.com/2026-08-17/playlist-notes-editors-listeners/).

New Web API integrations cannot rely on Recommendations, Audio Features or Audio Analysis. This limits proposals that assume Spotify supplies mood, energy or similarity data. [Introducing some changes to our Web API, November 27, 2024](https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api/).

Generic prompt-to-playlist creation also faces an existing first-party offering. Spotify described personalized Prompted Playlist, including natural-language requests and scheduled refreshes, on February 23, 2026. [3 Prompts to Try Using Prompted Playlist](https://newsroom.spotify.com/2026-02-23/prompted-playlist-prompts-to-try/).

### AI data boundaries

Spotify's Developer Terms prohibit ingesting Spotify Content into AI or machine-learning models as well as training on it. Their definition includes metadata, so an on-device model is not an exception. Exclude Spotify audio, lyrics, artwork, catalog responses and playlist data from prompts and embeddings. [Spotify Developer Terms, sections II and IV, version 10 effective May 15, 2025](https://developer.spotify.com/terms).

The proposed separation between independent inputs and ordinary catalog matching is an engineering direction to investigate, not a determination that Spotify has approved these integrations. Independently sourced material needs its own processing rights and attribution. Recheck the applicable terms before selecting an AI feature for implementation.

### Model choice and evaluation

Apple's on-device Foundation Models are the first candidate for short extraction, classification and command-interpretation tasks. They fit a native app and can work without sending prompts to a server. Availability still depends on Apple Intelligence support, settings, region and model readiness; ordinary playback must remain usable when the model is unavailable. [Generating content and performing tasks with Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models).

A hosted model offers another route for tasks that exceed the local model's capabilities, but brings network dependence, provider costs and data disclosure. The macOS 26 text workflow is the baseline for investigation; newer framework capabilities must be checked individually rather than assumed to support that baseline. [Foundation Models framework](https://developer.apple.com/foundation-models-framework/).

Keep inference on demand and measure latency, resource use and task quality. Guided generation constrains response structure; application code must still validate meaning and permissions. For each AI candidate, compare it with the non-AI workflow before keeping the added complexity. Apple recommends starting prompt evaluation with a critical quality criterion and a small set of scenarios. [Evaluating prompts to measure performance and improve model responses](https://developer.apple.com/documentation/foundationmodels/evaluating-prompts-to-measure-performance-and-improve-model-responses).

Use Instruments to measure model loading and response time before describing a feature as lightweight. [Analyzing the runtime performance of your Foundation Models app](https://developer.apple.com/documentation/foundationmodels/analyzing-the-runtime-performance-of-your-foundation-models-app).
