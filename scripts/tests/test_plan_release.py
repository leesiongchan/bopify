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
        result = subprocess.run(
            [str(ROOT / "scripts/plan-release.sh"), str(notes)],
            cwd=self.repo, env=dict(self.env, GITHUB_OUTPUT=str(output)),
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
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
                        "build(deps): bump librespot", "Update internal implementation",
                        'Revert "chore: tidy player"']:
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
                                 ('Revert "feat: search music"', "1.0.1"),
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

    def test_git_default_revert_of_a_feature_is_in_the_notes(self):
        self.commit("Bopify/Bopify/App.swift", "search", "feat: search music")
        self.commit("Bopify/Bopify/App.swift", "reverted", 'Revert "feat: search music"')
        values, notes = self.plan()
        self.assertEqual(values["tag"], "v1.1.0")
        self.assertIn("Search music", notes)
        self.assertIn('Revert "feat: search music"', notes)

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
