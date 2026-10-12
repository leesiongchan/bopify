# Release Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a Developer ID-signed, notarized, stapled `Bopify-<version>.dmg` locally with one script, and publish it to GitHub Releases from a `v*` tag.

**Architecture:** Release configuration signs manually with Developer ID and hardened runtime, arm64 only. `scripts/release.sh` archives, exports, stages the app with license notices, builds a UDZO DMG with `hdiutil`, notarizes it with `notarytool`, staples and verifies. A GitHub Actions workflow imports the certificate into a temporary keychain and runs the same script.

**Tech Stack:** Xcode 27 `xcodebuild`, `codesign`, `hdiutil`, `notarytool`, `stapler`, `spctl`; cargo-about 0.9.2; GitHub Actions (`xcode-27` image, `actions/checkout@v7`).

**Spec:** [2026-10-11-public-distribution-design.md](../specs/2026-10-11-public-distribution-design.md), sections "Release pipeline" and "Open-source groundwork".

## Global Constraints

- arm64 only. Team `6RS6K2N242`, bundle ID `com.leesiongchan.bopify` unchanged.
- Debug keeps automatic Apple Development signing so Xcode runs work as before. Only Release uses Developer ID.
- No new tool dependencies beyond what Xcode ships, plus cargo-about 0.9.2 installed the way `gen-header.sh` installs cbindgen.
- Never echo secrets in scripts or CI logs. Notarization credentials come from a keychain profile locally and from an App Store Connect API key in CI.
- Pushing tags, creating releases, and adding repository secrets are the user's actions; the implementer prepares and verifies everything up to them.
- Work in `.worktrees/release-pipeline`, branched from `main` after the README rewrite is committed.
- Order: [the bring-your-own library client plan](2026-10-11-bring-your-own-library-client.md) merges before Task 5 and before any public tag. Until then a release would ship the owner's five-user Dashboard ID, and Task 5 documents a "Library Access…" menu that would not exist yet. Tasks 1–4 can proceed in parallel with it.

## Prerequisites (the user, once)

