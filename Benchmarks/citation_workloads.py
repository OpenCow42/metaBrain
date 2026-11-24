"""Fixtures and correctness checks for end-to-end citation benchmarks."""

import os
from pathlib import Path
from tempfile import TemporaryDirectory


def run_workloads(invoke, count, warmups, samples):
    """Return elapsed nanoseconds and stdout byte counts from timed CLI calls.

    The caller supplies a fresh store and an invoke function that returns
    (decoded JSON, elapsed nanoseconds, stdout bytes). Verification calls
    use the same CLI but their timing and output sizes are discarded.
    """
    if count < 1 or warmups < 0 or samples < 1:
        raise ValueError("Expected positive citation and sample counts and nonnegative warmups.")

    initialized, _, _ = invoke("init", "--empty", "--format", "json")
    if initialized.get("status") != "initialized":
        raise RuntimeError("Could not initialize the citation benchmark store.")

    measurements = {name: [] for name in ("rewrite", "outgoing", "incoming", "resolve")}
    document_ids = set()
    temp_parent = os.environ.get("METABRAIN_TMPDIR") or None
    with TemporaryDirectory(prefix="mb-citation-bodies-", dir=temp_parent) as directory:
        body_file = Path(directory).resolve() / "body.md"
        _measure_current_graph(invoke, count, warmups, samples, body_file, document_ids, measurements)
        _measure_pending_links(invoke, count, warmups, samples, body_file, document_ids, measurements["resolve"])
    return measurements


def _measure_current_graph(invoke, count, warmups, samples, body_file, document_ids, measurements):
    hub_path = "/hub.md"
    hub, _, _ = invoke("put", hub_path, "Hub anchor. ^hub", "--format", "json")
    hub_id = _created_id(hub, hub_path, document_ids)

    targets = {}
    for index in range(count):
        path = f"/targets/t{index:06d}.md"
        body = f"Rule {index:06d}. ^rule\n\nSee [[{hub_path}#^hub]]."
        target, _, _ = invoke("put", path, body, "--format", "json")
        targets[path] = _created_id(target, path, document_ids)

    source_path = "/source.md"
    citations = "\n".join(f"See [[{path}#^rule]]." for path in targets)
    _write_source_body(body_file, 1, citations)
    source, _, _ = invoke(
        "put", source_path, "--body-file", str(body_file), "--keep-last", "1", "--format", "json"
    )
    source_id = _created_id(source, source_path, document_ids)
    outgoing = {(source_path, source_id, path, target_id) for path, target_id in targets.items()}
    incoming = {(path, target_id, hub_path, hub_id) for path, target_id in targets.items()}

    source_version = 1
    operations = ("rewrite", "outgoing", "incoming")
    for index in range(warmups + samples):
        start = index % len(operations)
        for operation in operations[start:] + operations[:start]:
            if operation == "rewrite":
                source_version += 1
                _write_source_body(body_file, source_version, citations)
                result, elapsed_ns, stdout_bytes = invoke(
                    "put", source_path, "--body-file", str(body_file), "--body-only", "--format", "json"
                )
                if (
                    result.get("status") != "updated"
                    or result.get("documentID") != source_id
                    or result.get("path") != source_path
                    or result.get("version") != source_version
                ):
                    raise RuntimeError(f"Expected a real update of {source_path} to version {source_version}.")
            elif operation == "outgoing":
                result, elapsed_ns, stdout_bytes = invoke("links", source_path, "--format", "json")
                _check_resolved(result, outgoing, "^rule", source_version, "source outgoing links")
            else:
                result, elapsed_ns, stdout_bytes = invoke("links", hub_path, "--incoming", "--format", "json")
                _check_resolved(result, incoming, "^hub", 1, "hub incoming links")
            if index >= warmups:
                measurements[operation].append((elapsed_ns, stdout_bytes))


def _measure_pending_links(invoke, count, warmups, samples, body_file, document_ids, measurements):
    future_paths = [f"/pending/p{index:06d}.md" for index in range(warmups + samples)]
    destinations = {f"{path}#^ready" for path in future_paths}
    body_file.write_bytes("\n".join(f"See [[{path}#^ready]]." for path in future_paths).encode("utf-8"))
    sources = {}
    for index in range(count):
        path = f"/waiting/w{index:06d}.md"
        source, _, _ = invoke("put", path, "--body-file", str(body_file), "--format", "json")
        sources[path] = _created_id(source, path, document_ids)

    # Verify every waiting source before introducing any target. This checks
    # that each creation will resolve one distinct occurrence per source.
    for path, source_id in sources.items():
        pending, _, _ = invoke("links", path, "--format", "json")
        _check_pending(pending, path, source_id, destinations)

    for index, path in enumerate(future_paths):
        before, _, _ = invoke("links", path, "--incoming", "--format", "json")
        if before != []:
            raise RuntimeError(f"Expected no incoming links for the absent target {path}.")
        result, elapsed_ns, stdout_bytes = invoke(
            "put", path, "Target arrived. ^ready", "--format", "json"
        )
        target_id = _created_id(result, path, document_ids)
        expected = {(source_path, source_id, path, target_id) for source_path, source_id in sources.items()}
        after, _, _ = invoke("links", path, "--incoming", "--format", "json")
        _check_resolved(after, expected, "^ready", 1, f"new target incoming links at {path}")
        if index >= warmups:
            measurements.append((elapsed_ns, stdout_bytes))


def _write_source_body(body_file, version, citations):
    body_file.write_bytes(f"Revision {version:08d}\n\n{citations}".encode("utf-8"))


def _created_id(result, path, document_ids):
    document_id = result.get("documentID")
    if (
        result.get("status") != "created"
        or result.get("path") != path
        or result.get("version") != 1
        or not isinstance(document_id, str)
        or not document_id
        or document_id in document_ids
    ):
        raise RuntimeError(f"Expected a fresh document ID at {path} with version 1.")
    document_ids.add(document_id)
    return document_id


def _check_resolved(links, expected, fragment, source_version, context):
    if not isinstance(links, list) or len(links) != len(expected):
        raise RuntimeError(f"Expected {len(expected)} {context}.")
    actual = set()
    for link in links:
        target_path = link.get("targetPath")
        if (
            link.get("status") != "resolved"
            or link.get("fragment") != fragment
            or link.get("destination") != f"{target_path}#{fragment}"
            or link.get("sourceVersion") != source_version
        ):
            raise RuntimeError(f"Unexpected status, destination, or source revision in {context}.")
        actual.add((link.get("sourcePath"), link.get("sourceID"), target_path, link.get("targetID")))
    if actual != expected:
        raise RuntimeError(f"Wrong source or target identities in {context}.")


def _check_pending(links, path, source_id, destinations):
    if not isinstance(links, list) or len(links) != len(destinations):
        raise RuntimeError(f"Expected {len(destinations)} unresolved links at {path}.")
    for link in links:
        if (
            link.get("status") != "unresolved"
            or link.get("sourceID") != source_id
            or link.get("sourcePath") != path
            or link.get("sourceVersion") != 1
            or link.get("fragment") != "^ready"
            or link.get("targetID") is not None
            or link.get("targetPath") is not None
        ):
            raise RuntimeError(f"Expected a pending citation at {path} without a target ID.")
    if {link.get("destination") for link in links} != destinations:
        raise RuntimeError(f"Wrong pending destinations at {path}.")
