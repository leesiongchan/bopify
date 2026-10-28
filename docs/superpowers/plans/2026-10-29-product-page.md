# Bopify Product Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the approved Sleeve Notes product page and GitHub Pages deployment configuration.

**Architecture:** A standalone, dependency-free static page in `site/`. Existing product imagery is copied into its assets directory. A dedicated GitHub Actions workflow publishes only the site.

**Tech Stack:** HTML, CSS, GitHub Pages.

**Spec:** `docs/superpowers/specs/2026-10-29-product-page-design.md`

## Global Constraints

- macOS 26+, Apple silicon and Spotify Premium requirements are visible.
- Preserve Spotify developer setup and ad-hoc signing caveat.
- No dependencies, analytics, remote fonts or modifications to app code.
- Relative paths work under `/bopify/`; main content works without JavaScript.
- Honor reduced motion and keyboard access.

## Review Focus

- Narrow screens and enlarged text must not clip content.
- Reduced-motion users receive no automatic spinning.
- No JavaScript must leave navigation and downloads usable.
- Downloads must reach the latest release without a stale version URL.
- Deployment must include assets and exclude app/repository source.

### Task 1: Build the page

**Files:** Create `site/index.html`, `site/styles.css`, `site/assets/player.png`, `site/assets/icon.png`, `site/assets/favicon.svg`.

**Interfaces:** CSS animates `.record-face` inside the clipped `#record` wrapper. Assets use relative paths.

- [x] Serve the repository locally and capture the missing page as the baseline.
- [x] Build semantic page sections, accurate copy, record artwork and responsive styles.
- [x] Add continuous CSS record rotation that respects reduced motion.
- [x] Verify desktop/mobile screenshots, overflow, keyboard, reduced motion and no-JavaScript behavior using agent-browser.

### Task 2: Configure GitHub Pages

**Files:** Create `.github/workflows/pages.yml`, `site/README.md`.

**Interfaces:** Workflow uploads `site/`; push paths include the workflow and `site/**`.

- [x] Use verified official action release commits; configure Pages, upload site artifact and deploy with scoped permissions.
- [x] Document local preview and deployment requirements.
- [x] Verify HTML/assets and workflow syntax; run an accessibility audit.
- [x] Review the whole diff and report the actual publication state.

## Verification results

- Static site packaging checked for asset/link references, unique IDs, fragment targets and the deployment file set.
- `, actionlint .github/workflows/pages.yml` and `git diff --check` pass.
- Desktop 1440px and mobile 390px screenshots reviewed; no horizontal overflow at 390px or 320px.
- Browser-tested automatic rotation, motion preference changes, and native disclosure keyboard behavior. The final page requires no JavaScript.
- Full rotations sampled at 72 angles across eight widths after fixing overflow; automatic rotation subsequently checked at 320px, 390px, 1272px and 1440px.
- Feature icons use matching SVG dimensions and stroke weights; revised vinyl-themed copy reviewed on desktop and mobile.
- All packaged images decode. Axe-core 4.12.1 reports zero WCAG A/AA violations; it leaves gradient/decorative contrast checks for manual review.
- Independent review found focus indicator contrast below 3:1; fixed with the darker heading orange. Also corrected the screenshot's intrinsic width to 968px.
- Public deployment and repository Pages settings remain separate from the source commit.
