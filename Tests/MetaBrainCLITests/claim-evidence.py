"""Commit and recover opposing claim evidence through direct or daemon CLI."""
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


def read(*args):
    return json.loads(run(*args))


def write_operation(operation):
    spec.write_text(json.dumps(operation), encoding="utf-8")


def document(path, body, **fields):
    return {
        "path": {"rawValue": path}, "body": body,
        "tags": [], "metadata": {}, "references": [], **fields,
    }


def findings(claim_id):
    report = read("lint", project)
    return [finding for finding in report["findings"]
            if finding["kind"] == "claimEvidence" and finding["claimID"].lower() == claim_id]


project = "/projects/atlas"
spec = store.parent / "operation.json"
preview_file = store.parent / "preview.json"
owner = f"{project}/decision"
first = f"{project}/local.md"
second = f"{project}/replicated.md"
first_body = "Prefer local storage to keep working offline."
second_body = "Require replication to survive machine loss."
run("init", "--empty")

reviews = []
for path, text, group in [(first, first_body, "team-a"), (second, second_body, "team-b")]:
    original = store.parent / Path(path).name
    original.write_text(text, encoding="utf-8")
    capture = read("source", "stage", original, "--origin", group, "--media-type", "text/plain")
    reviews.append(document(path, text + " ^evidence", sourceCapture=capture, sourceProfile={
        "status": "active", "synthetic": False, "independenceGroup": group, "freshUntil": "2099-01-01T00:00:00Z",
    }))

operation = {
    "operationID": str(uuid.uuid4()),
    "project": {"rawValue": project},
    "documents": [document(owner, "The reviewers disagree."), *reviews],
}
write_operation(operation)
inspected = read("operation", "inspect", spec)
ids = {
    target["path"]["rawValue"]: target["documentID"]["rawValue"]
    for target in inspected["creations"]
}
first_ref = f"{ids[first]}@1#^evidence"
second_ref = f"{ids[second]}@1#^evidence"
claim_id = str(uuid.uuid4())
claim = {
    "id": claim_id, "text": "Local storage should be preferred.", "state": "contested", "highRisk": False,
    "evidence": [{"relation": "supports", "ref": first_ref}, {"relation": "contradicts", "ref": second_ref}],
}
operation["documents"][0]["claims"] = [claim]
write_operation(operation)
preview_file.write_bytes(run("operation", "inspect", spec))
run("get", owner, ok=False)
receipt = run("operation", "apply", preview_file)
assert run("operation", "apply", preview_file) == receipt
decision = read("get", owner, "--format", "json")
assert decision["claims"][0]["id"].lower() == claim_id
assert decision["claims"][0]["state"] == "contested"
assert decision["claims"][0]["evidence"] == claim["evidence"]

assert read("get", "--ref", first_ref)["items"][0]["text"] == first_body
assert read("get", "--ref", second_ref)["items"][0]["text"] == second_body
assert findings(claim_id) == []

run("put", first, "Recommendation updated. ^evidence")
moved = f"{project}/archive/local.md"
run("move", first, moved)
assert read("get", "--id", ids[first], "--format", "json")["path"] == moved
assert read("get", "--ref", first_ref)["items"][0]["text"] == first_body
before_prune = findings(claim_id)
assert before_prune and any(finding["evidenceRef"] == first_ref for finding in before_prune), before_prune
run("remove-version", "--id", ids[first], "--sequence", "1")
run("get", "--ref", first_ref, ok=False)
after_prune = findings(claim_id)
assert after_prune != before_prune and any(finding["evidenceRef"] == first_ref for finding in after_prune), after_prune
