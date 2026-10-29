# Release pipeline redesign

## Goal

Every push to `main` releases Bopify automatically when, and only when, it brings user-facing app changes. git-cliff decides the version and writes the notes, `gh` publishes, and GitHub Actions orchestrates. Nobody intervenes by hand.

## Release policy (C1)

A push releases only if git-cliff finds at least one unreleased `feat`, `fix`, `perf`, `revert` or breaking commit (git's default `Revert "feat: …"` message of a user-facing commit counts as a `revert`) touching a path in `cliff.toml`'s `include_paths`. Other commit types on app paths (`chore`, `refactor`, `build`, `test`, …) do not release on their own; they ship with the next qualifying release but are omitted from its notes. A dependency bump that should ship on its own is committed as `fix(deps):`.

The decision is made per commit, not per diff. A `feat` that is later reverted still releases, and both appear in the notes; the old path-diff check skipped that case.

Version bumps are unchanged: breaking gives major, `feat` gives minor, anything else gives patch.

## What is removed

- `scripts/prepare-release.py` and `scripts/tests/test_prepare_release.py`: path diffing, the patch-bump fallback, the tag-collision loop and the `--count-tags` workaround.
- `ncipollo/release-action`: both the draft step and the publish step.
- The "Maintenance release" template branch and `render_always = true` in `cliff.toml`.
- The `gh release list` lookup of the previous release.

## Components

### `cliff.toml`

- `tag_pattern` becomes `^v[0-9]+\.[0-9]+\.[0-9]+$`. A manually pushed prerelease tag such as `v1.0.1-rc1` otherwise becomes the boundary and yields `v1.0.1-rc1.1` (checked against git-cliff 2.14.2).
- Remove the `{% if commits | length == 0 %}` branch and `render_always`; under C1 the notes always contain at least one commit.
- `include_paths`, `commit_parsers` and `[bump]` stay as they are.

### `scripts/plan-release.sh <notes-path>`

1. `git-cliff --offline --unreleased --bump --body '{{ commits | length }} {{ version }}'` prints the number of unreleased user-facing commits and the next version. This replaces parsing the `--context` JSON, so the script needs no `jq`, which isn't installed locally. When the count is 0, the version printed is the previous release.
2. If there are 0 commits: log `No user-facing app changes since <previous>; skipping release.`, write `release=false` to `$GITHUB_OUTPUT`, exit 0.
3. Otherwise run `git-cliff --offline --unreleased --bump --output <notes-path>`, log the version, commit count and notes size, and write `release=true`, `tag=vX.Y.Z` and `version=X.Y.Z` to `$GITHUB_OUTPUT`.

Do not use `git-cliff --bumped-version` on its own. It drops tags on commits outside `include_paths`; the real `v1.0.0` is one of these. The next fix would then be numbered `v1.0.0` or `v1.0.1` again (checked against 2.14.2). `--unreleased` keeps those tags.

The previous release is the latest tag matching `tag_pattern`. Every such tag belongs to a published release, because `gh` creates the tag only when the release is published. git-cliff finds a tag even when it sits on a commit that `include_paths` filters out (checked on the real repo at `v1.0.0` and in a fixture).

### `.github/workflows/release.yml`

The trigger (`push` to `main`), top-level `permissions: contents: read`, and the `concurrency` block (`release-main`, no cancellation, queued) are unchanged.

- **`plan`** (`ubuntu-latest`, read-only): checkout with `fetch-depth: 0`; install git-cliff through the existing `mise-action` pin; run `python3 -B -m unittest discover -s scripts/tests -v`; run `scripts/plan-release.sh build/release/notes.md`; when releasing, upload `notes.md` as the `release-notes` artifact. Outputs: `release`, `tag`, `version`.
- **`build`** (`xcode-27`, read-only): runs only if `needs.plan.outputs.release == 'true'`. Steps are unchanged (tests, caches, `release.sh "$version" --skip-rust-build`) except that it no longer downloads the release notes, no longer passes `version`/`tag` through as outputs, and the `verified-dmg` artifact holds only the DMG.
- **`publish`** (`ubuntu-26.04`, `contents: write`, no checkout): `needs: [plan, build]`; env `GH_TOKEN`, `GH_REPO: ${{ github.repository }}`, `TAG`, `VERSION` from `needs.plan.outputs`; download both artifacts into `release/` with `merge-multiple: true`; then:

  ```sh
  latest=$(gh release view --json tagName --jq .tagName)
  if [[ $(printf '%s\n' "$latest" "$TAG" | sort -V | tail -n 1) != "$TAG" ]]; then
    echo "$latest is newer than $TAG; refusing to publish a stale release." >&2
    exit 1
  fi
  gh release create "$TAG" "release/Bopify-$VERSION.dmg" \
    --target "$GITHUB_SHA" --title "Bopify $VERSION" --notes-file release/notes.md
  ```

  The guard refuses to publish when the latest release is newer than `$TAG`: a stale "Re-run failed jobs" on an older run would otherwise publish its old tag as Latest. When an asset is attached, `gh release create` creates a draft, uploads, publishes, and deletes the draft on failure (cli/cli `pkg/cmd/release/create/create.go`). The release becomes Latest by the API default. `gh` is the one preinstalled on GitHub-hosted runners and is not pinned.

Only `publish` holds a write token. Pushes that don't release never start a macOS runner.

### `README.md`

Rewrite the Releases section (currently lines 42–44) to describe C1: which commit types release, that other types wait for the next release, and `fix(deps):` for shipping a dependency bump on its own. Drop the "maintenance notes" and "start at 1.0.0" sentences.

## Failure handling

| Failure | State left behind | Recovery |
|---|---|---|
| `plan` or `build` fails | No release, no tag | Re-run, or the next qualifying push includes the pending commits |
| `publish` fails | gh deleted the draft; no tag | Re-run the failed job (artifacts kept 14 days), unless a later run has already released (the publish job then refuses as stale; nothing to do, since the later release contains these commits) |
| `publish` reports failure after GitHub actually published (lost response) | gh deletes the release; the tag remains | A whole-workflow re-run skips (HEAD is tagged); recover with `gh release create "$TAG" <dmg> --verify-tag --title ... --notes-file ...` from the run's artifacts |
| Successful run re-run | Tag on HEAD | `plan` finds 0 commits and skips |
| Only `publish` re-run after success | Release exists | `gh` fails with "already exists"; nothing overwritten |

Not handled: a stable tag pushed by hand to an older commit becomes the boundary. This is treated as operator error.

## Testing

`scripts/tests/test_plan_release.py` (Python `unittest`, the same fixture approach as the file it replaces: a throwaway repo with global git config disabled, the real `cliff.toml`, `v1.0.0` tagged) runs `plan-release.sh` and reads `$GITHUB_OUTPUT` and the notes:

- Skip: site/README/test-only `feat`; app-path `chore`/`refactor`; `build(deps)`; HEAD already tagged.
- Bump: app `fix` and `perf` give 1.0.1; `feat` gives 1.1.0; `feat!` and a `BREAKING CHANGE:` footer give 2.0.0.
- Boundaries: a previous tag on a filtered-out commit is honoured; `v1.0.1-rc1` is ignored.
- Notes: contain the user-facing subject and the breaking upgrade text, omit internal commits, and link `v1.0.0...vX.Y.Z`.

Verification before merge: run the tests locally with the pinned git-cliff 2.14.2, and run `actionlint` on the workflow. The workflow is proved end to end by the first qualifying push to `main`.
