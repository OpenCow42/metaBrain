#!/usr/bin/env python3
"""Exercise the portable skill bundle and its CLI acceptance fixture."""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
MB = Path(os.environ.get("MB_TEST_CLI", REPO / ".build/debug/mb")).resolve()
MBD = Path(os.environ.get("MB_TEST_DAEMON", REPO / ".build/debug/mbd")).resolve()


class SkillsTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)

    def script(self, name, *args, check=True):
        return subprocess.run(
            [sys.executable, str(REPO / "Scripts" / name), *map(str, args)],
            capture_output=True, text=True, check=check
        )

    def install(self, *args, check=True):
        return self.script("install-skills.py", "--project", self.work, *args, check=check)

    def test_manifests_are_portable(self):
        for manifest in sorted((REPO / "skills").glob("metabrain-*/SKILL.md")):
            with self.subTest(skill=manifest.parent.name):
                delimiter, name, description, closing, *_ = manifest.read_text(encoding="utf-8").splitlines()
                self.assertEqual((delimiter, closing), ("---", "---"))
                self.assertRegex(manifest.parent.name, r"^[a-z0-9-]{1,64}$")
                self.assertEqual(name, f"name: {manifest.parent.name}")
                self.assertRegex(description, r"^description: [^:\[\]{}]+$")

    def test_preview_apply_rerun_and_unrelated_skills(self):
        self.install()
        self.assertEqual(list(self.work.iterdir()), [])
        for host in (".agents", ".claude"):
            custom = self.work / host / "skills" / "custom"
            custom.mkdir(parents=True)
            (custom / "SKILL.md").write_bytes(b"custom\n")
        self.install("--apply")
        self.assertIn("Copied 0", self.install("--apply").stdout)
        for host in (".agents", ".claude"):
            destination = self.work / host / "skills"
            self.assertEqual((destination / "custom/SKILL.md").read_bytes(), b"custom\n")
            for source in (REPO / "skills").glob("metabrain-*"):
                self.assertFalse((destination / source.name).is_symlink())
                expected = {p.relative_to(source): p.read_bytes() for p in source.rglob("*") if p.is_file()}
                copied = destination / source.name
                actual = {p.relative_to(copied): p.read_bytes() for p in copied.rglob("*") if p.is_file()}
                self.assertEqual(actual, expected)

    def test_collision_aborts_both_hosts(self):
        colliding = self.work / ".claude/skills/metabrain-wiki"
        colliding.mkdir(parents=True)
        (colliding / "SKILL.md").write_bytes(b"custom\n")
        result = self.install("--apply", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(colliding.resolve()), result.stderr)
        self.assertEqual((colliding / "SKILL.md").read_bytes(), b"custom\n")
        self.assertFalse((self.work / ".agents").exists())
        self.assertFalse(colliding.with_name("metabrain-wiki-cli").exists())

    def test_symlink_does_not_install_outside_project(self):
        outside = self.work / "outside"
        outside.mkdir()
        (self.work / ".agents").symlink_to(outside, target_is_directory=True)
        result = self.install("--apply", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse((self.work / ".claude").exists())

    def fixture(self, state="adopt"):
        directory = self.work / state
        info = json.loads(self.script(
            "build-wiki-fixture.py", "--directory", directory, "--mb", MB, "--state", state
        ).stdout)
        return info, [str(MB), "--store", info["store"]]

    def mb(self, cli, *args, check=True):
        result = subprocess.run([*cli, *map(str, args)], text=True, capture_output=True)
        if check:
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            return json.loads(result.stdout)
        return result

    def project_reads(self, info, cli):
        root = info["project"]
        listing = self.mb(cli, "list", root, "--recursive", "--format", "json")
        evidence = self.mb(cli, "search", "offline storage", "--path-prefix", root + "/",
                           "--view", "evidence", "--limit", "8")
        self.assertTrue(evidence["items"])
        self.assertTrue(all(hit["path"].startswith(root + "/") for hit in evidence["items"]))
        hit = next(hit for hit in evidence["items"] if hit["path"] == root + "/reviews/field-review.md")
        passage = self.mb(cli, "get", "--ref", hit["ref"], "--context", "section")
        self.assertIn("readable off-network", json.dumps(passage))
        decision = self.mb(cli, "get", root + "/decision.md")
        relations = {entry["relation"] for entry in decision["claims"][0]["evidence"]}
        self.assertEqual(relations, {"supports", "contradicts"})
        links = self.mb(cli, "links", root + "/decision.md")
        self.assertEqual(len(links), 2)
        self.assertTrue(all(link["status"] == "resolved" for link in links))
        incoming = self.mb(cli, "links", hit["path"], "--incoming")
        self.assertEqual(incoming[0]["sourcePath"], root + "/decision.md")
        return listing, evidence, passage, decision, links, incoming

    def assert_missing_store_stays_missing(self, *connection):
        missing = self.work / "missing.leveldb"
        result = self.mb([str(MB), "--store", str(missing), *connection], "get", "/AGENTS.md", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No metaBrain store found", result.stderr)
        self.assertFalse(missing.exists())

    def test_cli_reads_and_binary_recovery(self):
        info, common = self.fixture()
        cli = [*common, "--no-server"]
        self.project_reads(info, cli)
        self.assert_missing_store_stays_missing("--no-server")
        recovered = self.work / "recovered.bin"
        completed = subprocess.run([*cli, "source", "export", info["project"] + "/opaque.md",
                                    "--output", str(recovered)], capture_output=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(recovered.read_bytes(), (self.work / "adopt/originals/opaque.bin").read_bytes())

    @unittest.skipUnless(os.environ.get("MB_TEST_SOCKET") == "1", "Set MB_TEST_SOCKET=1 where Unix sockets are allowed")
    def test_equivalent_reads_via_explicit_daemon(self):
        info, common = self.fixture()
        direct = self.project_reads(info, [*common, "--no-server"])
        endpoint = self.work / "mb.sock"
        config = self.work / "mbd.json"
        config.write_text("{}", encoding="utf-8")
        daemon = subprocess.Popen(
            [str(MBD), "serve", "--store", info["store"], "--socket", str(endpoint), "--config", str(config)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        try:
            for _ in range(50):
                if endpoint.is_socket() or daemon.poll() is not None:
                    break
                time.sleep(0.1)
            if not endpoint.is_socket():
                daemon.terminate()
                self.fail(daemon.communicate(timeout=5)[0])
            self.assertEqual(self.project_reads(info, [*common, "--server", str(endpoint)]), direct)
            self.assert_missing_store_stays_missing("--server", str(endpoint))
        finally:
            daemon.terminate()
            daemon.communicate(timeout=5)

    def setup_preview(self, info, cli, include_index=False):
        root = info["project"]
        operation_id = str(uuid.uuid4())
        record = f"_wiki/operations/{operation_id}.md"
        bodies = {
            "_wiki/config.json": '{"version":1,"mode":"generic"}\n',
            "_wiki/recent.md": f"# Recent activity\n\n[[{root}/{record}]]\n",
            record: f"# Setup\n\nAdopted [[{root}/index.md]].\n",
        }
        if include_index:
            bodies["index.md"] = "# Project wiki\n"
        documents = [{"path": {"rawValue": f"{root}/{name}"}, "body": body,
                      "tags": [], "metadata": {}, "references": []} for name, body in bodies.items()]
        draft = self.work / "setup.json"
        draft.write_text(json.dumps({
            "operationID": operation_id, "project": {"rawValue": root}, "documents": documents,
        }), encoding="utf-8")
        return self.mb(cli, "operation", "inspect", draft), f"{root}/{record}"

    def test_reviewed_setup_and_adoption(self):
        for state in ("empty", "adopt"):
            with self.subTest(state=state):
                info, common = self.fixture(state)
                cli = [*common, "--no-server"]
                root = info["project"]
                before = self.mb(cli, "list", root, "--recursive", "--format", "json")
                preserved = ["/AGENTS.md", info["decoy"] + "/review.md"]
                preserved.extend(entry["path"] for entry in before if "documentID" in entry)
                originals = {path: self.mb(cli, "get", path) for path in preserved}
                preview, record = self.setup_preview(info, cli, include_index=state == "empty")
                self.assertEqual(self.mb(cli, "list", root, "--recursive", "--format", "json"), before)
                self.assertTrue(Path(preview["storePath"]).samefile(info["store"]))
                self.assertEqual(preview["operation"]["project"]["rawValue"], root)
                self.assertTrue(all(target["version"] == 0 and "documentID" not in target
                                    for target in preview["targets"]))
                reviewed = self.work / "reviewed.json"
                reviewed.write_text(json.dumps(preview), encoding="utf-8")
                receipt = self.mb(cli, "operation", "apply", reviewed)
                self.assertEqual(self.mb(cli, "operation", "apply", reviewed), receipt)
                self.assertEqual({path: self.mb(cli, "get", path) for path in preserved}, originals)
                config = self.mb(cli, "get", root + "/_wiki/config.json")
                self.assertEqual(json.loads(config["body"]), {"version": 1, "mode": "generic"})
                self.assertIn(record, self.mb(cli, "get", root + "/_wiki/recent.md")["body"])
                self.assertEqual(sum(entry.get("documentID") is not None for entry in
                                     self.mb(cli, "list", root + "/_wiki/operations", "--format", "json")), 1)

    def inspect_operation(self, cli, project, operation_id, documents):
        draft = self.work / "workflow-draft.json"
        draft.write_text(json.dumps({
            "operationID": operation_id, "project": {"rawValue": project}, "documents": documents,
        }), encoding="utf-8")
        return self.mb(cli, "operation", "inspect", draft)

    def assert_observed_targets(self, preview, observations):
        actual = {target["path"]["rawValue"]: (target.get("documentID", {}).get("rawValue"), target["version"])
                  for target in preview["targets"]}
        expected = {path: ((document["documentID"], document["version"]) if document else (None, 0))
                    for path, document in observations.items()}
        self.assertEqual(actual, expected)

    def apply_preview(self, cli, preview, *, check=True):
        reviewed = self.work / "workflow-preview.json"
        reviewed.write_text(json.dumps(preview), encoding="utf-8")
        return self.mb(cli, "operation", "apply", reviewed, check=check)

    def proposed_note(self, path, body, existing=None, **updates):
        fields = {key: existing[key] for key in (
            "title", "tags", "metadata", "markdown", "sourceCapture", "claims", "sourceProfile"
        ) if existing and key in existing}
        references = []
        for reference in existing["references"] if existing else []:
            kind, value = reference["kind"], reference["value"]
            references.append({kind: {"_0": value if kind == "externalURL" else {"rawValue": value}}})
        return {"path": {"rawValue": path}, "body": body, "tags": [], "metadata": {},
                "references": references, **fields, **updates}

    def navigation(self, cli, root, operation_id, destination, purpose):
        index = root + "/index.md"
        recent = root + "/_wiki/recent.md"
        record = f"{root}/_wiki/operations/{operation_id}.md"
        observed = {path: self.mb(cli, "get", path) for path in (index, recent)}
        observed[record] = None
        link = f"[[{destination}]]"
        index_body = observed[index]["body"]
        if link not in index_body:
            index_body += f"\n- {link}\n"
        docs = [
            self.proposed_note(index, index_body, observed[index]),
            self.proposed_note(recent, observed[recent]["body"] + f"\n- [[{record}]]\n", observed[recent]),
            self.proposed_note(record, f"# {purpose}\n\n{link}\n"),
        ]
        return docs, observed, record

    def project_snapshot(self, cli, root):
        return {item["path"]: self.mb(cli, "get", item["path"]) for item in
                self.mb(cli, "list", root, "--recursive", "--format", "json") if "documentID" in item}

    def test_ingest_conflicting_reviews_and_identical_replay(self):
        info, common = self.fixture("empty")
        cli = [*common, "--no-server"]
        root = info["project"]
        setup, _ = self.setup_preview(info, cli, include_index=True)
        self.apply_preview(cli, setup)
        decision_path = root + "/decision.md"
        index_path = root + "/index.md"
        index_id = self.mb(cli, "get", index_path)["documentID"]
        self.mb(cli, "put", "--title", "Storage choice", "--tag", "decision", "--meta", "owner=UX",
                "--keep-last", "3", "--ref-id", index_id, "--ref-path", index_path,
                "--ref-url", "https://example.invalid/charter", "--if-version", "0",
                "--", decision_path, "---\nowner: UX\n---\n# Storage decision\n")
        decision = self.mb(cli, "get", decision_path)
        initial = self.project_snapshot(cli, root)
        originals = self.work / "empty/originals"
        inputs = []
        for name in ("field-review", "security-review"):
            original = originals / (name + ".md")
            digest = hashlib.sha256(original.read_bytes()).hexdigest()
            inputs.append((original, digest, "Design review: " + name, f"{root}/reviews/{name}.md"))
        self.assertEqual(self.project_snapshot(cli, root), initial)
        documents = [
            self.proposed_note(path, original.read_text(encoding="utf-8"), sourceCapture=self.mb(
                cli, "source", "stage", original, "--origin", origin, "--media-type", "text/markdown"
            ))
            for original, _, origin, path in inputs
        ]
        self.assertEqual([doc["sourceCapture"]["blob"]["sha256"] for doc in documents],
                         [digest for _, digest, _, _ in inputs])
        self.assertEqual(self.project_snapshot(cli, root), initial)
        operation_id = str(uuid.uuid4())
        navigation, observed, record = self.navigation(cli, root, operation_id, decision_path, "Ingest reviews")
        observed.update({path: None for _, _, _, path in inputs})
        observed[decision_path] = decision
        links = "\n".join(f"- [[{path}#^result]]" for _, _, _, path in inputs)
        edited_decision = self.proposed_note(decision_path, decision["body"] + "\n" + links + "\n", decision)
        documents += [edited_decision, *navigation]
        first = self.inspect_operation(cli, root, operation_id, documents)
        self.assert_observed_targets(first, observed)
        ids = {item["path"]["rawValue"]: item["documentID"]["rawValue"] for item in first["creations"]}
        edited_decision["claims"] = [{
            "id": str(uuid.uuid4()).upper(), "text": "The client should keep an offline copy.",
            "state": "contested", "highRisk": False,
            "evidence": [{"relation": relation, "ref": f"{ids[path]}@1#^result"}
                         for (_, _, _, path), relation in zip(inputs, ("supports", "contradicts"))],
        }]
        final = self.inspect_operation(cli, root, operation_id, documents)
        self.assert_observed_targets(final, observed)
        self.assertEqual(first["creations"], final["creations"])
        self.assertEqual(self.project_snapshot(cli, root), initial)
        receipt = self.apply_preview(cli, final)
        self.assertEqual(self.apply_preview(cli, final), receipt)
        self.assertEqual({result["path"]["rawValue"] for result in receipt["results"]}, set(observed))
        after = self.project_snapshot(cli, root)
        stored = after[decision_path]
        for key in ("documentID", "title", "tags", "metadata", "references"):
            self.assertEqual(stored[key], decision[key])
        self.assertTrue(stored["body"].startswith(decision["body"]))
        self.assertEqual(stored["claims"], edited_decision["claims"])
        self.assertIn(record, after[root + "/_wiki/recent.md"]["body"])
        self.assertIn(decision_path, after[root + "/index.md"]["body"])
        self.assertIn(decision_path, after[record]["body"])
        for source, entry in zip(inputs, stored["claims"][0]["evidence"]):
            original, _, _, path = source
            excerpt = self.mb(cli, "get", "--ref", entry["ref"])["items"][0]
            self.assertEqual(excerpt["path"], path)
            self.assertIn(excerpt["text"], original.read_text(encoding="utf-8"))
            recovered = self.work / original.name
            subprocess.run([*cli, "source", "export", path, "--output", str(recovered)], check=True,
                           capture_output=True)
            self.assertEqual(recovered.read_bytes(), original.read_bytes())

        # Repeat planning against project-scoped provenance, independently of the original preview.
        captures = {(doc["sourceCapture"]["blob"]["sha256"], doc["sourceCapture"]["origin"]): doc
                    for doc in after.values() if "sourceCapture" in doc}
        repeated = [item for item in inputs if (item[1], item[2]) not in captures]
        self.assertEqual(repeated, [])
        self.assertEqual(len(captures), 2)
        self.assertEqual(self.project_snapshot(cli, root), after)

    def test_budgeted_retrieval_and_query_depths(self):
        info, common = self.fixture("initialized")
        cli = [*common, "--no-server"]
        root = info["project"]
        decision = root + "/decision.md"
        extra = root + "/constraints.md"
        counter = root + "/threats.md"
        self.mb(cli, "put", extra, f"Offline storage exception: no sync without consent. [[{decision}]]",
                "--tag", "review", "--meta", "status=current", "--if-version", "0")
        self.mb(cli, "put", counter, "Credential theft exposes cached records. ^counter",
                "--if-version", "0")
        before = self.project_snapshot(cli, root)
        direct = [entry["ref"] for entry in before[decision]["claims"][0]["evidence"]]
        quick = [self.mb(cli, "get", "--ref", ref)["items"][0] for ref in direct]
        self.assertEqual([item["ref"] for item in quick], direct)
        self.assertIn("readable off-network", quick[0]["text"])
        self.assertIn("persistent client exposure", quick[1]["text"])

        neighbors = self.mb(cli, "links", decision, "--incoming")
        self.assertIn(extra, {link["sourcePath"] for link in neighbors})
        standard = self.mb(cli, "search", "offline storage exception", "--path-prefix", root + "/",
                           "--tag", "review", "--meta", "status=current", "--view", "evidence")
        self.assertEqual({item["path"] for item in standard["items"]}, {extra})
        self.assertIn("no sync without consent", self.mb(cli, "get", "--ref",
                      standard["items"][0]["ref"], "--context", "section")["items"][0]["text"])

        deep = self.mb(cli, "search", "credential theft", "--path-prefix", root + "/", "--view", "evidence")
        self.assertEqual(deep["items"][0]["path"], counter)
        self.assertIn("exposes cached records", self.mb(cli, "get", "--ref",
                      deep["items"][0]["ref"])["items"][0]["text"])
        origins = {before[item["path"]]["sourceCapture"]["origin"] for item in quick}
        self.assertEqual(len(origins), 2)
        lint = self.mb(cli, "lint", root, "--format", "json")
        self.assertTrue(all(finding["evidenceIssue"] == "ineligible" for finding in lint["findings"]))
        self.assertEqual({finding["evidenceRef"] for finding in lint["findings"]}, set(direct))

        budget = 360
        response = self.mb(cli, "search", "offline storage", "--path-prefix", root + "/",
                           "--view", "evidence", "--max-tokens", budget, check=False)
        self.assertEqual(response.returncode, 0, response.stderr)
        self.assertLessEqual(len(response.stdout.encode("utf-8")), budget)
        limited = json.loads(response.stdout)
        self.assertTrue(limited["truncated"])
        self.assertTrue(limited["items"])
        scoped_ids = {item["documentID"] for item in
                      self.mb(cli, "list", root, "--recursive", "--format", "json")
                      if "documentID" in item and item["path"].startswith(root + "/")}
        for item in limited["items"]:
            self.assertTrue(item["path"].startswith(root + "/"))
            self.assertIn(item["ref"].split("@")[0], scoped_ids)
            self.assertEqual(self.mb(cli, "get", "--ref", item["ref"])["items"][0], item)
        decoy_row = self.mb(cli, "list", info["decoy"], "--format", "json")[0]
        explicit = decoy_row["documentID"] + "@1#^result"
        self.assertNotIn(explicit.split("@")[0], scoped_ids)
        self.assertEqual(self.project_snapshot(cli, root), before)

    def test_save_exact_selection_and_guard_against_unread_revisions(self):
        info, common = self.fixture("initialized")
        cli = [*common, "--no-server"]
        root = info["project"]
        decision_path = root + "/decision.md"
        before = self.project_snapshot(cli, root)
        decision = before[decision_path]
        evidence = decision["claims"][0]["evidence"]
        selection = "Offline reads matter, and persistent exposure remains unresolved."
        conversation = ("Unrelated budget discussion.", selection, "Draft scheduling aside.")
        citations = "\n".join(f"- {entry['relation']}: `{entry['ref']}`" for entry in evidence)
        for entry in evidence:
            self.assertTrue(self.mb(cli, "get", "--ref", entry["ref"])["items"])
        candidates = self.mb(cli, "search", "Storage decision", "--path-prefix", root + "/",
                             "--tag", "decision", "--view", "refs")
        self.assertEqual({item["path"] for item in candidates["items"]}, {decision_path})
        new_section = f"\n## Saved conclusion\n\n{conversation[1]}\n\n{citations}\n"
        operation_id = str(uuid.uuid4())
        navigation, observed, record = self.navigation(cli, root, operation_id, decision_path, "Save conclusion")
        observed[decision_path] = decision
        draft = [self.proposed_note(decision_path, decision["body"] + new_section, decision), *navigation]
        preview = self.inspect_operation(cli, root, operation_id, draft)
        self.assert_observed_targets(preview, observed)
        self.assertEqual(self.project_snapshot(cli, root), before)

        human_edit = "\nThe team will revisit this in December.\n"
        self.mb(cli, "put", "--body-only", "--if-version", decision["version"],
                "--", decision_path, decision["body"] + human_edit)
        newer_preview = self.inspect_operation(cli, root, operation_id, draft)
        with self.assertRaises(AssertionError):
            self.assert_observed_targets(newer_preview, observed)
        self.assertNotEqual(self.apply_preview(cli, preview, check=False).returncode, 0)
        current = self.project_snapshot(cli, root)
        self.assertEqual({path: doc for path, doc in current.items() if path != decision_path},
                         {path: doc for path, doc in before.items() if path != decision_path})

        observed[decision_path] = current[decision_path]
        draft[0] = self.proposed_note(decision_path, current[decision_path]["body"] + new_section,
                                      current[decision_path])
        revised = self.inspect_operation(cli, root, operation_id, draft)
        self.assert_observed_targets(revised, observed)
        self.apply_preview(cli, revised)
        after = self.project_snapshot(cli, root)
        self.assertEqual(after[decision_path]["body"], decision["body"] + human_edit + new_section)
        self.assertEqual(after[decision_path]["claims"], decision["claims"])
        self.assertEqual(after[decision_path]["metadata"], decision["metadata"])
        self.assertTrue(decision["references"])
        self.assertEqual(after[decision_path]["references"], decision["references"])
        self.assertIn(record, after[root + "/_wiki/recent.md"]["body"])
        self.assertIn(decision_path, after[root + "/index.md"]["body"])
        self.assertEqual(set(after) - set(before), {record})

    def test_reserved_target_collision_and_stale_preview(self):
        info, common = self.fixture()
        cli = [*common, "--no-server"]
        root = info["project"]
        preview, record = self.setup_preview(info, cli)
        self.mb(cli, "put", root + "/_wiki/recent.md", "# Human-owned notes", "--if-version", "0")
        occupied, _ = self.setup_preview(info, cli)
        self.assertEqual([target["path"]["rawValue"] for target in occupied["targets"] if target["version"] != 0],
                         [root + "/_wiki/recent.md"])
        reviewed = self.work / "reviewed.json"
        reviewed.write_text(json.dumps(preview), encoding="utf-8")
        conflict = self.mb(cli, "operation", "apply", reviewed, check=False)
        self.assertNotEqual(conflict.returncode, 0)
        self.assertIn("changed after inspection", conflict.stderr)
        self.assertNotEqual(self.mb(cli, "get", record, check=False).returncode, 0)
        self.assertNotEqual(self.mb(cli, "get", root + "/_wiki/config.json", check=False).returncode, 0)
        self.assertEqual(self.mb(cli, "get", root + "/_wiki/recent.md")["body"], "# Human-owned notes")


if __name__ == "__main__":
    unittest.main(verbosity=2)
