# Project wiki skills

| Skill | Use it to |
| --- | --- |
| `metabrain-wiki` | Set up, adopt, or route a wiki request. |
| `metabrain-wiki-cli` | Read notes, inspect the selected store, and follow links. |
| `metabrain-wiki-ingest` | Capture supplied originals and relate their evidence to project claims. |
| `metabrain-wiki-retrieve` | Return ranked passages and versioned references under a budget. |
| `metabrain-wiki-query` | Answer from the selected project at Quick, Standard, or Deep depth. |
| `metabrain-autoresearch` | Research an agreed question under a source and stopping budget. |
| `metabrain-defuddle` | Plan URL capture offline or preserve supplied HTML or Markdown. |
| `metabrain-think` | Review a decision, competing evidence, and a test that could change the recommendation. |
| `metabrain-wiki-lint` | Audit links, evidence, note properties, sections, and navigation. |
| `metabrain-wiki-mode` | Suggest a destination or change the filing mode for future notes. |
| `metabrain-wiki-fold` | Summarize a bounded range of past operations with versioned sources. |
| `metabrain-save` | Preserve the selected answer or insight with its evidence. |
| `metabrain-canvas` | Inspect a JSON Canvas board or add one node. |
| `metabrain-markdown` | Verify or edit Markdown properties, links, headings, blocks, embeds, and comments. |
| `metabrain-bases` | Inspect or edit a saved YAML table and check its filters against project properties. |

See the [local plan](second-brain-plan.md) for the workflow and its acceptance checks.

## Install into a project

From the metaBrain checkout, run this with Python 3 and an existing local project directory.

```sh
python3 Scripts/install-skills.py --project /path/to/project
python3 Scripts/install-skills.py --project /path/to/project --apply
```

The first command previews. The second copies the canonical directories from [skills](../skills/) to the selected project's `.agents/skills/` and `.claude/skills/`. Identical copies are skipped on rerun. A differing package with the same name or a blocked destination stops the install for both hosts. Review a conflicting project copy yourself before trying again. The installer leaves global agent settings and unrelated project skills alone.

