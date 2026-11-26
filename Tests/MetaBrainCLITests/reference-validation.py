#!/usr/bin/env python3
"""Exercise typed audits and client-side HTTP decisions without contacting public hosts."""
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
    store = Path(sys.argv[1])
    command = [*sys.argv[2:], "--store", str(store)]
    base = store.parent
    base.mkdir(parents=True)
    curl = base / "curl"
    log = base / "curl.log"
    curl.write_text("""#!/bin/bash
set -eu
url="${@: -1}"
[[ "$1" == "--disable" && "$*" == *"--connect-to ::"* && "$*" == *"--noproxy *"* ]]
echo "$url" >> "$MB_PROBE_LOG"
case "$url" in
  */ok|*/dedupe|*/native) printf '204\\n' ;;
  */redirect) printf '302\\nhttps://93.184.216.34/ok\\n' ;;
  */private-redirect) printf '307\\nhttp://127.0.0.1/private\\n' ;;
  */secret-redirect) printf '302\\nhttps://93.184.216.34/?sig=REDIRECT_SECRET\\n' ;;
  */loop) printf '302\\n%s\\n' "$url" ;;
  */missing) printf '404\\n' ;;
  */gone) printf '410\\n' ;;
  */restricted) printf '401\\n' ;;
  */rate) printf '429\\n' ;;
  */timeout) exit 28 ;;
  */fallback)
    if [[ "$*" == *"--head"* ]]; then printf '405\\n'; else
      [[ "$*" == *"--range 0-0 --max-filesize "* ]]
      printf '206\\n'
      exit 63
    fi ;;
  */fallback-fails)
    if [[ "$*" == *"--head"* ]]; then printf '501\\n'; else exit 28; fi ;;
  *) exit 2 ;;
esac
""".replace(r"\$", "$"))
    curl.chmod(0o755)
    env = dict(os.environ, PATH=str(base) + os.pathsep + os.environ["PATH"], MB_PROBE_LOG=str(log))

    def run(*args, expected=0, environment=env, as_json=True):
        result = subprocess.run(command + list(args), text=True, capture_output=True, env=environment)
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        return json.loads(result.stdout) if as_json else result.stdout + result.stderr

    source = "/audit/source.md"
    run("put", "/audit/target.md", "Evidence. ^checked")
    public = "https://93.184.216.34"
    paths = ["ok", "redirect", "private-redirect", "secret-redirect", "loop", "missing", "gone",
             "restricted", "rate", "timeout", "fallback", "fallback-fails"]
    body = "[[target.md#^checked]]\n" + "\n".join(f"[{p}]({public}/{p})" for p in paths)
    body += (f"\n[A]({public}/dedupe#one) [B]({public}/dedupe#two)"
             "\n[private](http://127.0.0.1/secret) [mail](mailto:owner@example.org)"
             f"\n[signed]({public}/private?sig=SENSITIVE_TOKEN)")
    run("put", source, body, "--ref-url", public + "/native")
    offline = run("lint", source, "--references", "--strict")
    assert {c["kind"] for c in offline["referenceChecks"]} == {"storePassage", "externalURL"}
    assert offline["referenceChecks"][0]["location"] == "documentReference"
    assert not log.exists() and "externalChecks" not in offline
    assert "SENSITIVE_TOKEN" not in json.dumps(offline)
    observed = run("lint", source, "--check-external", "--strict", expected=3)
    assert observed["referenceChecks"] == offline["referenceChecks"]
    checks = {c["url"]: c for c in observed["externalChecks"]}
    statuses = ["reachable", "redirected", "blocked", "blocked", "inconclusive", "notFound", "notFound",
                "restricted", "inconclusive", "inconclusive", "reachable", "inconclusive"]
    assert [checks[public + "/" + path]["status"] for path in paths] == statuses, checks
    assert checks[public + "/redirect"]["finalURL"] == public + "/ok"
    assert checks["http://127.0.0.1/secret"]["status"] == "blocked"
    assert "REDIRECT_SECRET" not in json.dumps(observed)
    requests = log.read_text().splitlines()
    assert requests.count(public + "/dedupe") == 1 and requests.count(public + "/fallback") == 2
    assert not any("127.0.0.1" in url or "SECRET" in url or "TOKEN" in url for url in requests)
    text = run("lint", source, "--check-external", "--format", "text", as_json=False)
    assert "storePassage\tresolved" in text and "redirected\t204" in text
    lines = run("lint", source, "--check-external", "--format", "jsonl", as_json=False)
    assert {"location", "url"} <= {key for line in lines.splitlines() for key in json.loads(line)}
    missing_executable = run("lint", source, "--check-external", environment=dict(env, PATH=str(base / "empty")))
    assert all(c.get("reason") == "curlUnavailable" for c in missing_executable["externalChecks"])
    assert "explicit document or subtree" in run("lint", "--check-external", expected=64, as_json=False)

    # Exercise a bounded list and an unavailable numeric destination without DNS traffic.
    run("put", "/audit/limit.md", "\n".join(f"[row]({public}/{num}/ok)" for num in range(101)))
    limited = run("lint", "/audit/limit.md", "--check-external")
    assert limited["externalChecks"][-1]["reason"] == "requestLimit"
    run("put", "/audit/bad-address.md", "[bad](https://[2606:4700::1111]/ok) [dns](https://bad.invalid/ok)")
    unavailable = run("lint", "/audit/bad-address.md", "--check-external")
    assert [row["reason"] for row in unavailable["externalChecks"] if row["status"] != "reachable"] == ["dnsUnavailable"]

    if "--no-server" in command:
        legacy_checks(command, base, run)


def legacy_checks(command, base, run):
    op = base / "draft.json"
    op.write_text(json.dumps({
        "operationID": "70c0d652-6a18-4f7d-9714-817f56e75975", "project": {"rawValue": "/audit"},
        "documents": [{"path": {"rawValue": "/audit/proposed.md"}, "body": "Draft",
                       "tags": [], "metadata": {}, "references": []}],
    }))
    old_preview = run("operation", "inspect", str(op))

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if self.path == "/v1/lint":
                response = {"path": "/audit", "documentsChecked": 0, "counts": {}, "findings": []}
            else:
                assert self.path == "/v1/operation-check-citations", self.path
                response = old_preview
            data = json.dumps(response).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            cli = [arg for arg in command if arg != "--no-server"] + ["--server", f"http://127.0.0.1:{server.server_port}"]
            for args, message in [
                (["lint", "/audit", "--references"], "does not support reference inventories"),
                (["operation", "inspect", str(op), "--check-citations"], "does not support guarded citation checks"),
            ]:
                result = subprocess.run(cli + args, text=True, capture_output=True)
                assert result.returncode != 0 and message in result.stderr, (args, result)
        finally:
            server.shutdown()
            worker.join()


if __name__ == "__main__":
    main()
