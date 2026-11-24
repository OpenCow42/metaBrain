"""Exercise capture, reviewed attachment, and exact export in both connection modes."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import uuid

store = Path(sys.argv[1])
store.parent.mkdir(parents=True)
command = [*sys.argv[2:], "--store", str(store)]


def run(*args, ok=True):
    result = subprocess.run([*command, *map(str, args)], capture_output=True)
    if ok:
        assert result.returncode == 0, (args, result.stderr.decode())
    else:
        assert result.returncode != 0, args
    return result.stdout


def write_json(file, value):
    file.write_text(json.dumps(value), encoding="utf-8")


original = store.parent / "design-review.bin"
original_bytes = hashlib.shake_256(b"metaBrain capture fixture").digest(17 * 1024 * 1024 + 7)
original.write_bytes(original_bytes)
exported = store.parent / "exported.bin"
project = "/projects/demo"
path = f"{project}/review"
moved = f"{project}/archive/review"
run("init", "--empty")
capture = json.loads(run("source", "stage", original, "--origin", "first design review", "--media-type", "application/octet-stream"))
assert capture == {
    "blob": {"byteCount": len(original_bytes), "sha256": hashlib.sha256(original_bytes).hexdigest()},
    "filename": original.name,
    "mediaType": "application/octet-stream",
    "origin": "first design review",
}, capture
empty = store.parent / "empty.bin"
empty.touch()
empty_capture = json.loads(run("source", "stage", empty, "--origin", "second review", "--extraction", "manual"))
assert empty_capture == {
    "blob": {"byteCount": 0, "sha256": hashlib.sha256(b"").hexdigest()},
    "filename": empty.name,
    "mediaType": "application/octet-stream",
    "origin": "second review",
    "extraction": "manual",
}, empty_capture
assert json.loads(run("list", "--format", "json")) == []
run("source", "export", path, "--version", "0", "--output", exported, ok=False)
run("source", "export", path, "--output", exported, ok=False)
assert not exported.exists()

operation_file = store.parent / "operation.json"
preview_file = store.parent / "preview.json"
write_json(operation_file, {
    "operationID": str(uuid.uuid4()),
    "project": {"rawValue": project},
    "documents": [
        {
            "path": {"rawValue": path},
            "body": "",
            "tags": [],
            "metadata": {},
            "references": [],
            "sourceCapture": capture,
        },
        {
            "path": {"rawValue": f"{project}/empty"},
            "body": "",
            "tags": [],
            "metadata": {},
            "references": [],
            "sourceCapture": empty_capture,
        },
    ],
})
preview_file.write_bytes(run("operation", "inspect", operation_file))
run("source", "export", path, "--output", exported, ok=False)
receipt = run("operation", "apply", preview_file)
assert run("operation", "apply", preview_file) == receipt
document_id = json.loads(receipt)["results"][0]["documentID"]["rawValue"]
run("source", "export", path, "--output", exported)
assert exported.read_bytes() == original_bytes
empty_output = store.parent / "exported-empty.bin"
run("source", "export", f"{project}/empty", "--output", empty_output)
assert empty_output.read_bytes() == b""

run("move", path, moved)
run("source", "export", "--id", document_id, "--version", "1", "--output", exported)
assert exported.read_bytes() == original_bytes
run("source", "export", moved, "--output", exported)
assert exported.read_bytes() == original_bytes
run("remove-version", "--id", document_id, "--sequence", "1")
previous_output = b"Existing output is preserved after a failed export."
exported.write_bytes(previous_output)
run("source", "export", "--id", document_id, "--version", "1", "--output", exported, ok=False)
assert exported.read_bytes() == previous_output
