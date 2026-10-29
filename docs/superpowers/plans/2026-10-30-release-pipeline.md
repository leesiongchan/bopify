# Release Pipeline Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every push to `main` that brings user-facing app commits publishes a Bopify release automatically, with git-cliff deciding the version and notes and `gh` publishing.

**Architecture:** A read-only `plan` job runs `scripts/plan-release.sh`, which asks git-cliff how many unreleased user-facing app commits exist and what the next version is. The unchanged macOS `build` job packages the DMG only when `plan` says release. A `publish` job, the only one with write access, runs a single `gh release create`.

**Tech Stack:** GitHub Actions, git-cliff 2.14.2 (pinned in `mise.toml`, installed via `jdx/mise-action`), `gh` (preinstalled on GitHub-hosted runners), Bash, Python `unittest` for fixture tests.

**Spec:** `docs/superpowers/specs/2026-10-30-release-pipeline-design.md`

## Global Constraints

- Release policy C1: release only if at least one unreleased `feat`, `fix`, `perf`, `revert` or breaking commit touches a path in `cliff.toml`'s `include_paths`.
- Do not use `git-cliff --bumped-version` on its own: it drops tags on commits outside `include_paths`, and the real `v1.0.0` is one of these. Always pass `--unreleased --bump`.
- `tag_pattern` must be `^v[0-9]+\.[0-9]+\.[0-9]+$` (stable releases only).
- Only the `publish` job gets `contents: write`. Keep every existing action SHA pin and the `concurrency` block unchanged.
- No `jq` in scripts (it isn't installed on the maintainer's machine).
- Commit messages follow Conventional Commits and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. These are `ci:`/`docs:` commits, so they don't appear in app release notes.
- Work on a branch in an isolated worktree. The main checkout has the user's uncommitted Swift edits plus edits to `scripts/prepare-release.py` and its test. Never touch, stage or discard them.
- Run git-cliff-dependent commands through `mise exec --` locally. The fixture repos live outside the project, so mise shims can't resolve the tool version there. In a fresh worktree, run `mise trust` first if `mise exec` reports an untrusted config.
- The `publish` job has no checkout on purpose. `gh release create` only calls local git through `gitTagInfo`, whose error it discards (cli/cli `create.go:296-299`), and `GH_REPO` supplies the repository.

## File map

| File | Change | Responsibility |
|---|---|---|
| `scripts/plan-release.sh` | Create | Decide release or skip, write notes, emit `release`/`tag`/`version` to `$GITHUB_OUTPUT` |
| `scripts/tests/test_plan_release.py` | Create | Fixture-repo regression tests for the release policy |
| `scripts/prepare-release.py` | Delete | Replaced by `plan-release.sh` |
| `scripts/tests/test_prepare_release.py` | Delete | Replaced by `test_plan_release.py` |
| `cliff.toml` | Modify | Stable-only `tag_pattern`; drop the maintenance-release template branch and `render_always` |
| `.github/workflows/release.yml` | Modify | `plan` job (Task 1); `build` and `publish` simplification with `gh` (Task 2) |
| `README.md` | Modify | Releases section describes C1 |

---

### Task 1: Release planning with git-cliff

**Files:**
- Create: `scripts/plan-release.sh`
- Create: `scripts/tests/test_plan_release.py`
- Delete: `scripts/prepare-release.py`, `scripts/tests/test_prepare_release.py`
- Modify: `cliff.toml` (template lines 3–5, 15, `render_always`, `tag_pattern`)
- Modify: `.github/workflows/release.yml` (`prepare` job → `plan`; job references in `build`/`publish`)
- Modify: `README.md:40-44`

**Interfaces:**
- Produces: `scripts/plan-release.sh <notes-path>`. It must run from the repo root with `GITHUB_OUTPUT` set and `git-cliff` on `PATH`. It always appends `release=true|false` to `$GITHUB_OUTPUT`; when `true` it also appends `tag=vX.Y.Z` and `version=X.Y.Z` and writes the notes to `<notes-path>`. It exits non-zero only when git-cliff fails or the usage is wrong.
- Produces: workflow job `plan` with outputs `release`, `tag` and `version`, and artifact `release-notes` containing `notes.md`. Task 2 relies on these exact names.

- [ ] **Step 1: Write the failing tests**