1. Active Apple Developer Program membership (99 USD/year, [enrollment](https://developer.apple.com/help/account/membership/program-enrollment/)) on team `6RS6K2N242`.
2. Xcode → Settings → Accounts → Manage Certificates → **+** → **Developer ID Application**.
3. App Store Connect → Users and Access → Integrations → Team Keys: create a key with the Developer role; download the `.p8`, note the Key ID and Issuer ID.
4. Local notary profile: `xcrun notarytool store-credentials bopify-notary --key <path>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>`.

## Review Focus

1. `lipo -archs` on the shipped binary prints exactly `arm64` (Task 1).
2. `codesign -dv` on the exported app shows `Authority=Developer ID Application` and the `runtime` flag (Task 1, Task 3).
3. A rejected notarization prints Apple's log and fails the script; it never staples or reports success (Task 3).
4. The DMG contains `Bopify.app`, an `Applications` link, `LICENSE.txt` and `Third-Party Licenses.html` (Tasks 2–3).

---

### Task 1: Release build settings

**Files:**
- Modify: `Bopify/Bopify.xcodeproj/project.pbxproj` — target `Bopify` Debug (`19D0CF36…`) and Release (`19D0CF37…`) build settings.

- [ ] **Step 1: Record the current state**

Run: `xcodebuild -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Release -destination 'generic/platform=macOS' -showBuildSettings | rg '^\s*(ARCHS|ENABLE_HARDENED_RUNTIME|CODE_SIGN_IDENTITY|CODE_SIGN_STYLE) ='`
Expected: `ARCHS = arm64 x86_64`, hardened runtime `NO`, `Apple Development`, `Automatic`.

- [ ] **Step 2: Edit the target's Release configuration only**

Debug already builds only the active architecture and needs neither change.

```
				ARCHS = arm64;
				"CODE_SIGN_IDENTITY[sdk=macosx*]" = "Developer ID Application";
				CODE_SIGN_STYLE = Manual;
				ENABLE_HARDENED_RUNTIME = YES;
```

Replace the existing `CODE_SIGN_IDENTITY[sdk=macosx*]` and `CODE_SIGN_STYLE` lines; keep keys alphabetical, matching the file. A target-level `ARCHS` may not reach the local Swift package's targets, so `release.sh` (Task 3) also passes `ARCHS=arm64` on the command line, which applies to every target.

- [ ] **Step 3: Verify**

Re-run Step 1's command. Expected: `ARCHS = arm64`, `ENABLE_HARDENED_RUNTIME = YES`, `Developer ID Application`, `Manual`.
Run the Debug build: `xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -destination 'platform=macOS,arch=arm64' build` — expected: succeeds.
Run `swift test --package-path Packages/BopifyCore` — expected: passes (sanity; nothing here should change it).

- [ ] **Step 4: Commit**

```bash
git add Bopify/Bopify.xcodeproj/project.pbxproj
git commit -m "Sign Release builds with Developer ID and hardened runtime, arm64 only"
```

### Task 2: License and third-party notices

**Files:**
- Create: `LICENSE`
- Create: `rust/about.toml`, `rust/about.hbs`
- Create: `scripts/gen-notices.sh`

**Interfaces:**
- Produces: `scripts/gen-notices.sh <absolute-output-path>` writes an HTML file of every Rust dependency's license text; Task 3 calls it.

- [ ] **Step 1: Add `LICENSE`**

Standard MIT text, first line `MIT License`, copyright line `Copyright (c) 2026 leesiongchan`. (Use the user's legal name instead if they give one.)

- [ ] **Step 2: Add the cargo-about template and config**

`rust/about.hbs` (cargo-about's documented template data: `licenses[].name/id/text/used_by[].crate`):

```hbs
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Bopify third-party licenses</title>
<style>body{font:14px -apple-system,sans-serif;max-width:860px;margin:2em auto;padding:0 1em}pre{white-space:pre-wrap;background:#f4f4f4;padding:1em}</style>
</head>
<body>
<h1>Third-party licenses</h1>
<p>Bopify includes the following open-source software.</p>
{{#each licenses}}
<h2 id="{{id}}">{{name}}</h2>
<p>Used by:</p>
<ul>{{#each used_by}}<li>{{crate.name}} {{crate.version}}</li>{{/each}}</ul>
<pre>{{text}}</pre>
{{/each}}
</body>
</html>
```

`rust/about.toml`:

```toml
targets = ["aarch64-apple-darwin"]
accepted = [
    "MIT",
    "Apache-2.0",
    "Apache-2.0 WITH LLVM-exception",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "ISC",
    "Zlib",
    "Unicode-3.0",
    "CC0-1.0",
    "MPL-2.0",
]
```

- [ ] **Step 3: Add `scripts/gen-notices.sh`**

```bash
#!/usr/bin/env bash
# Writes the license texts of every Rust crate linked into the app; MIT and
# Apache both require them to ship with binary copies.
set -euo pipefail
out=${1:?usage: scripts/gen-notices.sh <absolute-output-path>}
cd "$(dirname "$0")/../rust"
cargo install cargo-about --locked --version 0.9.2 2>/dev/null || true
cargo about generate --config about.toml --manifest-path crates/bopify-core/Cargo.toml about.hbs > "$out"
```

`chmod +x scripts/gen-notices.sh`.

- [ ] **Step 4: Run it and resolve rejected licenses**

Run: `./scripts/prepare-librespot.sh && ./scripts/gen-notices.sh /private/tmp/bopify-notices.html`
First confirm the flags with `cargo about generate --help` (`--config`, `--manifest-path`); adjust the script if 0.9.2 names them differently.
If cargo-about reports a license as not accepted, add it to `accepted` only if it permits binary redistribution with attribution (permissive or file-level copyleft). If any is GPL/LGPL/AGPL, stop and report it to the user: statically linking it would put the distributed app under that license's terms.
Expected: exit 0; `rg -c '<h2' /private/tmp/bopify-notices.html` ≥ 2; `rg -q librespot /private/tmp/bopify-notices.html` succeeds.

- [ ] **Step 5: Commit**

```bash
git add LICENSE rust/about.toml rust/about.hbs scripts/gen-notices.sh
git commit -m "License Bopify under MIT and generate Rust dependency notices"
```

### Task 3: `scripts/release.sh`

**Files:**
- Create: `scripts/release.sh`, `scripts/ExportOptions.plist`
- Modify: `.gitignore` (add `build/`)

**Interfaces:**
- Consumes: `scripts/build-rust.sh`, `scripts/gen-notices.sh <path>`, `LICENSE`.
- Produces: `scripts/release.sh <version>` → `build/release/Bopify-<version>.dmg`; a `-suffix` (e.g. `-rc.1`) stays in the file name but not in the bundle version. Env: `BUILD_NUMBER` (default `git rev-list --count HEAD`), `NOTARY_PROFILE` (default `bopify-notary`), or `NOTARY_KEY_PATH` + `NOTARY_KEY_ID` + `NOTARY_ISSUER_ID` (CI), `SIGN_IDENTITY` (default `Developer ID Application`).

- [ ] **Step 1: Add `scripts/ExportOptions.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
	<key>teamID</key>
	<string>6RS6K2N242</string>
</dict>
</plist>
```

- [ ] **Step 2: Add `scripts/release.sh`**

```bash
#!/usr/bin/env bash
# Builds build/release/Bopify-<version>.dmg: Developer ID-signed, notarized and stapled.
# Notarizes with an App Store Connect API key when NOTARY_KEY_PATH is set (CI),
# otherwise with the notarytool keychain profile NOTARY_PROFILE (default bopify-notary).
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: scripts/release.sh <version>}
# CFBundleShortVersionString allows only numbers and dots; "0.1.0-rc.1" ships as 0.1.0.
marketing_version=${version%%-*}
build_number=${BUILD_NUMBER:-$(git rev-list --count HEAD)}
out="$PWD/build/release"
app="$out/export/Bopify.app"
dmg="$out/Bopify-$version.dmg"

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  notary_auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  notary_auth=(--keychain-profile "${NOTARY_PROFILE:-bopify-notary}")
fi

rm -rf "$out"
mkdir -p "$out/dmg"

./scripts/build-rust.sh

echo "Archiving Bopify $version ($build_number)"
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$out/Bopify.xcarchive" \
  ARCHS=arm64 MARKETING_VERSION="$marketing_version" CURRENT_PROJECT_VERSION="$build_number" archive
xcodebuild -quiet -exportArchive -archivePath "$out/Bopify.xcarchive" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$out/export"

archs=$(lipo -archs "$app/Contents/MacOS/Bopify")
[[ "$archs" == arm64 ]] || { echo "Expected an arm64-only binary, got: $archs" >&2; exit 1; }
codesign --verify --strict --verbose=2 "$app"

cp -R "$app" "$out/dmg/"
ln -s /Applications "$out/dmg/Applications"
cp LICENSE "$out/dmg/LICENSE.txt"
./scripts/gen-notices.sh "$out/dmg/Third-Party Licenses.html"
hdiutil create -quiet -volname Bopify -srcfolder "$out/dmg" -format UDZO -ov "$dmg"
codesign --sign "${SIGN_IDENTITY:-Developer ID Application}" --timestamp "$dmg"

echo "Submitting $(basename "$dmg") for notarization"
# Parse the status rather than trusting the exit code, so a rejection always prints Apple's log.
xcrun notarytool submit "$dmg" "${notary_auth[@]}" --wait --output-format json > "$out/notary.json" || true
status=$(plutil -extract status raw -o - "$out/notary.json" 2>/dev/null || echo unknown)
if [[ "$status" != Accepted ]]; then
  if id=$(plutil -extract id raw -o - "$out/notary.json" 2>/dev/null); then
    xcrun notarytool log "$id" "${notary_auth[@]}" >&2 || true
  fi
  echo "Notarization status: $status" >&2
  exit 1
fi

xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
echo "Release ready: $dmg"
```

`chmod +x scripts/release.sh`; append `build/` to `.gitignore`.

- [ ] **Step 3: Static check**

Run: `bash -n scripts/release.sh && , shellcheck scripts/release.sh scripts/gen-notices.sh`
Expected: no errors.

- [ ] **Step 4: End-to-end run (needs the prerequisites)**

Run: `./scripts/release.sh 0.1.0`
Expected: ends with `Release ready: …/Bopify-0.1.0.dmg`, and `spctl` prints `accepted` and `source=Notarized Developer ID`. Then:

```sh
codesign -dv --verbose=4 build/release/export/Bopify.app 2>&1 | rg 'Authority=Developer ID Application|flags=.*runtime'
xcrun stapler validate build/release/Bopify-0.1.0.dmg
hdiutil attach -nobrowse build/release/Bopify-0.1.0.dmg   # inspect contents, then hdiutil detach
```

Expected: both `rg` patterns match; `The validate action worked!`; the volume lists `Bopify.app`, `Applications`, `LICENSE.txt`, `Third-Party Licenses.html`.
Final check by the user: copy the DMG to a second Mac (or a fresh macOS user), open it, drag to Applications, launch — no Gatekeeper dialog beyond the standard "downloaded from the internet" confirmation. Existing installs on the build Mac may show one Keychain access prompt (signing identity changed); choose Always Allow.

- [ ] **Step 5: Commit**

```bash
git add scripts/release.sh scripts/ExportOptions.plist .gitignore
git commit -m "Add a release script that builds a notarized DMG"
```

### Task 4: GitHub Actions release workflow

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Add the workflow**

```yaml
name: Release

on:
  push:
    tags: ["v*"]

permissions:
  contents: write

jobs:
  release:
    # Preview image; the only GitHub-hosted runner with Xcode 27 as of 2026-10.
    runs-on: xcode-27
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0  # release.sh derives the build number from the commit count

      - name: Install Rust
        run: |
          command -v rustup || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
          echo "$HOME/.cargo/bin" >> "$GITHUB_PATH"

      - name: Install Metal Toolchain
        run: xcodebuild -downloadComponent MetalToolchain

      - name: Import Developer ID certificate
        env:
          DEVELOPER_ID_P12_BASE64: ${{ secrets.DEVELOPER_ID_P12_BASE64 }}
          DEVELOPER_ID_P12_PASSWORD: ${{ secrets.DEVELOPER_ID_P12_PASSWORD }}
          KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
        run: |
          certificate="$RUNNER_TEMP/developer-id.p12"
          keychain="$RUNNER_TEMP/signing.keychain-db"
          echo -n "$DEVELOPER_ID_P12_BASE64" | base64 --decode -o "$certificate"
          security create-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
          security set-keychain-settings -lut 21600 "$keychain"
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
          security import "$certificate" -P "$DEVELOPER_ID_P12_PASSWORD" -A -t cert -f pkcs12 -k "$keychain"
          security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$keychain"
          security list-keychain -d user -s "$keychain"

      - name: Write notary key
        env:
          NOTARY_KEY_P8: ${{ secrets.NOTARY_KEY_P8 }}
        run: echo "$NOTARY_KEY_P8" > "$RUNNER_TEMP/notary.p8"

      - name: Build, sign and notarize
        env:
          NOTARY_KEY_PATH: ${{ runner.temp }}/notary.p8
          NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
          NOTARY_ISSUER_ID: ${{ secrets.NOTARY_ISSUER_ID }}
        run: ./scripts/release.sh "${GITHUB_REF_NAME#v}"

      - name: Publish release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          version="${GITHUB_REF_NAME#v}"
          prerelease=()
          [[ "$version" == *-* ]] && prerelease=(--prerelease)
          gh release create "$GITHUB_REF_NAME" "build/release/Bopify-$version.dmg" --title "Bopify $version" --generate-notes "${prerelease[@]}"

      - name: Remove signing material
        if: always()
        run: |
          security delete-keychain "$RUNNER_TEMP/signing.keychain-db" || true
          rm -f "$RUNNER_TEMP/developer-id.p12" "$RUNNER_TEMP/notary.p8"
```

- [ ] **Step 2: Lint**

Run: `, actionlint .github/workflows/release.yml`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Publish notarized DMGs to GitHub Releases on version tags"
```

- [ ] **Step 4: Hand off to the user**

The user adds repository secrets (Settings → Secrets and variables → Actions):
`DEVELOPER_ID_P12_BASE64` (export the Developer ID certificate with its private key from Keychain Access as `.p12`, then `base64 -i cert.p12 | pbcopy`), `DEVELOPER_ID_P12_PASSWORD`, `KEYCHAIN_PASSWORD` (any random string), `NOTARY_KEY_P8` (contents of the `.p8`), `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`.
Then pushes a pre-release tag, e.g. `git tag v0.1.0-rc.1 && git push leesiongchan v0.1.0-rc.1`, and checks the Actions run and the resulting release. Delete the test release and tag afterwards if unwanted.

### Task 5: README for public users

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the README**

Keep the existing structure and voice. Changes:
- Opening: replace "It's a personal tool: built from source, for one account, and not distributed." with a **Download** pointer: latest `Bopify-<version>.dmg` from GitHub Releases; requires an Apple Silicon Mac on macOS 14+ and Spotify Premium.
- New section **Library features** after Download: playback works immediately; Favorites, Liked Songs and history need the user's own free Spotify app via **Library Access…** in the status menu; link `docs/spotify-app-setup.md`.
- "Spotify sign-in and privacy": replace the "Library features are opt-in and separate" paragraph — the client ID is now the user's own app, still requested only when a feature is turned on.
- New section **Disclaimer** at the end: Bopify is an unofficial, free, non-commercial project not affiliated with or endorsed by Spotify; it uses librespot, whose own README warns that using it to connect to Spotify's API is probably forbidden by Spotify; use at your own risk. Mention that some newer accounts currently can't play through librespot ([librespot #1649](https://github.com/librespot-org/librespot/issues/1649)).
- New section **Releasing** (for maintainers): prerequisites from this plan, `./scripts/release.sh <version>`, and that pushing a `v*` tag runs the same in CI.
- New section **License**: MIT, see `LICENSE`; third-party licenses ship in the DMG.

- [ ] **Step 2: Verify**

Every command and path in the README exists: `rg -o '\./scripts/[a-z-]+\.sh' README.md | sort -u | xargs ls`. Links render: preview with `, glow README.md`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Document downloading, library setup and releases"
```
