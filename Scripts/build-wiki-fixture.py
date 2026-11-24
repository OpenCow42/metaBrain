#!/usr/bin/env python3
"""Create an isolated acceptance store for project wiki skills."""

import argparse
import json
import shutil
import subprocess
import uuid
from pathlib import Path


PROJECT = "/projects/storage-review"
DECOY = "/projects/storage-review-other"
GLOBAL_GUIDE = "# Store guide\n\nUse the explicitly selected project.\n"
PROJECT_GUIDE = "# Storage review guide\n\nRetain minority opinions in decisions.\n"
INDEX = "# Storage review\n\nCustom project navigation for the architecture team.\n"
REVIEWS = {
    "field-review": "# Field design review\n\nOffline storage keeps the client readable off-network. ^result\n",
    "security-review": "# Security design review\n\nServer-only storage limits persistent client exposure. ^result\n",
}
ORIGINAL = bytes.fromhex("00 ff fe 80 4d 42 0a 00 10")


def note(name, body, **fields):
    return {
        "path": {"rawValue": f"{PROJECT}/{name}"},
        "body": body,
        "tags": [],
        "metadata": {},
        "references": [],
        **fields,
    }


def run_mb(cli, *args):
    return subprocess.run([*cli, *args], check=True, capture_output=True).stdout


def build_fixture(directory, mb, state):
    store = directory / "store.leveldb"
    cli = [mb, "--store", str(store), "--no-server"]
    capture_dir = directory / "originals"
    capture_dir.mkdir()
    run_mb(cli, "init", "--empty")
    run_mb(cli, "put", "/AGENTS.md", GLOBAL_GUIDE, "--if-version", "0")
    run_mb(cli, "put", f"{DECOY}/review.md", "Offline storage decoy. ^result", "--if-version", "0")
    captured = []
    for name, body in REVIEWS.items():
        original = capture_dir / f"{name}.md"
        original.write_text(body, encoding="utf-8")
        captured.append((original, body, "text/markdown"))
    binary = capture_dir / "opaque.bin"
    binary.write_bytes(ORIGINAL)
    captured.append((binary, "", "application/octet-stream"))
    if state == "empty":
        return store

    documents = [note("AGENTS.md", PROJECT_GUIDE), note("index.md", INDEX)]
    for original, body, media_type in captured:
        capture = json.loads(run_mb(
            cli, "source", "stage", str(original), "--origin",
            f"Acceptance fixture {original.name}", "--media-type", media_type
        ))
        path = f"{original.stem}.md"
        if body:
            path = f"reviews/{path}"
        documents.append(note(path, body, sourceCapture=capture))

    board = {
        "nodes": [
            {"id": "decision", "type": "file", "file": "decision.md",
             "x": 0, "y": 0, "width": 240, "height": 140},
            {"id": "field", "type": "file", "file": "reviews/field-review.md",
             "x": -300, "y": 0, "width": 240, "height": 140},
        ],
        "edges": [{"id": "evidence", "fromNode": "field", "toNode": "decision"}],
    }
    saved_view = """filters:
  and:
    - 'file.hasTag("decision")'
views:
  - type: table
    name: Decisions
    order:
      - file.name
      - status
    limit: 10
"""
    documents.extend([
        note("decision.md", "---\nstatus: contested\n---\n\n# Storage decision\n\n"
             f"[[{PROJECT}/reviews/field-review.md#^result]] supports an offline copy. "
             f"[[{PROJECT}/reviews/security-review.md#^result]] favors server-only storage.\n",
             tags=["decision"], metadata={"status": "contested"}),
        note("storage.canvas", json.dumps(board, indent=2) + "\n"),
        note("decisions.base", saved_view),
    ])
    operation_id = str(uuid.uuid4())
    if state == "initialized":
        record = f"_wiki/operations/{operation_id}.md"
        documents.extend([
            note("_wiki/config.json", '{"version":1,"mode":"generic"}\n'),
            note("_wiki/recent.md", f"# Recent activity\n\n[[{PROJECT}/{record}]]\n"),
            note(record, f"# {operation_id}\n\nSeeded the acceptance fixture. [[{PROJECT}/decision.md]]\n"),
        ])
    draft = directory / "fixture-operation.json"
    preview_file = directory / "fixture-preview.json"
    operation = {"operationID": operation_id, "project": {"rawValue": PROJECT}, "documents": documents}
    draft.write_text(json.dumps(operation), encoding="utf-8")
    first_preview = json.loads(run_mb(cli, "operation", "inspect", str(draft)))
    ids = {item["path"]["rawValue"]: item["documentID"]["rawValue"] for item in first_preview["creations"]}
    decision = next(document for document in documents if document["path"]["rawValue"] == f"{PROJECT}/decision.md")
    decision["claims"] = [{
        "id": str(uuid.uuid4()),
        "text": "This client should keep an offline copy.",
        "state": "contested",
        "highRisk": False,
        "evidence": [
            {"relation": relation, "ref": f"{ids[f'{PROJECT}/reviews/{name}.md']}@1#^result"}
            for name, relation in zip(REVIEWS, ("supports", "contradicts"))
        ],
    }]
    draft.write_text(json.dumps(operation), encoding="utf-8")
    preview_file.write_bytes(run_mb(cli, "operation", "inspect", str(draft)))
    run_mb(cli, "operation", "apply", str(preview_file))
    return store


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True, help="New, disposable output directory")
    parser.add_argument("--mb", default="mb", help="mb executable path")
    parser.add_argument("--state", choices=("empty", "adopt", "initialized"), default="adopt")
    args = parser.parse_args()
    directory = args.directory.resolve()
    try:
        directory.mkdir()
        try:
            store = build_fixture(directory, args.mb, args.state)
        except (OSError, subprocess.CalledProcessError, KeyboardInterrupt):
            shutil.rmtree(directory)
            raise
    except subprocess.CalledProcessError as error:
        parser.exit(1, error.stderr.decode(errors="replace"))
    except OSError as error:
        parser.exit(1, f"{error}\n")
    print(json.dumps({"store": str(store), "project": PROJECT, "decoy": DECOY, "state": args.state}))


if __name__ == "__main__":
    main()
