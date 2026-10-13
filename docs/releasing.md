# Releasing Bopify

The integrated source is prepared on `codex/public-distribution-integration`.
It combines the user-supplied library client ID and Library Access UI with the
audio/authentication fixes and reviewed release tooling. See the
[integration verification record](superpowers/verification/2026-10-13-public-distribution-integration.md).

The selected distribution route is now the free, ad-hoc-signed GitHub DMG.
Developer ID signing and notarization are optional future work, not prerequisites
for this route. Clean-Mac installation, installed-account Keychain access, real
playback, audio output changes and sleep/wake remain pending or user-deferred.
The AppKit status-bar layout warning remains unresolved; preserve
[its investigation](superpowers/verification/2026-10-12-appkit-layout-investigation.md).

The earlier [release-tooling evidence](superpowers/verification/2026-10-13-release-pipeline.md)
records the original branch's development-signed controls. New integrated controls
verify packaging only and do not establish public distribution acceptance.

## Distribution route

This workflow publishes an ad-hoc-signed DMG to GitHub Releases. It uses no
Apple signing certificate, notarization credentials or Apple Developer Program
membership. The ad-hoc signature provides integrity checks but does not identify
the publisher to Gatekeeper; the app is not notarized.

After copying the app to Applications, try opening it. If macOS blocks it and you
trust the download, use System Settings → Privacy & Security → Open Anyway.
[Apple's installation instructions](https://support.apple.com/en-us/102445)
describe this exception; managed Macs may not allow it. Do not disable Gatekeeper
globally as an installation step.

The existing Developer ID/notarized path remains available for later. Those
credentials support distribution outside the App Store and do not require an
App Store listing or App Review.

The latest dependency update removes the XML/time advisories and yanked macro
package. The raw audit still reports the RSA advisory, whose private-key attack
path was not found in the current public-key verification usage. The integration
verification record preserves that scoped assessment, raw findings and checks;
reassess it when the dependency or its usage changes.

## Local build and free packaging

Use Xcode 27 with the Metal toolchain and Rust 1.99+. The checked-in
`rust-toolchain.toml` selects Rust 1.99.0, Clippy, rustfmt and the
`aarch64-apple-darwin` target when using rustup. Environment or directory
overrides take precedence; check `rustup show active-toolchain` before building. The scripts use cbindgen 0.29.4 and cargo-about
0.9.2, installing exact versions under `.build/release-tools` when necessary.

From a clean, committed checkout, build the free package:

```sh
./scripts/release.sh 0.1.0-rc.1 --ad-hoc
```

The script explicitly selects ad-hoc signing, archives with no development team,
copies the archived app and verifies it before packaging. It preserves the four
required sandbox/network/file capabilities and hardened runtime. It rejects
unexpected identity entitlements, debugger access and runtime exceptions.
The app and DMG receive ad-hoc signatures; no notarization or Gatekeeper approval
is claimed. Evidence records `signing: ad-hoc` and `notarized: false`.

The final DMG appears at `build/release/Bopify-<version>.dmg` only after the free
packaging checks pass. Existing artifacts are never overwritten. Each run keeps
its archive and policy evidence in a distinct directory. License notices ship
inside the app and alongside it in the DMG, with exact-version MPL source links.

Switching signing modes or installing another ad-hoc build may cause Keychain
authorization prompts because file-based Keychain ACLs depend on the app's code
identity. The app preserves grants on temporary access errors. Test continuity
with an installed account before publishing an update; automated packaging alone
does not establish that behavior. See
[Apple's code requirement documentation](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

## GitHub Actions setup

The prepared workflow runs on a future `v*` tag, uses GitHub's `xcode-27` hosted
image and selects Xcode 27.0 explicitly. No workflow has been triggered as part
of this preparation.

The current workflow explicitly invokes `release.sh <version> --ad-hoc` after
its tests. It does not use `ci-release.py`, a signing environment or Apple secrets.
Protect release branches and version tags so only reviewed inputs are published.

CI bootstraps Rust if needed using the [official rustup installer](https://rustup.rs/)
and selects the checked-in toolchain pin. A separate publishing job receives
`contents: write` and downloads only the successfully verified artifact. Action
revisions are pinned to full commit hashes. Release notes disclose ad-hoc signing,
absent notarization and the installation exception.

An approved tag creates its GitHub Release after packaging verification; a
prerelease suffix marks it as a prerelease. Complete local installation and the
deferred live checks before tagging. The first approved prerelease run must
validate hosted execution before treating the workflow as accepted.

## Optional Developer ID and notarization setup

The existing paid route uses `./scripts/release.sh <version>` without `--ad-hoc`.
It never silently falls back to ad-hoc signing if credentials are missing.

Install a **Developer ID Application** certificate with its private key for team
`6RS6K2N242`. Creating that certificate requires the
[Account Holder role](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).
Store notarization credentials locally:

```sh
xcrun notarytool store-credentials bopify-notary \
  --key /absolute/path/AuthKey.p8 --key-id KEY_ID --issuer ISSUER_ID
./scripts/release.sh 0.1.0-rc.1
```

Keep private keys and passwords out of Git and chat. Commit the release inputs
before running the script. `SIGN_IDENTITY` can select a certificate fingerprint
or full subject. `BUILD_NUMBER` defaults to the Git commit count; it must be
1–9999. A prerelease suffix stays in the DMG filename; the app's marketing version
has three numeric components.

The final DMG appears at `build/release/Bopify-<version>.dmg` only after export
signature, arm64, runtime, sandbox, version, notice, notarization-log, staple and
Gatekeeper checks pass. Existing final artifacts are never overwritten. Each
run retains its archive, export and notarization evidence in a distinct directory.
Notarization waits up to one hour. Failed or timed-out submissions need
investigation; a timeout does not cancel
the job at Apple. Retain the job ID and retrieve its log before retrying.

Notices ship inside `Bopify.app` and alongside it in the DMG. The notices include
exact-version source links for dependencies distributed under MPL-2.0.

For future hosted notarized releases, restore the credential helper invocation
and configure the protected `release-signing` environment before giving it secrets.
The retained `ci-release.py` uses an isolated temporary keychain and restores the
original search list on success, failure and cancellation. Current free releases
do not invoke it. The required optional secrets are `DEVELOPER_ID_P12_BASE64`,
`DEVELOPER_ID_P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `NOTARY_KEY_P8`, `NOTARY_KEY_ID`
and `NOTARY_ISSUER_ID`. Keep keys and passwords out of Git and chat.

## Verification and sources

```sh
python3 -m unittest discover -s scripts/tests -v
swift test --package-path Packages/BopifyCore
, actionlint .github/workflows/release.yml
```

[Apple: Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution) — notarize and staple the shipped container.

[Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) — inspect notarization logs, including accepted jobs.

[Apple DTS: Keychain partition lists](https://developer.apple.com/forums/thread/712005) — scope key access to the signing keychain.

[Apple: LSApplicationCategoryType](https://developer.apple.com/documentation/bundleresources/information-property-list/lsapplicationcategorytype) — the app uses the Music category.

[GitHub: Secure use of Actions](https://docs.github.com/en/actions/reference/security/secure-use) — full revision pins and least privilege.

[GitHub: Xcode 27 arm64 image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) — image/toolchain requirements, checked 2026-10-13.

[cargo-about 0.9.2](https://github.com/EmbarkStudios/cargo-about/releases/tag/0.9.2) — pinned license generator.

[cbindgen 0.29.4](https://github.com/mozilla/cbindgen/releases/tag/0.29.4) — pinned header generator.
