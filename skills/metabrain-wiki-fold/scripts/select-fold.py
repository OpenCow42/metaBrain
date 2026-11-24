#!/usr/bin/env python3
"""Select source revisions for a wiki fold and look for an existing summary."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


OPERATION = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\.md", re.IGNORECASE)
DEFAULT_COUNT = 16


def select(run, project, start, through):
    prefix = project + "/_wiki/operations/"
    times = {row["path"]: row["createdAt"] for row in run("list", prefix.rstrip("/"))
             if "documentID" in row and row["path"].startswith(prefix)
             and OPERATION.fullmatch(row["path"][len(prefix):])}
    notes = [note for note in run("dump", prefix.rstrip("/"))
             if note["isCurrent"] and note["path"] in times]
    raw = sorted(
        (note for note in notes if note["metadata"].get("wiki-operation") != "fold"),
        key=lambda note: (times[note["path"]], note["path"]),
    )
    if start is None:
        selected = raw[-DEFAULT_COUNT:]
        shortfall = DEFAULT_COUNT - len(selected)
    else:
        paths = [note["path"] for note in raw]
        if start not in paths or through not in paths or paths.index(start) > paths.index(through):
            raise ValueError("Use two ordered raw operation paths from the selected project")
        selected = raw[paths.index(start):paths.index(through) + 1]
        shortfall = 0
    result = {"entries": selected, "shortfall": shortfall}
    if shortfall:
        return {**result, "state": "shortfall"}
    if selected:
        revisions = [[note["documentID"], note["version"]] for note in selected]
        sources = json.dumps(revisions, separators=(",", ":"))
        digest = hashlib.sha256(sources.encode("utf-8")).hexdigest()
        path = f"{project}/_wiki/folds/{digest}.md"
        occupied = run("dump", path)
        summary = next((note for note in occupied if note["path"] == path and note["isCurrent"]), None)
        records = [note for note in notes if note["metadata"].get("wiki-fold") == digest]
        record_path = records[0]["path"] if len(records) == 1 else None
        index_path = f"{project}/index.md"
        recent_path = f"{project}/_wiki/recent.md"
        index_edges = run("links", index_path)
        recent_edges = run("links", recent_path)

        def resolved(edges, destination):
            return any(edge["status"] == "resolved" and edge.get("targetPath") == destination for edge in edges)

        complete = (summary and summary["metadata"].get("wiki-fold") == digest
                    and summary["metadata"].get("wiki-fold-sources") == sources
                    and record_path and records[0]["metadata"].get("wiki-operation") == "fold"
                    and resolved(run("links", record_path), path)
                    and resolved(index_edges, path) and resolved(recent_edges, record_path))
        traces = occupied or records or any(edge["destination"].split("#")[0] == path for edge in index_edges)
        state = "complete" if complete else "conflict" if traces else "new"
        result.update(digest=digest, path=path, sources=sources, state=state,
                      records=sorted(note["path"] for note in records))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mb", default="mb")
    parser.add_argument("--store", required=True)
    connection = parser.add_mutually_exclusive_group(required=True)
    connection.add_argument("--no-server", action="store_true")
    connection.add_argument("--server")
    parser.add_argument("--project", required=True)
    parser.add_argument("--from", dest="start")
    parser.add_argument("--through")
    args = parser.parse_args()
    if not Path(args.store).is_dir():
        parser.error("select an existing store directory")
    if not args.project.startswith("/") or any(part in ("", ".", "..") for part in args.project.split("/")[1:]):
        parser.error("use a normalized project root below /")
    if (args.start is None) != (args.through is None):
        parser.error("provide both --from and --through")
    command = [args.mb, "--store", args.store]
    command += ["--no-server"] if args.no_server else ["--server", args.server]

    def run(*arguments):
        result = subprocess.run([*command, *arguments, "--format", "json"], capture_output=True, text=True)
        if result.returncode:
            raise ValueError(result.stderr.strip() or "mb command failed")
        return json.loads(result.stdout)

    try:
        print(json.dumps(select(run, args.project, args.start, args.through), sort_keys=True))
    except (KeyError, OSError, TypeError, ValueError) as error:
        parser.exit(1, f"Unable to select fold sources: {error}\n")


if __name__ == "__main__":
    main()