Create `scripts/tests/test_plan_release.py`:

```python
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PlanReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release@example.com")
        shutil.copyfile(ROOT / "cliff.toml", self.repo / "cliff.toml")
        self.commit("Bopify/Bopify/App.swift", "initial", "feat: initial player")
        self.git("tag", "v1.0.0")

    def git(self, *args):
        return subprocess.check_output(
            ["git", *args], cwd=self.repo, env=self.env, text=True
        ).strip()

    def commit(self, path, text, message):
        file = self.repo / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
        self.git("add", "--", path)
        self.git("commit", "-m", message)

    def plan(self):
        output = self.repo / "outputs"
        output.unlink(missing_ok=True)
        notes = self.repo / "build/release/notes.md"
        notes.unlink(missing_ok=True)
        subprocess.run(
            [str(ROOT / "scripts/plan-release.sh"), str(notes)],
            cwd=self.repo, env=dict(self.env, GITHUB_OUTPUT=str(output)),
            check=True, capture_output=True, text=True,
        )
        values = dict(line.split("=", 1) for line in output.read_text().splitlines())
        return values, notes.read_text() if notes.exists() else ""

    def assert_skips(self):
        values, notes = self.plan()
        self.assertEqual(values, {"release": "false"})
        self.assertEqual(notes, "")

    def test_changes_outside_the_app_skip(self):
        for path in ["site/index.html", "README.md", "AGENTS.md",
                     "Packages/BopifyCore/Tests/PlaybackTests/Test.swift",
                     "Bopify/BopifyAppTests/Test.swift",
                     "rust/crates/bopify-core/tests/test.rs",
                     ".github/workflows/release.yml"]:
            with self.subTest(path=path):
                self.commit(path, "changed", "feat: unrelated change")
                self.assert_skips()

    def test_internal_app_commits_skip(self):
        for message in ["chore: tidy player", "refactor: split player",
                        "build(deps): bump librespot", "Update internal implementation"]:
            with self.subTest(message=message):
                self.commit("Bopify/Bopify/App.swift", message, message)
                self.assert_skips()

    def test_already_released_head_skips(self):
        self.commit("Bopify/Bopify/App.swift", "fixed", "fix: retain artwork")
        self.git("tag", "v1.0.1")
        self.assert_skips()

    def test_user_facing_commits_bump_versions(self):
        for message, version in [("fix: retain artwork", "1.0.1"),
                                 ("perf: load artwork faster", "1.0.1"),
                                 ("fix(deps): patch librespot", "1.0.1"),
                                 ("revert: restore artwork", "1.0.1"),
                                 ("feat: search music", "1.1.0"),
                                 ("feat!: change setup", "2.0.0"),
                                 ("fix: change setup\n\nBREAKING CHANGE: Sign in again.", "2.0.0")]:
            with self.subTest(message=message):
                self.git("reset", "--hard", "v1.0.0")
                self.commit("Bopify/Bopify/App.swift", message, message)
                values, _ = self.plan()
                self.assertEqual(values, {"release": "true", "tag": f"v{version}",
                                          "version": version})

    def test_notes_cover_user_facing_app_changes_only(self):
        self.commit("site/index.html", "site", "feat: new product page")
        self.commit("Bopify/Bopify/App.swift", "chore", "chore: tidy player")
        self.commit("Bopify/Bopify/App.swift", "fixed", "fix: retain artwork\n\nInternal implementation diary.")
        self.commit("Bopify/Bopify/App.swift", "breaking", "fix!: change setup\n\nBREAKING CHANGE: Sign in again.")
        values, notes = self.plan()
        self.assertEqual(values["tag"], "v2.0.0")
        self.assertIn("Retain artwork", notes)
        self.assertIn("**Upgrade:** Sign in again.", notes)
        self.assertNotIn("product page", notes)
        self.assertNotIn("Tidy player", notes)
        self.assertNotIn("implementation diary", notes)
        self.assertIn("v1.0.0...v2.0.0", notes)

    def test_release_on_filtered_commit_is_the_boundary(self):
        self.commit("site/index.html", "site", "docs: product page")
        self.git("tag", "v1.0.1")
        self.commit("Bopify/Bopify/App.swift", "fixed", "fix: retain artwork")
        values, notes = self.plan()
        self.assertEqual(values["tag"], "v1.0.2")
        self.assertIn("v1.0.1...v1.0.2", notes)

    def test_only_release_on_filtered_commit_is_the_boundary(self):
        # Mirrors production: v1.0.0 was tagged on a commit outside include_paths.
        self.git("tag", "-d", "v1.0.0")
        self.commit("site/index.html", "site", "docs: product page")
        self.git("tag", "v1.0.0")
        self.assert_skips()
        self.commit("Bopify/Bopify/App.swift", "fixed", "fix: retain artwork")
        values, notes = self.plan()
        self.assertEqual(values["tag"], "v1.0.1")
        self.assertIn("v1.0.0...v1.0.1", notes)

    def test_prerelease_tags_are_ignored(self):
        self.commit("Bopify/Bopify/App.swift", "fixed", "fix: retain artwork")
        self.git("tag", "v1.0.1-rc1")
        self.commit("Bopify/Bopify/App.swift", "fixed again", "fix: restore playback")
        values, notes = self.plan()
        self.assertEqual(values["tag"], "v1.0.1")
        self.assertIn("Retain artwork", notes)
        self.assertIn("v1.0.0...v1.0.1", notes)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Delete the replaced script and tests**

The worktree comes from committed `HEAD`, so these files have no local edits there. `-f` only guards against an unexpected modified copy.

```bash
git rm -f scripts/prepare-release.py scripts/tests/test_prepare_release.py
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mise exec -- python3 -B -m unittest discover -s scripts/tests -v`
Expected: all 8 tests ERROR with `FileNotFoundError` for `scripts/plan-release.sh`.

- [ ] **Step 4: Write the planning script**

Create `scripts/plan-release.sh` and make it executable (`chmod +x scripts/plan-release.sh`):

```bash
#!/usr/bin/env bash
# Decides whether HEAD is a release and writes its notes; results go to $GITHUB_OUTPUT.
set -euo pipefail