Start a session in the selected project with a current `mb` on your executable search path. If building from source, use the checkout’s `.build/debug` directory. In Codex, select a skill by name with a `$` prefix, such as `$metabrain-wiki-query`. In Claude Code, use the corresponding slash command, such as `/metabrain-wiki-query`. Use a new session if skill discovery has yet to refresh. [Codex skill discovery](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills) · [Claude Code skill discovery](https://code.claude.com/docs/en/skills#where-skills-live)

## Set up or adopt a wiki

Ask the wiki skill to set up or preview setup, giving it an existing store path and a virtual project root below `/`, such as `/projects/storage-review`. Direct access uses `--no-server`. For a daemon-backed store, give the Unix socket or loopback endpoint explicitly. The skill uses the selected connection and reads the store's virtual `/AGENTS.md` and the project's optional `AGENTS.md`.

The preview proposes missing documents, preserves existing project content and custom guidance, and reports occupied reserved paths. A usable Markdown `index.md` can be adopted as-is. The workflow stops for an invalid configuration or incompatible reserved paths. Review the proposed operation before authorizing apply.

| Virtual path under the project root | Purpose |
| --- | --- |
| `_wiki/config.json` | A document with a JSON body such as `{"version":1,"mode":"generic"}`. The recognized modes are `generic`, `lyt`, `para`, and `zettelkasten`. |
| `index.md` | Project navigation. |
| `_wiki/recent.md` | Recent activity summary. |
| `_wiki/operations/<operation-UUID>.md` | An append-only Markdown record written in the same reviewed project operation as its related changes. |

For read-only evidence, invoke the CLI skill and specify the same store and project. It lists or searches within the selected project and reopens a versioned reference before quoting. [Reviewed project operations](../README.md#commit-related-notes-together) · [Evidence reads](../README.md#find-and-reopen-evidence)

## Ingest, retrieve, query, and save

- **Ingest** supplies original files or text and an origin. A preview-only request leaves the store untouched. An ingest request stages the exact bytes and verifies the proposed citations before applying the batch. Repeated capture of the same digest and origin in the project reuses the source note. A different origin can have its own note while sharing the bytes. The reviewed operation commits notes, claims, index, recent activity, and its UUID log entry together. [Claim evidence](claim-evidence.md)
- **Retrieve** asks for terms, optional filters, and a budget. Native BM25 ranks lexical matches under the selected project. Results include paths, versioned references, and truncation status. The budget counts serialized UTF-8 bytes. Explicit references are reopened and checked against the project before their passages are returned. [Evidence reads](../README.md#find-and-reopen-evidence)
- **Query** answers from the local project. Quick verifies direct evidence, Standard also searches related notes and link neighbors, and Deep probes competing evidence, distinct sources, and gaps. Answers show disagreements and cite retained passages. These reads leave project notes and the operation log untouched.
- **Save** takes the exact answer or excerpt the user selected. It looks for an existing home, preserves the selected wording and evidence, and saves the note and navigation changes together. Ask for a preview to see the proposed changes first. [Reviewed project operations](../README.md#commit-related-notes-together)

## Research, capture a page, or review a decision

- **Autoresearch** agrees on the question, public-source scope or local-only scope, and stopping budget. It starts with local evidence, contacts public sources only with explicit authorization, and returns a dossier with provenance, disagreements, and gaps. A request to file or merge results in its own versioned operation. [Autoresearch skill](../skills/metabrain-autoresearch/SKILL.md)
- **Defuddle** previews capture from a supplied HTTP or HTTPS URL with zero outgoing requests. Supply an HTML or Markdown original to capture locally. The wiki retains the original bytes, and extraction metadata records any requested extraction that actually ran. [Defuddle skill](../skills/metabrain-defuddle/SKILL.md) · [Original-byte recovery](../README.md#capture-and-recover-an-original-file)
- **Think** weighs verified evidence and hypotheses, gives a recommendation and its strongest counterargument, and identifies a test and the result that would change the decision. A request to save it uses the versioned write workflow. [Think skill](../skills/metabrain-think/SKILL.md)

## Maintain a project wiki

- **Lint** runs native link, anchor, orphan, and claim-evidence checks, plus checks for missing wiki properties, empty sections, and unresolved links in known navigation documents. Use `--references` for typed results and request `--check-external` for live public URL checks. The report is read-only. Request a specific repair to apply it as a separate operation, or ask for a preview. [Lint skill](../skills/metabrain-wiki-lint/SKILL.md)
- **Mode** suggests paths under Generic, LYT, PARA, or Zettelkasten. Generic is the default when config is absent. Review the old and new config and activity entries to change the mode. Existing notes keep their paths. [Mode skill](../skills/metabrain-wiki-mode/SKILL.md)
- **Fold** defaults to the latest 16 raw operation entries. If fewer are available, it reports the shortfall without drafting a fold. You can specify a shorter inclusive range. The summary cites each source revision and gets a path derived from those revisions. Repeating a completed fold leaves it as-is. The index, recent activity, and a single new log entry accompany the summary in the reviewed operation. [Fold skill](../skills/metabrain-wiki-fold/SKILL.md)

## Inspect or edit project formats

Use the same pinned store and connection you use for the wiki, with an explicit virtual project root. The following Bash commands preview the fixture's board and saved table and check the decision note's links. Set `store` to the fixture's printed store path. For a daemon-backed store, replace `--no-server` with `--server "$endpoint"` in the common options.

```bash
MB=(mb --store "$store" --no-server)
root=/projects/storage-review
"${MB[@]}" preview "$root/storage.canvas" --project "$root"
"${MB[@]}" preview "$root/decisions.base" --project "$root"
"${MB[@]}" links "$root/decision.md"
```

- **Canvas** validates portable JSON Canvas 1.0 boards and resolves project-relative file targets. A focused edit adds one node while preserving the stacking order and existing unknown fields. [Canvas skill](../skills/metabrain-canvas/SKILL.md)
- **Markdown** uses native properties and citation indexing to check links and open headings or blocks. Embedded targets can be indexed, and percent comments are excluded from citation extraction. Use `mb get` for the original source or an exact passage. Use `mb operation inspect --check-citations` to verify proposed targets and compare their returned passages to the intended evidence. Use `mb links` and `mb lint` after apply. [Markdown skill](../skills/metabrain-markdown/SKILL.md) · [Markdown citations and properties](../README.md#markdown-citations)
- **Bases** previews table columns and row limits with global and view filters applied together. An unsupported filter anywhere in the definition stops the preview before any rows are returned. Report its source expression and preserve it byte-for-byte when editing another field. [Bases skill](../skills/metabrain-bases/SKILL.md)

For Canvas or Bases drafts, add `--body-file DRAFT` to preview the proposed body before inspecting the reviewed operation. These commands work with direct and daemon connections. In the optional MetaBrainExplorer viewer, select the stored board or table in a configured wiki. Click a Canvas file card to open the note. Use **Source** to view its stored JSON or YAML. Version history is available in either the viewer or `mb versions PATH`. [Reviewed project operations](../README.md#commit-related-notes-together) · [Local plan](second-brain-plan.md)

## Try the disposable fixture

Build the checkout with `swift build`, then create and install the disposable fixture.

```sh
scratch="$(mktemp -d)"
python3 Scripts/build-wiki-fixture.py --directory "$scratch/demo" --mb .build/debug/mb
python3 Scripts/install-skills.py --project "$scratch/demo" --apply
```

The builder prints JSON with the selected store and project. Open the new directory in either host, then ask the wiki skill to preview adoption of `/projects/storage-review` in that store. Look for retained custom guides and index, proposed setup documents, and the operation note. Then ask the wiki skill to adopt the project and use the CLI skill to inspect `decision.md` and reopen both reviews' cited passages.

To exercise the evidence workflow, build a separate fixture with `--state empty` and ask to set up the wiki. Ask ingest to preview the two review files from `originals/` and explain the disagreement in one decision. Then ask it to ingest and save the decision. Check that the reported receipt covers both sources, the decision, and navigation. In a fresh session, ask each query depth whether the client should store an offline copy. Ask retrieve for `offline storage` with a small budget, then reopen a returned reference with a larger budget. Select one conclusion with its citations and preview saving it.

The default fixture state, `adopt`, contains two opposing design reviews, a contested decision, the original source files including an opaque binary, a JSON Canvas board, a saved `.base` definition, and a similarly named sibling project. `--state empty` leaves the selected subtree empty and keeps the originals, global guide, and sibling project. `--state initialized` also seeds the configuration, recent summary, and an operation note. The fixture builder requires a new output directory.

With the default or initialized fixture, ask canvas to preview adding a file node linked to `reviews/security-review.md` with subpath `#^result`. Ask Markdown to verify the existing links in `decision.md`. Ask bases to preview `decisions.base` and a draft that changes its table limit to 1. In a separate draft, add an unsupported filter and check that the preview reports it before returning rows.

With the initialized fixture, ask autoresearch for a local-only dossier on offline storage with a two-source budget. Ask think whether to deploy offline storage and look for both reviews and a verification step. For defuddle, preview `https://example.invalid/field-review`, then supply `originals/field-review.md` as the original and review its proposed capture.

```sh
python3 Scripts/test-wiki-skills.py
MB_TEST_SOCKET=1 python3 Scripts/test-wiki-skills.py
```

The second test command adds the same-store CLI comparison over a temporary Unix socket. Use it where local sockets are allowed. `MB_TEST_CLI` and `MB_TEST_DAEMON` can select different built binaries.
