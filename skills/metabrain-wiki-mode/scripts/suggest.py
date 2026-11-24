#!/usr/bin/env python3
"""Suggest a virtual destination using a config body read from the store."""

import argparse
from datetime import datetime, timezone
import json
import re
import sys
import uuid


MODES = ("generic", "lyt", "para", "zettelkasten")
GENERIC = {
    "note": "notes", "source": "sources", "decision": "decisions", "map": "maps",
    "concept": "concepts", "entity": "entities", "session": "sessions",
}
PARA = {"project": "projects", "area": "areas", "resource": "resources", "archive": "archives"}


def parse_config(body):
    def unique_object(items):
        result = dict(items)
        if len(result) != len(items):
            raise ValueError("Duplicate configuration key")
        return result

    def reject_constant(value):
        raise ValueError(f"Invalid JSON constant {value}")

    config = json.loads(body, object_pairs_hook=unique_object, parse_constant=reject_constant)
    if (not isinstance(config, dict) or type(config.get("version")) is not int or config["version"] != 1
            or config.get("mode") not in MODES):
        raise ValueError("Expected wiki configuration version 1 with a recognized mode")
    return config


def destination(root, mode, slug, kind, actionability):
    if mode == "generic":
        folder = GENERIC[kind]
    elif mode == "lyt":
        folder = "maps" if kind == "map" else "sources" if kind == "source" else "notes"
    elif mode == "para":
        if actionability is None:
            raise ValueError("PARA requires an actionability choice")
        folder = PARA[actionability]
    else:
        if kind in ("note", "concept"):
            timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
            slug = f"{timestamp}-{uuid.uuid4().hex}-{slug}"
        folder = "zettels" if kind in ("note", "concept") else GENERIC[kind]
    return f"{root}/{folder}/{slug}.md"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--config-stdin", action="store_true", help="Read an existing config body as JSON")
    source.add_argument("--absent-config", action="store_true", help="Use only after verifying absence")
    parser.add_argument("--slug", required=True)
    parser.add_argument("--kind", choices=tuple(GENERIC), default="note")
    parser.add_argument("--actionability", choices=tuple(PARA))
    args = parser.parse_args()
    if not args.project.startswith("/") or any(part in ("", ".", "..") for part in args.project.split("/")[1:]):
        parser.error("use a normalized project root below /")
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", args.slug):
        parser.error("use a lowercase hyphenated slug")
    try:
        mode = parse_config(sys.stdin.read())["mode"] if args.config_stdin else "generic"
        path = destination(args.project, mode, args.slug, args.kind, args.actionability)
        print(json.dumps({"mode": mode, "path": path}))
    except ValueError as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
