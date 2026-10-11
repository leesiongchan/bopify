#!/usr/bin/env python3
"""Join app update markers to shared compositor frame intervals, never isolated app cost."""
import argparse
import json
import math
import statistics
import xml.etree.ElementTree as ET
from collections import Counter


def load(path):
    root = ET.parse(path).getroot()
    refs = {e.get("id"): e for e in root.iter() if e.get("id")}
    cols = [e.text for e in root.findall(".//schema/col/mnemonic")]
    rows = []
    for row in root.findall(".//row"):
        values = {}
        for col, elem in zip(cols, row):
            value = refs.get(elem.get("ref"), elem)
            values[col] = value.text if value.text is not None else value.get("fmt")
            if col == "process":
                child = value.find("pid")
                if child is not None:
                    values["process_pid"] = int(refs.get(child.get("ref"), child).text)
        rows.append(values)
    return rows


def frame_key(row):
    return row["display"], row["swap-id"], row["surface-id"]


def distribution(rows):
    values = sorted(int(row["duration"]) / 1e6 for row in rows)
    if not values:
        return {"frames": 0}
    return {"frames": len(values), "mean_ms": statistics.mean(values), "median_ms": statistics.median(values), "p95_ms": values[min(len(values) - 1, math.ceil(.95 * len(values)) - 1)], "max_ms": max(values)}


def analyze(updates, gpu, renders, hitches, pid, start_s, end_s):
    start, end = int(start_s * 1e9), int(end_s * 1e9)
    in_range = lambda r: start <= int(r["start"]) < end
    updates = [r for r in load(updates) if r["containment-level"] == "0" and r.get("process_pid") == pid and in_range(r)]
    keys = {frame_key(r) for r in updates}
    result = {"process_pid": pid, "measurement": "shared compositor frame GPU associated with app updates", "window_seconds": [start_s, end_s], "top_level_update_rows": len(updates), "unique_update_frame_keys": len(keys)}
    for name, path in [("gpu", gpu), ("renders", renders)]:
        rows = [r for r in load(path) if r["containment-level"] == "0" and in_range(r)]
        by_key = {frame_key(r): r for r in rows}
        if len(by_key) != len(rows):
            raise ValueError("Multiple top-level intervals per compositor frame")
        joined = [r for key, r in by_key.items() if key in keys]
        result[name] = {"all_compositor_frames": len(rows), "diagnostic": ("joined" if joined else "No app-associated intervals; attribution unavailable"), "frame_values": [{"display": r["display"], "swap_id": int(r["swap-id"]), "surface_id": int(r["surface-id"]), "start_ns": int(r["start"]), "duration_ms": int(r["duration"]) / 1e6} for r in joined], "associated": distribution(joined), "unjoined_update_frame_keys": len(keys - set(by_key)), "by_display": {display: distribution([r for r in joined if r["display"] == display]) for display in sorted({r["display"] for r in joined})}}
    hit_rows = [r for r in load(hitches) if r.get("process_pid") == pid and r["is-system"] == "0" and in_range(r)]
    result["hitches"] = {"count": len(hit_rows), "total_duration_ms": sum(int(r["duration"]) / 1e6 for r in hit_rows), "descriptions": dict(Counter(r["narrative-description"] or "unspecified" for r in hit_rows)), "by_display": {display: distribution([r for r in hit_rows if r["display"] == display]) for display in sorted({r["display"] for r in hit_rows})}}
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ["updates", "gpu", "renders", "hitches"]:
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--start", type=float, default=2)
    parser.add_argument("--end", type=float, default=12)
    args = parser.parse_args()
    print(json.dumps(analyze(args.updates, args.gpu, args.renders, args.hitches, args.pid, args.start, args.end), indent=2))
