"""Run the same CLI contract against a direct store or a live mbd endpoint."""
import json
from pathlib import Path
import subprocess
import sys

store = Path(sys.argv[1])
command = [*sys.argv[2:], "--store", str(store)]


def run(*args, ok=True):
    result = subprocess.run([*command, *args], capture_output=True)
    if ok:
        assert result.returncode == 0, (args, result.stderr.decode())
    else:
        assert result.returncode != 0, args
    return result.stdout


def read(*args):
    return json.loads(run(*args))


def occurrence_ref(link):
    return f'{link["sourceID"]}@{link["sourceVersion"]}#{link["start"]}-{link["end"]}'


def graph_refs(query, path, flag, field):
    results = read("search", query, "--path-prefix", path, flag, "--format", "json")
    assert results and all(result["path"] == path for result in results), results
    return [result[field] for result in results]


run("ensure-guide", ok=False)
assert not store.exists()
run("init", "--empty")
assert read("ensure-guide")["status"] == "created"
guide = read("get", "/AGENTS.md")
assert "--view evidence" in guide["body"] and "--view refs" in guide["body"]
assert read("ensure-guide")["version"] == 1
run("put", "/AGENTS.md", "Local instructions.")
assert read("ensure-guide")["status"] == "unchanged"
assert read("get", "/AGENTS.md")["body"] == "Local instructions."

decision = "/decisions/backups"
target = "/policies/Retention.md"
moved = "/archive/Retention-2026.md"
native_path = "/policies/Background"
native = read("put", native_path, "Supporting background for the decision.")
native_ref = {"kind": "documentID", "value": native["documentID"]}
prefix = "Cafe\u0301. Decision: follow "
link_markup = "[[Retention#^keep-last]]"
decision_body = prefix + link_markup + ". ^decision\n\nExample: `[[No such note]]`."
source = read("put", decision, decision_body, "--markdown", "--keep-all", "--ref-id", native["documentID"])
source_ref = {"kind": "documentID", "value": source["documentID"]}
stored_decision = read("get", decision)
assert stored_decision["markdown"] and stored_decision["body"] == decision_body
assert stored_decision["references"] == [native_ref]
assert read("dump", decision, "--versions", "--format", "json")[0]["markdown"]
pending = read("links", decision, "--block", "decision", "--format", "json")
assert len(pending) == 1 and pending[0]["status"] == "unresolved", pending
assert "targetID" not in pending[0] and "targetPath" not in pending[0], pending
assert read("links", decision, "--block", "missing", "--format", "json") == []
assert all(refs == [native_ref] for refs in graph_refs(
    "Decision", decision, "--include-linked-documents", "linkedDocuments"
))

# Keep the actual match far from the beginning of the document.
rule = "Keep the last seven nightly backups, except during migration."
policy = "---\ntags: [storage]\nstatus: draft\n---\n# Retention\n\n"
policy += "Routine maintenance details. " * 190 + "\n\n" + rule + " ^keep-last\n"
body_file = store.parent / "policy.md"
body_file.write_text(policy, encoding="utf-8")
first = read("put", target, "--body-file", str(body_file), "--keep-all")
resolved = read("links", decision, "--format", "json")
assert len(resolved) == 1 and resolved[0]["targetID"] == first["documentID"], resolved
assert resolved[0]["status"] == "resolved" and resolved[0]["sourceVersion"] == 1, resolved
# The decomposed e + acute accent in the prefix is one Swift Character.
assert resolved[0]["start"] == len("Café. Decision: follow ")
assert resolved[0]["end"] - resolved[0]["start"] == len(link_markup)
first_occurrence_ref = occurrence_ref(resolved[0])
expected_targets = {native["documentID"], first["documentID"]}
for refs in graph_refs("Decision", decision, "--include-linked-documents", "linkedDocuments"):
    assert len(refs) == 2 and {ref["value"] for ref in refs} == expected_targets, refs
for query, path in [("Supporting background", native_path), ("nightly backups", target)]:
    assert all(refs == [source_ref] for refs in graph_refs(query, path, "--include-backlinks", "backlinks"))
refs = read("search", "--view", "refs", "--tag", "storage", "--meta", "status=draft")
assert [item["path"] for item in refs["items"]] == [target], refs
assert all("text" not in item for item in refs["items"])
raw = run("search", "nightly backups", "--view", "evidence", "--max-tokens", "512", "--tag", "storage")
assert len(raw) <= 512
items = json.loads(raw)["items"]
assert len(items) == 1 and rule in items[0]["text"], items
ref = items[0]["ref"]
assert rule in read("get", "--ref", ref)["items"][0]["text"]
assert rule in read("get", target, "--heading", "Retention")["text"]
assert rule in read("get", target, "--block", "keep-last")["text"]
run("move", target, moved)
body_file.write_text(policy.replace("seven", "fourteen"), encoding="utf-8")
run("put", moved, "--body-file", str(body_file), "--body-only")
assert read("links", decision, "--format", "json")[0]["targetPath"] == moved
incoming = read("links", moved, "--incoming", "--block", "keep-last", "--format", "json")
assert len(incoming) == 1 and incoming[0]["sourcePath"] == decision, incoming
assert "follow" in incoming[0]["snippet"]
readable = run("links", moved, "--incoming", "--block", "keep-last", "--format", "text").decode()
assert moved in readable and "Decision: follow" in readable
assert json.loads(run("links", moved, "--incoming", "--format", "jsonl")) == incoming[0]
added_prefix = "Extra context. "
run("put", decision, added_prefix + decision_body, "--body-only")
updated = read("links", decision, "--format", "json")
assert len(updated) == 1 and updated[0]["targetID"] == first["documentID"], updated
assert updated[0]["sourceVersion"] == 2 and updated[0]["start"] == resolved[0]["start"] + len(added_prefix), updated
for exact in [first_occurrence_ref, occurrence_ref(updated[0])]:
    assert read("get", "--ref", exact)["items"] == [{"ref": exact, "path": decision, "text": link_markup}]
