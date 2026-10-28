# Bopify product page: Sleeve Notes

The approved direction is a collectible record sleeve: warm ivory, ink black,
mint glass and orange drawn from the existing app icon. Oversized editorial
type and a playful spinning record introduce the product; the existing app
screenshot provides an accurate view of what users download.

The alternative considered was After Hours, a dark listening-room presentation.
Sleeve Notes was recommended for its warmth and connection to the app icon;
the user approved that recommendation with “ok”.

Build one responsive page with a record-and-sleeve hero, real app showcase,
numbered feature tracklist, download links, and setup instructions. Preserve
macOS 26+, Apple silicon and Spotify Premium requirements, Spotify developer
app setup, and the current ad-hoc signing caveat. Do not imply official Spotify
affiliation, audio playback on the website, or features absent from the app.

Use static HTML/CSS under `site/`, with no JavaScript, dependencies,
analytics or remote font requests. Use a GitHub Pages Actions workflow with
official actions pinned to verified releases. Relative asset URLs must work
under the `/bopify/` project path. The record spins continuously using CSS,
except when reduced motion is enabled. Feature icons share consistent SVG
dimensions and stroke weights.

Research: [OB–4](https://teenage.engineering/products/ob-4),
[Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/),
[GitHub Pages workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages),
[reduced motion](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/At-rules/@media/prefers-reduced-motion).

Verify desktop/mobile screenshots, overflow, keyboard interaction, reduced
motion, no-JavaScript content, asset/link integrity and workflow syntax.
Publication must be reported separately from local implementation.