if [[ $# != 1 ]]; then
  echo "Usage: scripts/plan-release.sh <notes-path>" >&2
  exit 1
fi

notes_path=$1
# --bumped-version alone drops tags on commits outside include_paths; --unreleased keeps them.
cliff=(git-cliff --offline --unreleased --bump)
plan=$("${cliff[@]}" --body '{{ commits | length }} {{ version }}')
read -r count tag <<< "$plan"
if [[ $count == 0 ]]; then
  echo "No user-facing app changes since $tag; skipping release."
  echo "release=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

mkdir -p "$(dirname "$notes_path")"
"${cliff[@]}" --output "$notes_path"
echo "Prepared $tag from $count user-facing commits ($(($(wc -c < "$notes_path"))) bytes of notes)."
printf 'release=true\ntag=%s\nversion=%s\n' "$tag" "${tag#v}" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 5: Run the tests; only the prerelease test should fail**

Run: `mise exec -- python3 -B -m unittest discover -s scripts/tests -v`
Expected: 7 pass. `test_prerelease_tags_are_ignored` FAILS (`'v1.0.1-rc1.1' != 'v1.0.1'` or similar), because `cliff.toml` still accepts prerelease tags.

- [ ] **Step 6: Update `cliff.toml`**

Remove the zero-commit branch from the top of `body`. Replace:

```
body = """
{% if commits | length == 0 %}
Maintenance release; no user-facing changes.
{% else %}
{% for entry in commits | commit_groups(groups=commit_parsers_groups) %}
```

with:

```
body = """
{% for entry in commits | commit_groups(groups=commit_parsers_groups) %}
```

Remove its closing tag. Replace:

```
{% endfor %}
{% endfor %}
{% endif %}
## Installation
```

with:

```
{% endfor %}
{% endfor %}
## Installation
```

Delete the line `render_always = true`.

Replace:

```
tag_pattern = '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
```

with:

```
tag_pattern = '^v[0-9]+\.[0-9]+\.[0-9]+$'
```

Leave everything else in `cliff.toml` unchanged.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mise exec -- python3 -B -m unittest discover -s scripts/tests -v`
Expected: `Ran 8 tests` … `OK`.

- [ ] **Step 8: Dry-run against the real history**

This proves the case the fixtures model: the real `v1.0.0` sits on a commit outside `include_paths`.

```bash
root=$PWD; d=$(mktemp -d)
git clone -q "$root" "$d/r"
cd "$d/r" && git checkout -q v1.0.0 && cp "$root/cliff.toml" . && mise trust -q .
GITHUB_OUTPUT="$d/out" mise exec -- "$root/scripts/plan-release.sh" "$d/notes.md"; cat "$d/out"
echo x >> Bopify/Bopify/BopifyApp.swift
GIT_CONFIG_GLOBAL=/dev/null git -c user.name=t -c user.email=t@t commit -qam "fix: simulated app fix"
GITHUB_OUTPUT="$d/out2" mise exec -- "$root/scripts/plan-release.sh" "$d/notes.md"; cat "$d/out2"; tail -n 1 "$d/notes.md"
cd "$root"
```

Expected: the first run prints `No user-facing app changes since v1.0.0; skipping release.` and `release=false`. The second prints `release=true`, `tag=v1.0.1`, `version=1.0.1`, and the notes end with `compare/v1.0.0...v1.0.1)`. If `Bopify/Bopify/BopifyApp.swift` doesn't exist, append to any `.swift` file under `Bopify/Bopify/`.

- [ ] **Step 9: Point the workflow's `plan` job at the script**

In `.github/workflows/release.yml`, rename the job and its step. Replace:

```yaml
  prepare:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    outputs:
      release: ${{ steps.release.outputs.release }}
      version: ${{ steps.release.outputs.version }}
      tag: ${{ steps.release.outputs.tag }}
```

with:

```yaml
  plan:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    outputs:
      release: ${{ steps.plan.outputs.release }}
      version: ${{ steps.plan.outputs.version }}
      tag: ${{ steps.plan.outputs.tag }}
```

Replace:

```yaml
      - name: Prepare app release
        id: release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          previous_tag=$(gh release list --exclude-drafts --exclude-pre-releases --limit 1 \
            --json tagName --jq '.[0].tagName')
          python3 scripts/prepare-release.py "$previous_tag" build/release/notes.md
      - name: Upload release notes
        if: steps.release.outputs.release == 'true'
```

with:

```yaml
      - name: Plan app release
        id: plan
        run: ./scripts/plan-release.sh build/release/notes.md
      - name: Upload release notes
        if: steps.plan.outputs.release == 'true'
```

Then, in the `build` job, change `needs: prepare` to `needs: plan`, and replace every `needs.prepare.` with `needs.plan.`. That covers five places: `if`, the two `outputs` values, the `RELEASE_VERSION` env, and the DMG upload path. Leave the rest of the `build` and `publish` jobs alone; Task 2 rewrites them.

Check: `rg -n 'prepare' .github/workflows/release.yml` prints nothing.

- [ ] **Step 10: Rewrite the README Releases section**

In `README.md`, replace the two paragraphs under `## Releases` (lines 42–44) with:

```markdown
Pushes to `main` release automatically when they bring user-facing app changes: a `feat:`, `fix:`, `perf:`, `revert:`, or breaking Conventional Commit touching the shipped app inputs listed in `cliff.toml`. Website, documentation, agent instructions, and test-only changes never release the app, and other commit types such as `chore:`, `refactor:`, and `build:` wait for the next release.

`feat:` bumps the minor version, `fix:`, `perf:`, and `revert:` bump the patch, and `!` or a `BREAKING CHANGE:` footer bumps the major. To ship a dependency update on its own, commit it as `fix(deps):`. Release notes list user-facing commit subjects since the last release and keep breaking upgrade instructions.
```

- [ ] **Step 11: Lint**

```bash
, shellcheck scripts/plan-release.sh
, actionlint -ignore 'unexpected key "queue"' -ignore 'label "(xcode-27|ubuntu-26\.04)" is unknown' .github/workflows/release.yml
```

Expected: both exit 0 with no output, apart from Nix `warning: unknown setting` lines. The three ignored findings already exist on `main` and pass on GitHub: nixpkgs actionlint 1.7.12 doesn't know `concurrency.queue`, the `xcode-27` runner or the `ubuntu-26.04` image.

- [ ] **Step 12: Commit**

```bash
git add scripts/plan-release.sh scripts/tests/test_plan_release.py cliff.toml .github/workflows/release.yml README.md
git commit -F - <<'EOF'
ci: release only for user-facing app commits

Let git-cliff decide whether a push releases and which version it gets:
a release needs at least one feat, fix, perf, revert or breaking commit
touching shipped app paths. Internal app commits wait for the next
release instead of producing maintenance releases.

Replace prepare-release.py with a short script around one git-cliff
query, and accept only stable tags as release boundaries.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 2: Publish with `gh`

**Files:**
- Modify: `.github/workflows/release.yml` (`build` outputs, notes download, DMG artifact; whole `publish` job)

**Interfaces:**
- Consumes: job `plan` outputs `tag` and `version`; artifact `release-notes` (`notes.md`), from Task 1.
- Produces: artifact `verified-dmg` containing only `Bopify-<version>.dmg`; a published GitHub release `<tag>` at `$GITHUB_SHA` with the DMG attached.

- [ ] **Step 1: Stop passing release data through `build`**

In the `build` job, delete:

```yaml
    outputs:
      version: ${{ needs.plan.outputs.version }}
      tag: ${{ needs.plan.outputs.tag }}
```

Delete the notes download step:

```yaml
      - name: Download release notes
        uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: release-notes
          path: build/release
```

In "Upload verified DMG", replace:

```yaml
          path: |
            build/release/Bopify-${{ needs.plan.outputs.version }}.dmg
            build/release/notes.md
```

with:

```yaml
          path: build/release/Bopify-${{ needs.plan.outputs.version }}.dmg
```

- [ ] **Step 2: Replace the `publish` job**

Replace the whole `publish:` job, from `  publish:` to the end of the file, with:

```yaml
  publish:
    needs: [plan, build]
    runs-on: ubuntu-26.04
    timeout-minutes: 15
    permissions:
      contents: write
    env:
      GH_TOKEN: ${{ github.token }}
      GH_REPO: ${{ github.repository }}
      TAG: ${{ needs.plan.outputs.tag }}
      VERSION: ${{ needs.plan.outputs.version }}
    steps:
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          path: release
          merge-multiple: true
      - name: Publish release
        # gh drafts the release, uploads the DMG, then publishes; it deletes the draft on failure.
        run: >-
          gh release create "$TAG" "release/Bopify-$VERSION.dmg"
          --target "$GITHUB_SHA" --title "Bopify $VERSION" --notes-file release/notes.md
```

With no `name`, download-artifact fetches every artifact of the run, which is just `release-notes` and `verified-dmg`. `merge-multiple` puts `notes.md` and the DMG together in `release/`.

- [ ] **Step 3: Verify the workflow**

```bash
rg -n 'ncipollo|needs\.build\.outputs|prepare' .github/workflows/release.yml
, actionlint -ignore 'unexpected key "queue"' -ignore 'label "(xcode-27|ubuntu-26\.04)" is unknown' .github/workflows/release.yml
mise exec -- python3 -B -m unittest discover -s scripts/tests -v
```

Expected: `rg` prints nothing; actionlint exits 0; `Ran 8 tests` … `OK`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -F - <<'EOF'
ci: publish releases with gh instead of release-action

Replace the two-step ncipollo/release-action draft and publish with one
gh release create, which drafts, uploads, publishes and cleans up a
failed draft itself. Publishing reads version and notes straight from
the plan job, so the macOS build no longer relays them.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

## After the tasks

The workflow can only be proved end to end on GitHub. Merging the branch into `main` is itself a push with only `ci:`/`docs:` commits, so `plan` should log `No user-facing app changes since v1.0.0; skipping release.` and `build`/`publish` should be skipped. Check with `gh run list --workflow release.yml --limit 1` and `gh run view <id> --log | rg 'No user-facing'`. The first `feat:`/`fix:` app commit afterwards is the real publish test: expect a `v1.0.1` or `v1.1.0` release with the DMG attached (`gh release view`). Merging and pushing are the user's call. Use superpowers:finishing-a-development-branch.

Before merging: the main checkout has uncommitted edits to `scripts/prepare-release.py` and `scripts/tests/test_prepare_release.py`, and this branch deletes both files, so `git merge` will refuse with "local changes would be overwritten". The user agreed those edits are superseded, but discarding them is still their action (`git restore scripts/prepare-release.py scripts/tests/test_prepare_release.py`). Ask before running it. The uncommitted Swift edits are unaffected.