retained = read("get", "--id", source["documentID"], "--version", "1")
assert retained["body"] == decision_body and retained["references"] == [native_ref]
run("put", "/other.md", "![[archive/Retention-2026#^keep-last]] and %%[[ignored]]%%")
embed = read("links", "/other.md", "--format", "json")
assert len(embed) == 1 and embed[0]["isEmbed"] and embed[0]["targetID"] == first["documentID"], embed
assert "fourteen" in read("get", moved, "--block", "keep-last")["text"]
assert "seven" in read("get", moved, "--version", "1", "--block", "keep-last")["text"]
expanded = run("get", "--ref", ref, "--context", "section", "--max-tokens", "512")
assert len(expanded) <= 512 and rule in json.loads(expanded)["items"][0]["text"]
run("get", moved, "--block", "missing", ok=False)
run("search", "retention", "--view", "evidence", "--max-tokens", "1", ok=False)
run("search", "retention", "--tag", "storage")
run("prune", moved, "--keep-last", "1")
run("get", "--ref", ref, ok=False)

# A new document at either old path cannot inherit the deleted target's binding.
replacement = read("put", target, "Independent policy. ^keep-last")
assert read("links", decision, "--format", "json")[0]["targetID"] == first["documentID"]
assert read("links", target, "--incoming", "--format", "json") == []
assert read("delete", moved)["deleted"]
recreated = read("put", moved, "Recreated policy. ^keep-last")
assert len({replacement["documentID"], recreated["documentID"], first["documentID"]}) == 3
for path in [target, moved]:
    assert read("links", path, "--incoming", "--format", "json") == []
for path in [decision, "/other.md"]:
    orphaned = read("links", path, "--format", "json")
    assert len(orphaned) == 1 and orphaned[0]["status"] == "unresolved", orphaned
    assert "targetID" not in orphaned[0] and "targetPath" not in orphaned[0], orphaned
assert all(refs == [native_ref] for refs in graph_refs(
    "Decision", decision, "--include-linked-documents", "linkedDocuments"
))

# A short name can be ambiguous while an exact relative link resolves.
shared_a = read("put", "/standards/a/Shared.md", "First shared standard.")
shared_b = read("put", "/standards/b/Shared.md", "Second shared standard.")
review = "/reviews/recommendation.md"
run("put", review, "[[Shared]] and [first](../standards/a/Shared.md)")
ambiguous = read("links", review, "--format", "json")
assert [link["status"] for link in ambiguous] == ["ambiguous", "resolved"], ambiguous
assert ambiguous[0]["candidates"] == [
    {"documentID": item["documentID"], "path": item["path"]} for item in [shared_a, shared_b]
]
assert ambiguous[1]["syntax"] == "markdown" and ambiguous[1]["targetID"] == shared_a["documentID"]
assert read("links", shared_b["path"], "--incoming", "--format", "json") == []
run("move", shared_b["path"], "/standards/b/Renamed.md")
unambiguous = read("links", review, "--format", "json")
assert len(unambiguous) == 2 and all(
    link["status"] == "resolved" and link["targetID"] == shared_a["documentID"] for link in unambiguous
), unambiguous
assert read("links", shared_a["path"], "--incoming", "--format", "json") == unambiguous
assert read("delete", review)["deleted"]
assert read("links", shared_a["path"], "--incoming", "--format", "json") == []

# Adding a second occurrence resolves it against the current destination.
policy_path = "/bindings/Policy.md"
archived_policy_path = "/bindings/archive/Policy-2026.md"
binding_source = "/bindings/decision.md"
original_policy = read("put", policy_path, "Original policy.")
run("put", binding_source, "Existing: [[Policy|old]].")
run("move", policy_path, archived_policy_path)
new_policy = read("put", policy_path, "New policy.")
run("put", binding_source, "Existing: [[Policy|old]]. Added: [[Policy|new]].", "--body-only")
bindings = read("links", binding_source, "--format", "json")
assert [(link["label"], link["targetID"], link["targetPath"]) for link in bindings] == [
    ("old", original_policy["documentID"], archived_policy_path),
    ("new", new_policy["documentID"], policy_path),
], bindings
assert read("links", archived_policy_path, "--incoming", "--format", "json") == [bindings[0]]
assert read("links", policy_path, "--incoming", "--format", "json") == [bindings[1]]
