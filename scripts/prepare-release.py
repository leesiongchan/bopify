#!/usr/bin/env python3
"""Prepare a release from shipped inputs since the latest published tag."""

import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def prepare(previous, notes_path):
    config = tomllib.loads(Path("cliff.toml").read_text())
    initial = config["bump"]["initial_tag"]
    if not re.fullmatch(r"v\d+\.\d+\.\d+", previous):
        raise ValueError(f"Expected a published stable version tag, got {previous!r}")
    subprocess.run(["git", "merge-base", "--is-ancestor", previous, "HEAD"], check=True)
    promote = tuple(map(int, previous[1:].split("."))) < tuple(map(int, initial[1:].split(".")))
    paths = [f":(glob){path}" for path in config["git"]["include_paths"]]
    diff = subprocess.run(["git", "diff", "--quiet", previous, "HEAD", "--", *paths])
    if diff.returncode not in (0, 1):
        diff.check_returncode()
    if diff.returncode == 0 and not promote:
        print(f"No shipped app inputs changed since {previous}; skipping release.")
        return {"release": "false"}

    # Draft tags can exist after a failed publish; only the published tag is a boundary.
    cliff = ["git-cliff", "--config", "cliff.toml", "--no-exec", "--offline",
             "--count-tags", f"^{re.escape(previous)}$", f"{previous}..HEAD"]
    tag = initial if promote else run(*cliff, "--bumped-version")
    if tag == previous:
        tag = run(*cliff, "--bump", "patch", "--bumped-version")
    head = run("git", "rev-parse", "HEAD")
    tags = run("git", "tag", "--list").splitlines()
    while tag in tags and run("git", "rev-parse", f"{tag}^{{commit}}") != head:
        major, minor, patch = map(int, tag.removeprefix("v").split("."))
        tag = f"v{major}.{minor}.{patch + 1}"
    notes = run(*cliff, "--tag", tag)
    if promote:
        notes = f"Bopify {tag[1:]} marks the first stable release.\n\n{notes}"
    notes_path.parent.mkdir(parents=True, exist_ok=True)
    notes_path.write_text(notes + "\n")
    print(f"Prepared {tag} from app changes since {previous}.")
    return {"release": "true", "version": tag.removeprefix("v"), "tag": tag}


if __name__ == "__main__":
    outputs = prepare(sys.argv[1], Path(sys.argv[2]))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for key, value in outputs.items():
            output.write(f"{key}={value}\n")
