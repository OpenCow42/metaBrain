#!/usr/bin/env python3
"""Exercise the portable skill bundle and its CLI acceptance fixture."""

import hashlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from html.parser import HTMLParser
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

    def project_format_previews(self, info, cli):
        root = info["project"]
        board = self.mb(cli, "preview", root + "/storage.canvas", "--project", root)
        self.assertEqual([node["id"] for node in board["nodes"]], ["decision", "field"])
        self.assertEqual(board["nodes"][0]["filePath"]["rawValue"], root + "/decision.md")
        self.assertEqual([edge["id"] for edge in board["edges"]], ["evidence"])
        tables = self.mb(cli, "preview", root + "/decisions.base", "--project", root)
        self.assertEqual(tables, [{
            "name": "Decisions", "columns": ["file.name", "status"],
            "rows": [{"path": {"rawValue": root + "/decision.md"}, "cells": ["decision.md", "contested"]}],
        }])
        return board, tables

    def test_canvas_draft_append_preserves_source(self):
        info, common = self.fixture()
        cli = [*common, "--no-server"]
        root = info["project"]
        path = root + "/storage.canvas"
        self.project_format_previews(info, cli)
        saved = self.mb(cli, "get", path)
        board = json.loads(saved["body"])
        board["custom"] = {"theme": "night", "layers": [1, 2]}
        board["nodes"][0]["customNode"] = {"lock": True}
        board["edges"][0]["customEdge"] = "curved"
        self.mb(cli, "put", "--body-only", "--if-version", saved["version"], path, json.dumps(board))
        original = self.mb(cli, "get", path)
        edited = json.loads(original["body"])
        edited["nodes"].append({
            "id": "review", "type": "file", "file": "reviews/security-review.md",
            "subpath": "#^result", "x": 300, "y": 0, "width": 240, "height": 140,
        })
        draft = self.work / "draft.canvas"
        draft.write_text(json.dumps(edited), encoding="utf-8")
        preview = self.mb(cli, "preview", path, "--project", root, "--body-file", draft)
        self.assertEqual([node["id"] for node in preview["nodes"]], ["decision", "field", "review"])
        self.assertEqual(preview["nodes"][-1]["subpath"], "#^result")
        self.assertEqual(self.mb(cli, "get", path), original)
        reviewed = self.inspect_operation(cli, root, str(uuid.uuid4()), [
            self.proposed_note(path, draft.read_text(encoding="utf-8"), original),
        ])
        self.assert_observed_targets(reviewed, {path: original})
        self.apply_preview(cli, reviewed)
        after = json.loads(self.mb(cli, "get", path)["body"])
        self.assertEqual(after["nodes"][:-1], board["nodes"])
        self.assertEqual(after["edges"], board["edges"])
        self.assertEqual(after["custom"], board["custom"])
        self.assertEqual(after, edited)

    def test_saved_views_are_scoped_and_unsupported_source_survives_edits(self):
        info, common = self.fixture()
        cli = [*common, "--no-server"]
        root = info["project"]
        path = root + "/decisions.base"
        self.mb(cli, "put", info["decoy"] + "/decision.md", "# Outside", "--tag", "decision")
        _, tables = self.project_format_previews(info, cli)
        saved = self.mb(cli, "get", path)
        draft = self.work / "draft.base"
        draft.write_text(saved["body"].replace("name: Decisions", "name: Storage decisions"), encoding="utf-8")
        self.assertEqual(self.mb(cli, "preview", path, "--project", root, "--body-file", draft),
                         [{**tables[0], "name": "Storage decisions"}])
        self.assertEqual(self.mb(cli, "get", path), saved)

        unsupported = saved["body"] + (
            "  - type: table\n"
            "    name: Links\n"
            "    filters: 'file.hasLink(\"decision\")'\n"
        )
        self.mb(cli, "put", "--body-only", "--if-version", saved["version"], path, unsupported)
        stored = self.mb(cli, "get", path)
        edited = unsupported.replace("name: Decisions", "name: Storage decisions")
        draft.write_text(edited, encoding="utf-8")
        missing_store = self.work / "missing.leveldb"
        for command, extra in (
            (cli, ()),
            ([str(MB), "--store", missing_store, "--no-server"], ("--body-file", draft)),
        ):
            result = self.mb(command, "preview", path, "--project", root, *extra, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Unsupported saved view filter", result.stderr)
            self.assertIn('file.hasLink("decision")', result.stderr)
            self.assertEqual(result.stdout, "")
        self.assertFalse(missing_store.exists())
        for target, project in ((path, "/"), (root + "/./decisions.base", root),
                                (root + "2/decisions.base", root), (root + ".base", root + ".base")):
            with self.subTest(target=target, project=project):
                result = self.mb([str(MB), "--store", missing_store, "--no-server"], "preview",
                                 target, "--project", project, "--body-file", draft, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("strictly inside an explicit non-root --project", result.stderr)
        self.assertEqual(self.mb(cli, "get", path), stored)
        reviewed = self.inspect_operation(cli, root, str(uuid.uuid4()), [
            self.proposed_note(path, edited, stored),
        ])
        self.assert_observed_targets(reviewed, {path: stored})
        self.apply_preview(cli, reviewed)
        self.assertEqual(self.mb(cli, "get", path)["body"], edited)

    def test_markdown_properties_anchors_embeds_and_comments(self):
        info, common = self.fixture()
        cli = [*common, "--no-server"]
        root = info["project"]
        path = root + "/acceptance.md"
        target = root + "/reviews/field-review.md"
        body = (
            "---\nstatus: verified\ntags: [acceptance]\n---\n\n"
            "# Acceptance\n\nVerified evidence. ^accepted\n\n"
            f"![[{target}#^result]]\n\n"
            "%% [[ignored.md]] ^ignored %%\n"
        )
        self.mb(cli, "put", "--", path, body)
        self.assertEqual(self.mb(cli, "get", path)["body"], body)
        passage = self.mb(cli, "get", path, "--block", "accepted")
        self.assertIn("Verified evidence.", json.dumps(passage))
        self.assertNotEqual(self.mb(cli, "get", path, "--block", "ignored", check=False).returncode, 0)
        links = self.mb(cli, "links", path)
        self.assertEqual(len(links), 1)
        self.assertEqual(links[0]["destination"], target + "#^result")
        self.assertEqual(links[0]["status"], "resolved")
        self.assertTrue(links[0]["isEmbed"])
        matches = self.mb(cli, "search", "--path-prefix", root + "/", "--tag", "acceptance",
                          "--meta", "status=verified", "--view", "refs")
        self.assertEqual([item["path"] for item in matches["items"]], [path])

    @unittest.skipUnless(os.environ.get("MB_TEST_SOCKET") == "1", "Set MB_TEST_SOCKET=1 where Unix sockets are allowed")
    def test_equivalent_reads_via_explicit_daemon(self):
        info, common = self.fixture()
        direct = self.project_reads(info, [*common, "--no-server"])
        direct_formats = self.project_format_previews(info, [*common, "--no-server"])
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
            self.assertEqual(self.project_format_previews(info, [*common, "--server", str(endpoint)]), direct_formats)
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

    def inspect_operation(self, cli, project, operation_id, documents, *options):
        draft = self.work / "workflow-draft.json"
        draft.write_text(json.dumps({
            "operationID": operation_id, "project": {"rawValue": project}, "documents": documents,
        }), encoding="utf-8")
        return self.mb(cli, "operation", "inspect", draft, *options)

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

    def skill_script(self, skill, script, *args, stdin=None, check=True):
        result = subprocess.run(
            [sys.executable, str(REPO / "skills" / ("metabrain-" + skill) / "scripts" / script),
             *map(str, args)], input=stdin, capture_output=True, text=True,
        )
        if not check:
            return result
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_lint_repeated_and_separate_selected_repair(self):
        info, common = self.fixture("initialized")
        cli = [*common, "--no-server"]
        root = info["project"]
        path = root + "/audit.md"
        index = root + "/index.md"
        missing = root + "/gone.md"
        self.mb(cli, "put", path,
                "## Empty\n<!--\n# Ignored HTML heading\n-->\n%%\n# Ignored wiki heading\n%%\n"
                "<!-- Another HTML comment --!>\n"
                "## Code only\n~~~sh\n# Literal code\n~~~\n"
                "## Present\nText.\n", "--if-version", "0")
        yaml = root + "/titled.md"
        self.mb(cli, "put", "--if-version", "0", "--", yaml, "---\ntitle: YAML title\n---\nUseful text.\n")
        index_note = self.mb(cli, "get", index)
        self.mb(cli, "put", "--body-only", "--if-version", index_note["version"], index,
                index_note["body"] + f"\n- [[{missing}]]\n- [[{path}#missing]]\n"
                f"- [[{info['decoy']}/review.md]]\n")
        before = self.project_snapshot(cli, root)
        args = ("--mb", MB, "--store", info["store"], "--no-server", "--project", root)
        report = self.skill_script("wiki-lint", "lint.py", *args)
        self.assertEqual(self.skill_script("wiki-lint", "lint.py", *args), report)
        self.assertEqual(report["native"], self.mb(cli, "lint", root, "--orphans"))
        self.assertEqual({item["link"]["destination"] for item in report["wikiFindings"]
                          if item["kind"] == "staleIndexEntry"}, {missing, path + "#missing"})
        self.assertEqual([(item["heading"], item["line"]) for item in report["wikiFindings"]
                          if item["sourcePath"] == path and item["kind"] == "emptySection"], [("Empty", 1)])
        self.assertEqual([item["property"] for item in report["wikiFindings"]
                          if item["sourcePath"] == path and item["kind"] == "missingWikiProperty"], ["title"])
        self.assertFalse(any(item["sourcePath"] == yaml and item["kind"] == "missingWikiProperty"
                             for item in report["wikiFindings"]))
        self.assertEqual(self.project_snapshot(cli, root), before)

        operation_id = str(uuid.uuid4())
        _, observed, record = self.navigation(cli, root, operation_id, index, "Repair index reference")
        recent = root + "/_wiki/recent.md"
        proposed = [
            self.proposed_note(index, before[index]["body"].replace(f"[[{missing}]]", f"[[{path}]]"), before[index]),
            self.proposed_note(recent, before[recent]["body"] + f"\n- [[{record}]]\n", before[recent]),
            self.proposed_note(record, f"# Repair index reference\n\nCorrected one stale entry in [[{index}]].\n"),
        ]
        preview = self.inspect_operation(cli, root, operation_id, proposed)
        self.assert_observed_targets(preview, observed)
        self.assertEqual(self.project_snapshot(cli, root), before)
        self.apply_preview(cli, preview)
        remaining = self.skill_script("wiki-lint", "lint.py", *args)["wikiFindings"]
        self.assertEqual({item["link"]["destination"] for item in remaining
                          if item["kind"] == "staleIndexEntry"}, {path + "#missing"})
        self.assertEqual(self.mb(cli, "get", path), before[path])

    def test_mode_suggestion_and_reviewed_config_change(self):
        info, common = self.fixture("initialized")
        cli = [*common, "--no-server"]
        root = info["project"]
        config_path = root + "/_wiki/config.json"
        extra = {"version": 1, "mode": "generic", "policy": {"owner": "research"}}
        self.mb(cli, "put", config_path, json.dumps(extra), "--if-version", "1")
        before = self.project_snapshot(cli, root)
        options = ("--project", root, "--slug", "offline-storage", "--kind", "concept")

        def suggest(config, *arguments, check=True):
            return self.skill_script("wiki-mode", "suggest.py", *options, "--config-stdin", *arguments,
                                     stdin=config, check=check)

        old = suggest(before[config_path]["body"])
        self.assertEqual(old, {"mode": "generic", "path": root + "/concepts/offline-storage.md"})
        self.assertEqual(self.skill_script("wiki-mode", "suggest.py", *options, "--absent-config"), old)
        for invalid in ('{"version":1,"mode":"unknown"}', '{"version":true,"mode":"generic"}', "broken"):
            self.assertNotEqual(suggest(invalid, check=False).returncode, 0)
        lyt = suggest('{"version":1,"mode":"lyt"}')
        self.assertEqual(lyt["path"], root + "/notes/offline-storage.md")
        zettels = [suggest('{"version":1,"mode":"zettelkasten"}')["path"] for _ in range(2)]
        self.assertNotEqual(*zettels)
        self.assertRegex(zettels[0], r"/zettels/\d{8}T\d{12}Z-[0-9a-f]{32}-offline-storage\.md$")

        operation_id = str(uuid.uuid4())
        recent = root + "/_wiki/recent.md"
        record = root + "/_wiki/operations/" + operation_id + ".md"
        replacement = {**extra, "mode": "para"}
        documents = [
            self.proposed_note(config_path, json.dumps(replacement), before[config_path]),
            self.proposed_note(recent, before[recent]["body"] + f"\n- [[{record}]]\n", before[recent]),
            self.proposed_note(record, f"# Change filing mode\n\nFrom generic to para in [[{config_path}]].\n"),
        ]
        observations = {config_path: before[config_path], recent: before[recent], record: None}
        preview = self.inspect_operation(cli, root, operation_id, documents)
        self.assert_observed_targets(preview, observations)
        self.assertEqual(self.project_snapshot(cli, root), before)
        self.apply_preview(cli, preview)
        after = self.project_snapshot(cli, root)
        self.assertEqual(json.loads(after[config_path]["body"]), replacement)
        self.assertEqual(suggest(after[config_path]["body"], "--actionability", "resource"),
                         {"mode": "para", "path": root + "/resources/offline-storage.md"})
        self.assertEqual(set(after) - set(before), {record})
        self.assertEqual({path: after[path] for path in before if path not in observations},
                         {path: before[path] for path in before if path not in observations})

    def test_fold_bounded_selection_idempotence_and_raw_versions(self):
        info, common = self.fixture("initialized")
        cli = [*common, "--no-server"]
        root = info["project"]
        args = ("--mb", MB, "--store", info["store"], "--no-server", "--project", root)

        def fold(*bounds, check=True):
            return self.skill_script("wiki-fold", "select-fold.py", *args, *bounds, check=check)

        before = self.project_snapshot(cli, root)
        default = fold()
        self.assertEqual((default["state"], default["shortfall"]), ("shortfall", 15))
        raw = default["entries"][0]["path"]
        bounds = ("--from", raw, "--through", raw)
        selected = fold(*bounds)
        self.assertEqual(selected["state"], "new")
        self.assertEqual(json.loads(selected["sources"]), [[before[raw]["documentID"], before[raw]["version"]]])
        self.assertEqual(selected["digest"], hashlib.sha256(selected["sources"].encode()).hexdigest())
        source = self.mb(cli, "get", "--id", before[raw]["documentID"], "--version", before[raw]["version"])
        self.assertEqual(source["body"], selected["entries"][0]["body"])

        destination, digest = selected["path"], selected["digest"]
        operation_id = str(uuid.uuid4())
        navigation, observed, record = self.navigation(cli, root, operation_id, destination, "Fold")
        citation = f"[[{raw}]] at `{source['documentID']}` version {source['version']}"
        navigation[-1]["metadata"] = {"wiki-operation": "fold", "wiki-fold": digest}
        navigation[-1]["body"] += f"\nSource: {citation}\n"
        summary = self.proposed_note(destination, f"# Fold\n\nSeeded the fixture.\n\n- {citation}\n",
                                     metadata={"wiki-fold": digest, "wiki-fold-sources": selected["sources"]})
        observed[destination] = None
        preview = self.inspect_operation(cli, root, operation_id, [summary, *navigation])
        self.assert_observed_targets(preview, observed)
        self.assertNotIn(raw, observed)
        self.assertEqual(self.project_snapshot(cli, root), before)
        receipt = self.apply_preview(cli, preview)
        self.assertEqual(self.apply_preview(cli, preview), receipt)
        after = self.project_snapshot(cli, root)
        repeated = fold(*bounds)
        self.assertEqual((repeated["state"], repeated["path"], repeated["records"]),
                         ("complete", destination, [record]))
        self.assertEqual(fold(), default)
        self.assertNotEqual(fold("--from", record, "--through", record, check=False).returncode, 0)
        self.assertEqual(self.project_snapshot(cli, root), after)
        self.assertEqual(after[raw], before[raw])
        self.assertEqual(set(after) - set(before), {destination, record})
        self.assertIn(citation, after[destination]["body"])
        recent = root + "/_wiki/recent.md"
        self.mb(cli, "put", "--body-only", "--if-version", after[recent]["version"], recent, before[recent]["body"])
        self.assertEqual(fold(*bounds)["state"], "conflict")

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
        final = self.inspect_operation(cli, root, operation_id, documents, "--check-citations")
        checked = [item for item in final["citationChecks"]
                   if item["link"]["sourcePath"]["rawValue"] == decision_path and "passage" in item]
        self.assertEqual(len(checked), len(inputs))
        for check, (original, _, _, path) in zip(checked, inputs):
            self.assertEqual(check["link"]["status"], "resolved")
            self.assertEqual(check["passage"]["path"]["rawValue"], path)
            self.assertIn(check["passage"]["passage"]["text"], original.read_text(encoding="utf-8"))
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

    def url_plan(self, url, *, check=True):
        return self.skill_script("defuddle", "plan-url.py", "--", url, check=check)

    def test_url_preview_keeps_supplied_origin(self):
        origin = "https://example.invalid/page%20name?q=a%2Bb#evidence"
        self.assertEqual(self.url_plan(origin), {
            "origin": origin, "state": "requires-original",
            "acceptedMediaTypes": ["text/html", "text/markdown"],
        })
        for invalid in ("file:///tmp/example", "example.invalid", "https://", "https://a:65536",
                        "https://user:secret@example.invalid", " https://example.invalid",
                        "https://example.invalid/\t", "https://[broken",
                        "https://example.invalid/?%61ccess_token=secret",
                        "https://example.invalid/?X-Amz-Signature=secret"):
            with self.subTest(url=invalid):
                result = self.url_plan(invalid, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("secret", result.stderr)
        self.assertEqual(list(self.work.iterdir()), [])

    @unittest.skipUnless(os.environ.get("MB_TEST_SOCKET") == "1", "Set MB_TEST_SOCKET=1 where sockets are allowed")
    def test_url_preview_does_not_contact_loopback_origin(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            origin = f"http://127.0.0.1:{listener.getsockname()[1]}/review"
            self.assertEqual(self.url_plan(origin)["origin"], origin)
            listener.setblocking(False)
            with self.assertRaises(BlockingIOError):
                listener.accept()

    def test_capture_locally_supplied_pages_preserves_exact_bytes(self):
        info, common = self.fixture("initialized")
        cli = [*common, "--no-server"]
        root = info["project"]
        origin = "https://example.invalid/page"
        html = self.work / "page.html"
        html.write_bytes(b'<p>Offline storage caf\xe9.</p>\r\n<img src="http://127.0.0.1/image">\r\n')
        markdown = self.work / "review.md"
        markdown.write_bytes(b"\xef\xbb\xbf# Field review\r\n\r\nKeep reads available.\r\n")
        before = self.project_snapshot(cli, root)
        self.assertEqual(self.url_plan(origin)["state"], "requires-original")
        self.assertEqual(self.project_snapshot(cli, root), before)

        class TextParser(HTMLParser):
            def __init__(self):
                super().__init__()
                self.text = []

            def handle_data(self, data):
                if data.strip():
                    self.text.append(data)

        parser = TextParser()
        parser.feed(html.read_bytes().decode("latin-1"))
        parser.close()
        extraction = "Python html.parser handle_data on Latin-1 HTML"
        html_path = root + "/sources/page.md"
        markdown_path = root + "/sources/field.md"
        captures = [
            (html, html_path, "text/html", " ".join(parser.text), ["--extraction", extraction]),
            (markdown, markdown_path, "text/markdown", markdown.read_bytes().decode("utf-8"), []),
        ]
        operation_id = str(uuid.uuid4())
        navigation, observed, _ = self.navigation(cli, root, operation_id, html_path, "Capture supplied pages")
        documents = []
        for source, path, media_type, body, extraction_args in captures:
            capture = self.mb(cli, "source", "stage", source, "--origin", origin,
                              "--media-type", media_type, *extraction_args)
            self.assertEqual(capture["blob"]["sha256"], hashlib.sha256(source.read_bytes()).hexdigest())
            documents.append(self.proposed_note(path, body, sourceCapture=capture))
            observed[path] = None
        preview = self.inspect_operation(cli, root, operation_id, [*documents, *navigation])
        self.assert_observed_targets(preview, observed)
        self.assertEqual(self.project_snapshot(cli, root), before)
        self.apply_preview(cli, preview)

        for source, path, media_type, _, extraction_args in captures:
            stored = self.mb(cli, "get", path)
            self.assertEqual(stored["sourceCapture"]["origin"], origin)
            self.assertEqual(stored["sourceCapture"]["mediaType"], media_type)
            self.assertEqual(stored["sourceCapture"].get("extraction"),
                             extraction_args[-1] if extraction_args else None)
            restored = self.work / f"{source.name}.recovered"
            subprocess.run([*cli, "source", "export", path, "--version", str(stored["version"]),
                            "--output", str(restored)], check=True, capture_output=True)
            self.assertEqual(restored.read_bytes(), source.read_bytes())
        self.assertEqual(self.mb(cli, "get", html_path)["body"], "Offline storage café.")

    def test_research_dossier_and_merge_use_distinct_reviewed_operations(self):
        info, common = self.fixture("initialized")
        cli = [*common, "--no-server"]
        root = info["project"]
        decision = root + "/decision.md"
        before = self.project_snapshot(cli, root)
        evidence = self.mb(cli, "search", "offline storage", "--path-prefix", root + "/reviews/",
                           "--view", "evidence", "--limit", "2")
        self.assertEqual(len(evidence["items"]), 2)
        passages = [self.mb(cli, "get", "--ref", entry["ref"])["items"][0] for entry in evidence["items"]]
        self.assertEqual({passage["path"] for passage in passages},
                         {root + "/reviews/field-review.md", root + "/reviews/security-review.md"})
        citations = "\n".join(f"- {passage['text']} ({passage['path']}, `{passage['ref']}`)"
                              for passage in passages)
        dossier = root + "/research/offline-storage.md"
        report = (
            "# Offline storage research\n\nLocal-only. Stopped after verifying both reviews.\n\n"
            f"## Evidence and disagreement\n\n{citations}\n\n"
            "## Interpretation and open question\n\n"
            "Start with a limited pilot. The availability benefit may not outweigh exposure on a lost device. "
            "Can a revoked account read persistent records after restart with the device offline? "
            "If it can, keep server-only storage.\n"
        )
        self.assertEqual(self.project_snapshot(cli, root), before)

        operation_id = str(uuid.uuid4())
        navigation, observed, filing_record = self.navigation(cli, root, operation_id, dossier, "File dossier")
        observed[dossier] = None
        filing = self.inspect_operation(cli, root, operation_id, [self.proposed_note(dossier, report), *navigation])
        self.assert_observed_targets(filing, observed)
        self.assertEqual(self.project_snapshot(cli, root), before)
        self.apply_preview(cli, filing)
        filed = self.project_snapshot(cli, root)
        self.assertEqual(filed[decision], before[decision])
        self.assertEqual(filed[dossier]["body"], report)

        operation_id = str(uuid.uuid4())
        navigation, observed, merge_record = self.navigation(cli, root, operation_id, decision, "Merge conclusion")
        observed[decision] = filed[decision]
        edited = self.proposed_note(decision, filed[decision]["body"] + f"\nReview the pilot in [[{dossier}]].\n",
                                    filed[decision])
        merge = self.inspect_operation(cli, root, operation_id, [edited, *navigation])
        self.assert_observed_targets(merge, observed)
        self.assertEqual(self.project_snapshot(cli, root), filed)
        self.apply_preview(cli, merge)
        merged = self.project_snapshot(cli, root)
        self.assertEqual(merged[dossier], filed[dossier])
        self.assertEqual(merged[decision]["claims"], before[decision]["claims"])
        self.assertIn(dossier, merged[decision]["body"])
        self.assertNotEqual(filing_record, merge_record)
        self.assertEqual(merged[filing_record], filed[filing_record])
        self.assertIn(merge_record, merged)

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
