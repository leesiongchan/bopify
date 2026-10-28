# Midnight Pressing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the template-like landing page with the approved dramatic Midnight Pressing design.

**Architecture:** Recompose `site/index.html` and replace its layout styles in `site/styles.css`. Use the existing app PNG with circular and rectangular CSS crops; the current Pages workflow continues packaging the same static assets.

**Tech Stack:** HTML, CSS, GitHub Pages; no new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-29-midnight-pressing-design.md`

## Global Constraints

- macOS 26+, Apple silicon, Spotify Premium, developer setup and ad-hoc signing remain accurate and visible.
- No JavaScript, new dependencies, native app changes or unrelated README edits.
- Relative URLs, continuous record rotation, reduced-motion support and consistent SVG icons.

## Review Focus

- Animated record bounds must never create horizontal overflow.
- The real player and download action must be visible in the opening composition.
- Product crops must show accurate UI and align with the original screenshot.
- Text contrast and keyboard focus must work on black, mint, ivory and orange.
- Mobile stacking and long setup URLs must remain readable.

### Task 1: Recompose the product page

**Files:** Modify `site/index.html`, `site/styles.css`.

**Interfaces:** `.record-face` rotates inside circular clipped wrappers. The real player image and detail crops all consume `assets/player.png`. Navigation retains `#experience`, `#liner-notes` and `#setup`.

- [x] Capture the current local page as a baseline.
- [x] Implement the masthead/product hero, mint library spread, vinyl and lyric passages, compact notes and orange download finish.
- [x] Keep metadata, feature claims and setup content accurate.
- [x] Inspect desktop/mobile screenshots and fix composition or crop errors.

### Task 2: Verify the result

**Files:** No new production files; update this plan with results.

- [x] Check full rotations across mobile/tablet/desktop widths, including 320px and 1440px.
- [x] Check reduced motion, image loading, native disclosure keyboard behavior and accessibility.
- [x] Package the site with the existing workflow commands; verify asset and fragment references and run diff checks.
- [x] Obtain an independent review, fix important findings and record the final publication state.

## Verification

- Full rotations sampled every 5 degrees at 320, 390, 500, 540, 768, 800, 820, 1024, 1280, 1440 and 1920px: no horizontal overflow, all feature icons 32px and complete hero player visible.
- Both records stop with reduced motion; setup disclosures respond to Enter. Mint download focus outline stays visible on the dark background.
- Product images decode. Desktop/mobile before-and-after screenshots inspected.
- Axe-core 4.12.1: zero A/AA violations; background/gradient contrast checks require manual review. Main text color pairs were separately calculated at 4.76:1 or higher.
- Independent review found the large record overlapping following text at 500–540px. Reproduced a 215px overlap at 540px, then fixed the mobile visual height and clipping; regression check passes.
- Relative assets, anchors, unique IDs, one h1, and static package verified. No JavaScript or new dependencies.
- Public deployment remains separate from the source commit. Existing pending README edit preserved.
