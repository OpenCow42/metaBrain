"""Check lint formats, strict exit status, and parity through a running daemon."""

import json
import pathlib
import subprocess
import sys


def main():
    store_path, endpoint, *client = sys.argv[1:]
    direct = client + ["--store", store_path, "--no-server"]
    daemon = client + ["--store", store_path, "--server", endpoint]

    def run(command, *args, status=0):
        result = subprocess.run(command + list(args), capture_output=True, text=True)
        assert result.returncode == status, (command, args, result)
        return result

    for mode in (direct, daemon):
        error = run(mode, "lint", status=1)
        assert "No metaBrain store found" in error.stderr, error
        assert not pathlib.Path(store_path).exists()
    run(direct, "init", "--empty")
    assert json.loads(run(direct, "lint", "--strict").stdout)["documentsChecked"] == 0
    run(direct, "put", "/policies/Retention.md", "Keep the last seven backups. ^keep-last")
    run(direct, "put", "/decisions/backups.md", "Follow [[/policies/Retention.md#^keep-last]].")
    assert not run(direct, "lint", "/decisions", "--format", "jsonl", "--strict").stdout
    run(direct, "put", "/policies/Retention.md", "Keep the last seven backups.", "--body-only")

    expected = run(direct, "lint", "/decisions").stdout
    report = json.loads(expected)
    assert report["path"] == "/decisions", report
    assert report["documentsChecked"] == 1, report
    assert report["counts"]["missingAnchor"] == 1, report
    finding, = report["findings"]
    assert finding["sourcePath"] == "/decisions/backups.md", finding
    assert finding["sourceVersion"] == 1, finding
    assert finding["targetPath"] == "/policies/Retention.md", finding
    assert finding["fragment"] == "^keep-last", finding

    for mode in (direct, daemon):
        assert run(mode, "lint", "/decisions").stdout == expected
        assert run(mode, "lint", "/decisions", "--strict", status=3).stdout == expected
        jsonl = run(mode, "lint", "/decisions", "--format", "jsonl").stdout
        assert [json.loads(line) for line in jsonl.splitlines()] == [finding]
        text = run(mode, "lint", "/decisions", "--format", "text").stdout
        assert "/decisions/backups.md@1:7-" in text and "missingAnchor=1" in text, text
        assert "Checked 1 Markdown document under /decisions." in text, text
        error = run(mode, "lint", "/decision", "--strict", status=1)
        assert "No document or descendants found at lint path /decision." in error.stderr, error
        run(mode, "lint", "/policies", "--strict")
        orphan = json.loads(run(
            mode, "lint", "/decisions/backups.md", "--orphans", "--format", "jsonl"
        ).stdout.splitlines()[-1])
        assert orphan["kind"] == "orphan", orphan

        # Use a separate clean note for the orphan-only strict check.
        if mode == direct:
            run(direct, "put", "/loose.md", "A standalone note.")
        run(mode, "lint", "/loose.md", "--strict")
        orphan_only = json.loads(run(mode, "lint", "/loose.md", "--strict", "--orphans", status=3).stdout)
        assert [item["kind"] for item in orphan_only["findings"]] == ["orphan"], orphan_only


if __name__ == "__main__":
    main()
