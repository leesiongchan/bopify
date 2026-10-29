import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PrepareReleaseTests(unittest.TestCase):
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

    def prepare(self, previous="v1.0.0"):
        output = self.repo / "outputs"
        subprocess.run(
            ["python3", str(ROOT / "scripts/prepare-release.py"), previous,
             str(self.repo / "notes.md")],
            cwd=self.repo, env=dict(self.env, GITHUB_OUTPUT=str(output)),
            check=True, capture_output=True, text=True,
        )
        values = dict(line.split("=", 1) for line in output.read_text().splitlines())
        notes = self.repo / "notes.md"
        return values, notes.read_text() if notes.exists() else ""

    def test_unrelated_changes_skip(self):
        for path in ["site/index.html", "README.md", "AGENTS.md",
                     "Packages/BopifyCore/Tests/PlaybackTests/Test.swift",
                     "Bopify/BopifyAppTests/Test.swift",
                     "rust/crates/bopify-core/tests/test.rs",
                     ".github/workflows/release.yml"]:
            with self.subTest(path=path):
                self.commit(path, "changed", "feat: unrelated change")
                values, notes = self.prepare()
                self.assertEqual(values["release"], "false")
                self.assertEqual(notes, "")

    def test_fix_releases_once_and_excludes_website_feature(self):
        self.commit("site/index.html", "site", "feat: new product page")
        self.commit("Bopify/Bopify/App.swift", "fixed", "fix: retain artwork\n\nInternal implementation diary.")
        self.commit("Bopify/Bopify/App.swift", "fixed again", "fix: restore playback")
        values, notes = self.prepare()
        self.assertEqual(values["version"], "1.0.1")
        self.assertEqual(values["tag"], "v1.0.1")
        self.assertIn("Retain artwork", notes)
        self.assertIn("Restore playback", notes)
        self.assertNotIn("product page", notes)
        self.assertNotIn("implementation diary", notes)
        self.assertNotIn("## Bopify", notes)
        self.assertIn("v1.0.0...v1.0.1", notes)

    def test_feature_and_breaking_versions(self):
        self.commit("Packages/BopifyCore/Sources/BopifyDomain/Track.swift", "feature", "feat: search music")
        self.assertEqual(self.prepare()[0]["version"], "1.1.0")
        self.commit("Bopify/Bopify/App.swift", "breaking", "fix!: change setup\n\nBREAKING CHANGE: Sign in again.")
        values, notes = self.prepare()
        self.assertEqual(values["version"], "2.0.0")
        self.assertIn("**Upgrade:** Sign in again.", notes)

    def test_packaging_dependencies_and_resources_release(self):
        for path in ["rust/Cargo.lock", "rust/crates/bopify-core/build.rs",
                     "rust/crates/bopify-core/oslog_shim.c", "rust/about.hbs",
                     "Bopify/Bopify/Assets.xcassets/icon.png",
                     "Packages/BopifyCore/Package.resolved", "scripts/release.sh"]:
            with self.subTest(path=path):
                self.git("reset", "--hard", "v1.0.0")
                self.commit(path, "changed", "build: update shipped inputs")
                values, notes = self.prepare()
                self.assertEqual(values["release"], "true")
                self.assertEqual(values["version"], "1.0.1")
                self.assertNotIn("Update shipped inputs", notes)

    def test_failed_draft_tag_does_not_hide_pending_changes(self):
        self.commit("Bopify/Bopify/App.swift", "feature", "feat: search music")
        self.git("tag", "v1.1.0")
        values, notes = self.prepare()
        self.assertEqual(values["version"], "1.1.0")
        self.assertIn("Search music", notes)

    def test_failed_draft_at_old_commit_reserves_its_version(self):
        self.commit("Bopify/Bopify/App.swift", "feature", "feat: search music")
        self.git("tag", "v1.1.0")
        self.commit("Bopify/Bopify/App.swift", "fix", "fix: retain artwork")
        values, notes = self.prepare()
        self.assertEqual(values["version"], "1.1.1")
        self.assertIn("Search music", notes)
        self.assertIn("Retain artwork", notes)
        self.assertIn("v1.0.0...v1.1.1", notes)

    def test_reverted_app_change_skips(self):
        self.commit("Bopify/Bopify/App.swift", "temporary", "feat: temporary")
        self.commit("Bopify/Bopify/App.swift", "initial", "revert: remove temporary")
        self.assertEqual(self.prepare()[0]["release"], "false")

    def test_unconventional_app_commit_gets_maintenance_notes(self):
        self.commit("Bopify/Bopify/App.swift", "updated", "Update internal implementation")
        values, notes = self.prepare()
        self.assertEqual(values["version"], "1.0.1")
        self.assertNotIn("Other changes", notes)
        self.assertNotIn("Update internal implementation", notes)
        self.assertIn("Maintenance release", notes)

    def test_promote_existing_app_to_1_0_0(self):
        self.git("tag", "-d", "v1.0.0")
        self.git("tag", "v0.21.2")
        self.commit("site/index.html", "site", "feat: product page")
        values, notes = self.prepare("v0.21.2")
        self.assertEqual(values["version"], "1.0.0")
        self.assertIn("first stable release", notes)
        self.assertNotIn("Product page", notes)
        self.assertIn("v0.21.2...v1.0.0", notes)

    def test_unknown_published_tag_fails(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare("v9.9.9")


if __name__ == "__main__":
    unittest.main()
