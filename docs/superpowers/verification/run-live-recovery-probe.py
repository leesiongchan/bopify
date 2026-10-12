# Uses the saved playback grant and real Spotify sessions; controls only its own engines.
from pathlib import Path
import argparse
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--derived-data", required=True)
parser.add_argument("--output", required=True)
mode = parser.add_mutually_exclusive_group()
mode.add_argument("--cleanup-check", action="store_true")
mode.add_argument("--physical-check", action="store_true")
options = parser.parse_args()
root = Path(__file__).resolve().parents[3]
products = Path(options.derived_data).resolve() / "Build/Products/Debug"
output = Path(options.output).resolve()
output.mkdir(parents=True, exist_ok=True)
binary = output / "LivePlaybackRecoveryProbe"
args = ["swiftc", "-parse-as-library", "-swift-version", "6", "-default-isolation", "MainActor",
        "-target", "arm64-apple-macos26.0", "-I", str(products),
        "-I", str(root / "Packages/BopifyCore/Sources/CBopifyCore/include"),
        "-L", str(products), "-lbopify_core", "-liconv", "-lobjc"]
for framework in ["AudioToolbox", "CoreAudio", "IOKit", "CoreFoundation", "Foundation", "SystemConfiguration", "Security", "AppKit", "Network"]:
    args += ["-framework", framework]
args += [str(root / "docs/superpowers/verification/LivePlaybackRecoveryProbe.swift")]
args += [str(root / "Bopify/Bopify/PlaybackConnectionMonitor.swift")]
args += [str(products / (name + ".o")) for name in ["BopifyDomain", "BopifyPlayback", "BopifyAuth", "CBopifyCore"]]
args += ["-o", str(binary)]
subprocess.run(args, check=True)
# A certificate-backed identity keeps Keychain approval valid across rebuilds.
print("Signing live recovery probe with Apple Development", flush=True)
subprocess.run(["codesign", "--force", "--sign", "Apple Development", "--identifier",
                "com.leesiongchan.bopify.live-playback-recovery-probe", str(binary)], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True)
sys.exit(subprocess.run([str(binary)] + (["--cleanup-check"] if options.cleanup_check else [])
                       + (["--physical-check"] if options.physical_check else [])).returncode)
