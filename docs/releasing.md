# Releasing Bopify

The integrated source is prepared on `codex/public-distribution-integration`.
It combines the user-supplied library client ID and Library Access UI with the
audio/authentication fixes and reviewed release tooling. See the
[integration verification record](superpowers/verification/2026-10-13-public-distribution-integration.md).

This Mac still has no Developer ID Application identity. Actual Developer ID
export, notarization, Gatekeeper and second-Mac acceptance remain pending.
Installed-account Keychain access, real playback, audio output changes and
sleep/wake remain user-deferred checks. The AppKit status-bar layout warning
remains unresolved; preserve [its investigation](superpowers/verification/2026-10-12-appkit-layout-investigation.md).

The earlier [release-tooling evidence](superpowers/verification/2026-10-13-release-pipeline.md)
records the original branch's development-signed controls. New integrated controls
verify packaging only and do not establish public distribution acceptance.

## Local signing setup

Use Xcode 27 with the Metal toolchain, Rust/Cargo and the
`aarch64-apple-darwin` target. The scripts use cbindgen 0.29.4 and cargo-about
0.9.2, installing exact versions under `.build/release-tools` when necessary.

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

## GitHub Actions setup

The prepared workflow runs on a future `v*` tag, uses GitHub's `xcode-27` hosted
image and selects Xcode 27.0 explicitly. No workflow has been triggered as part
of this preparation.

Before enabling releases, configure the **release-signing** environment with
required reviewers and restrict deployment to approved version tags. Naming an
environment in YAML does not configure approval or tag protection. Protect the
release branch and tag creation so only reviewed code receives signing secrets.

Add these environment secrets using GitHub's UI:

- `DEVELOPER_ID_P12_BASE64`: the base64-encoded Developer ID certificate **and
  private key**, exported as a password-protected `.p12`.
- `DEVELOPER_ID_P12_PASSWORD`: that export password.
- `KEYCHAIN_PASSWORD`: a separate randomly generated password.
- `NOTARY_KEY_P8`: the App Store Connect `.p8` key contents.
- `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`: the associated identifiers.

CI bootstraps Rust if needed before secret import, using the
[official rustup installer](https://rustup.rs/). CI tests run before secret import. Signing uses an isolated temporary keychain,
trusts `/usr/bin/codesign` for the imported key and restores the original search
list during cleanup, including setup failures and cancellation. It does not
change the default keychain. A separate publishing job receives `contents: write`
and downloads only the successfully verified artifact. Action revisions are
pinned to full commit hashes. Signing commands necessarily pass passwords to
Apple's CLI as arguments; process arguments remain visible to the job's user.

An approved tag automatically creates its GitHub Release after verification;
a prerelease suffix marks it as a prerelease. Do not push a test tag until signing
setup, library integration and the deferred acceptance checks are complete.

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
