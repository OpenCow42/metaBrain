#!/usr/bin/env python3
"""Exercise the portable skill bundle and its CLI acceptance fixture."""

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
