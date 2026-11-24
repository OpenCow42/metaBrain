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
decision_body = "Decision: follow [[Retention#^keep-last]].\n\nExample: `[[No such note]]`."
run("put", decision, decision_body, "--markdown")
assert read("get", decision)["markdown"]
assert read("dump", decision, "--versions", "--format", "json")[0]["markdown"]
pending = read("links", decision, "--format", "json")
assert len(pending) == 1 and pending[0]["status"] != "resolved", pending

# Keep the actual match far from the beginning of the document.
rule = "Keep the last seven nightly backups, except during migration."
policy = "---\ntags: [storage]\nstatus: draft\n---\n# Retention\n\n"
policy += "Routine maintenance details. " * 190 + "\n\n" + rule + " ^keep-last\n"
body_file = store.parent / "policy.md"
body_file.write_text(policy, encoding="utf-8")
first = read("put", target, "--body-file", str(body_file), "--keep-all")
resolved = read("links", decision, "--format", "json")
assert len(resolved) == 1 and resolved[0]["targetID"] == first["documentID"], resolved
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
