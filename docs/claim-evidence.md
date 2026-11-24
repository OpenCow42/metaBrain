# Record a decision with conflicting evidence

A claim belongs to a note and has a UUID that stays with it across edits. Each evidence item pairs a relationship (`supports` or `contradicts`) with a retained passage, such as `DOCUMENT_ID@1#^result`. The reference also contains the document ID for opening the current source after a move.

This example creates two review notes and one contested decision together in an existing store. It uses an unused project path. For an existing source, use its document ID and the version of the passage you inspected.

```sh
python3 - <<'PY'
import json, uuid
from pathlib import Path

project = "/projects/storage-review"
def note(name, body):
    return {"path": {"rawValue": project + "/" + name + ".md"}, "body": body,
            "tags": [], "metadata": {}, "references": []}

notes = [note("field-review", "Keep an offline copy for reading. ^result"),
         note("security-review", "Use server-only storage for this data. ^result"),
         note("decision", "The team is reviewing offline storage.")]
for source, group in zip(notes, ["field research", "security review"]):
    source["sourceProfile"] = {"status": "active", "synthetic": False,
                              "independenceGroup": group, "freshUntil": "2027-01-01T00:00:00Z"}
draft = {"operationID": str(uuid.uuid4()), "project": {"rawValue": project}, "documents": notes}
Path("draft.json").write_text(json.dumps(draft))
PY
mb operation inspect draft.json > draft-preview.json
python3 - <<'PY'
import json, uuid
from pathlib import Path

preview = json.loads(Path("draft-preview.json").read_text())
ids = {item["path"]["rawValue"]: item["documentID"]["rawValue"] for item in preview["creations"]}
draft = preview["operation"]
first, second, decision = draft["documents"]
evidence = [{"relation": relation, "ref": ids[note["path"]["rawValue"]] + "@1#^result"}
            for relation, note in [("supports", first), ("contradicts", second)]]
decision["claims"] = [{"id": str(uuid.uuid4()), "text": "This client should keep a local copy.",
                       "state": "contested", "highRisk": False, "evidence": evidence}]
Path("decision.json").write_text(json.dumps(draft))
PY
mb operation inspect decision.json > decision-preview.json
mb operation apply decision-preview.json
mb get /projects/storage-review/decision.md --format json
mb lint /projects/storage-review --format text
```

The first inspection reports the IDs the operation will assign. The final inspection checks the claims against the proposed source revisions. Apply repeats the checks and commits the sources and decision in one batch. Add `sourceCapture` to a source note when its original file is available. [Capture an original file](../README.md#capture-and-recover-an-original-file)

## Assessment rules

- Choose `accepted`, `provisional`, `contested`, `unsupported`, or `deprecated`. An accepted claim needs support from a fresh, active, non-synthetic source. Eligible contrary evidence prevents acceptance. Earlier or ineligible accounts can be kept alongside sufficient current support and appear in lint. Retain both accounts on a contested claim.
- Record the original reporting group and its review deadline on each assessed source. High-risk acceptance requires at least two independent groups and two distinct originals. The retained revisions supply the original byte digests for captured files and full-text digests for plain sources.
- A reviewed write verifies that every cited passage exists and contains text. A source moved within the reviewed project can still support a claim when its current passage matches the retained quotation. Moving it outside that project produces a lint finding. Lint flags changed passages, expired assessments, superseded or disputed sources, and unavailable revisions. Inspection and lint use the current time. Set the deadline in the example to the date when the source actually needs review.
- Use `mb get --ref 'DOCUMENT_ID@VERSION#^result'` to read cited evidence and `mb get --id DOCUMENT_ID` for the current source. Historical decision revisions retain their own claim lists. An operation with `"claims":[]` clears the list on the new revision. Omitting the field preserves it.
