"""Build the default campaign fact list from the game's quest and scene graphs.

The campaign host mirrors quest facts to its guests (see docs/CAMPAIGN.md). Which facts
matter is decided by the story data itself: every fact a quest or scene graph writes
with questSetVar_NodeType is story state. Facts that the graphs only read are written by
game code, often per player (vehicle, combat, UI), and are left out on purpose.

Usage (WolvenKit CLI 8.20+ for patch 2.31, https://github.com/WolvenKit/WolvenKit/releases):

    python tools/campaign/extract_facts.py --game "<Cyberpunk 2077>" \
        --wolvenkit <WolvenKit.CLI.exe> --work <empty scratch dir> \
        --out code/server/scripting/CampaignSystem/campaign_facts.txt

--skip-extract reuses the JSON already in --work.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

# Archives holding quest (.quest/.questphase) and scene (.scene) resources.
SOURCES = {
    "base": [
        "archive/pc/content/basegame_1_engine.archive",
        "archive/pc/content/basegame_3_nightcity.archive",
        "archive/pc/content/basegame_4_gamedata.archive",
    ],
    "ep1": [
        "archive/pc/ep1/ep1_1_nightcity.archive",
        "archive/pc/ep1/ep1_2_gamedata.archive",
    ],
}

RESOURCE_PATTERN = r"\.(quest|questphase|scene)$"

# Fields that hold a fact name, on quest* and scn* node and condition types.
FACT_FIELDS = ("factName", "factName1", "factName2")

WRITER_TYPES = {"questSetVar_NodeType"}

# Valid fact names; anything else is a placeholder or a broken reference.
FACT_NAME = re.compile(r"^[A-Za-z0-9_.]+$")

# Developer shortcuts (quest test definitions, debug switches) - never set in a real
# playthrough, and mirroring them could skip content. They can still be added by hand.
DEV_FACT = re.compile(r"(^|_)(debug|dbg|test|testdef|demo)(_|$|\d)", re.IGNORECASE)


def run(args):
    print(">", " ".join(str(a) for a in args), flush=True)
    result = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        sys.exit(f"command failed ({result.returncode}): {result.stderr[-2000:]}")


def extract(game, wolvenkit, work):
    for source, archives in SOURCES.items():
        raw = work / source
        raw.mkdir(parents=True, exist_ok=True)
        for archive in archives:
            path = game / archive
            if not path.exists():
                sys.exit(f"missing archive: {path}")
            run([wolvenkit, "unbundle", path, "-o", raw, "-r", RESOURCE_PATTERN, "-v", "Minimal"])
        # No -o: with an output directory WolvenKit flattens the tree and files that share
        # a name (many scenes do) overwrite each other. Without it each JSON lands beside
        # its resource.
        run([wolvenkit, "convert", "serialize", raw, "-v", "Minimal"])


def fact_name(value):
    if isinstance(value, dict):
        value = value.get("$value")
    if not isinstance(value, str):
        return None
    value = value.strip()
    if not value or value == "None" or not FACT_NAME.match(value):
        return None
    return value


def walk(node, found):
    if isinstance(node, dict):
        node_type = node.get("$type")
        if node_type:
            for field in FACT_FIELDS:
                if field in node:
                    name = fact_name(node[field])
                    if name:
                        found.append((name, node_type))
        for value in node.values():
            walk(value, found)
    elif isinstance(node, list):
        for value in node:
            walk(value, found)


def collect(work):
    # fact -> {"writers": set(type), "readers": set(type), "sources": set, "files": set}
    facts = defaultdict(lambda: {"writers": set(), "readers": set(), "sources": set(), "files": set()})
    for source in SOURCES:
        root = work / source
        files = sorted(root.rglob("*.json"))
        print(f"{source}: scanning {len(files)} files", flush=True)
        for path in files:
            try:
                with open(path, encoding="utf-8") as handle:
                    data = json.load(handle)
            except (OSError, ValueError) as error:
                print(f"  skipped {path}: {error}", file=sys.stderr)
                continue
            found = []
            walk(data, found)
            resource = path.relative_to(root).as_posix().removesuffix(".json")
            for name, node_type in found:
                entry = facts[name]
                (entry["writers"] if node_type in WRITER_TYPES else entry["readers"]).add(node_type)
                entry["sources"].add(source)
                entry["files"].add(resource)
    return facts


def write_list(facts, out):
    written = {name: entry for name, entry in facts.items() if entry["writers"] and not DEV_FACT.search(name)}
    dev = sum(1 for name, entry in facts.items() if entry["writers"] and DEV_FACT.search(name))
    groups = defaultdict(list)
    for name, entry in written.items():
        # A fact both expansions touch is base game state that ep1 also reads.
        groups["base" if "base" in entry["sources"] else "ep1"].append(name)

    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("# Quest facts mirrored from the campaign host to every guest.\n")
        handle.write("# One fact name per line. Lines starting with # are ignored.\n")
        handle.write("# Generated by tools/campaign/extract_facts.py: every fact a quest or\n")
        handle.write("# scene graph writes (questSetVar_NodeType), minus developer test/debug facts.\n")
        handle.write("# Built into the CampaignSystem plugin; local changes go in the server's\n")
        handle.write("# config/campaign_facts.txt.\n")
        for group, title in (("base", "Base game"), ("ep1", "Phantom Liberty")):
            names = sorted(groups[group], key=str.lower)
            handle.write(f"\n# ---- {title}: {len(names)} facts ----\n")
            for name in names:
                handle.write(name + "\n")

    read_only = len(facts) - len(written) - dev
    print(f"{len(facts)} facts referenced, {len(written)} written by story graphs, {dev} dev-only, {read_only} read only")
    print(f"base: {len(groups['base'])}, ep1: {len(groups['ep1'])} -> {out}")


def write_report(facts, path):
    rows = []
    for name in sorted(facts, key=str.lower):
        entry = facts[name]
        rows.append({
            "fact": name,
            "written": bool(entry["writers"]),
            "dev": bool(DEV_FACT.search(name)),
            "sources": sorted(entry["sources"]),
            "types": sorted(entry["writers"] | entry["readers"]),
            "files": sorted(entry["files"]),
        })
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(rows, handle, indent=1)
    print(f"report -> {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--game", type=Path, help="Cyberpunk 2077 install directory")
    parser.add_argument("--wolvenkit", type=Path, help="WolvenKit.CLI.exe")
    parser.add_argument("--work", type=Path, required=True, help="scratch directory for extracted files")
    parser.add_argument("--out", type=Path, required=True, help="fact list to write")
    parser.add_argument("--report", type=Path, help="optional JSON report: every fact with its files")
    parser.add_argument("--skip-extract", action="store_true", help="reuse the JSON already in --work")
    args = parser.parse_args()

    if not args.skip_extract:
        if not args.game or not args.wolvenkit:
            parser.error("--game and --wolvenkit are required unless --skip-extract is given")
        extract(args.game, args.wolvenkit, args.work)

    facts = collect(args.work)
    write_list(facts, args.out)
    if args.report:
        write_report(facts, args.report)


if __name__ == "__main__":
    main()
