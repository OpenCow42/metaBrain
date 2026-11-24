# Project wiki skills

`metabrain-wiki` previews setup or adoption of a project wiki. `metabrain-wiki-cli` reads notes, searches for evidence, and follows links through `mb`. See the [delivery plan](second-brain-plan.md) for the remaining workflow.

## Install into a project

From the metaBrain checkout, run this with Python 3 and an existing local project directory.

```sh
python3 Scripts/install-skills.py --project /path/to/project
python3 Scripts/install-skills.py --project /path/to/project --apply
```

The first command previews. The second copies the canonical directories from [skills](../skills/) to the selected project's `.agents/skills/` and `.claude/skills/`. Identical copies are skipped on rerun. A differing package with the same name or a blocked destination stops the install for both hosts. Review a conflicting project copy yourself before trying again. The installer leaves global agent settings and unrelated project skills alone.

Start a session in the selected project with `mb` on your executable search path. In Codex, use `$metabrain-wiki` or `$metabrain-wiki-cli` from the skill picker. In Claude Code, use `/metabrain-wiki` or `/metabrain-wiki-cli` from the slash menu. Use a new session if skill discovery has yet to refresh. [Codex skill discovery](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills) · [Claude Code skill discovery](https://code.claude.com/docs/en/skills#where-skills-live)

## Set up or adopt a wiki

Ask the wiki skill to preview setup, giving it an existing store path and a virtual project root below `/`, such as `/projects/storage-review`. Direct access uses `--no-server`. For a daemon-backed store, give the Unix socket or loopback endpoint explicitly. The skill uses the selected connection and reads the store's virtual `/AGENTS.md` and the project's optional `AGENTS.md`.

The preview proposes missing documents, preserves existing project content and custom guidance, and reports occupied reserved paths. A usable Markdown `index.md` can be adopted as-is. The workflow stops for an invalid configuration or incompatible reserved paths. Review the proposed operation before authorizing apply.

| Virtual path under the project root | Purpose |
| --- | --- |
| `_wiki/config.json` | A document with a JSON body such as `{"version":1,"mode":"generic"}`. The recognized modes are `generic`, `lyt`, `para`, and `zettelkasten`. |
| `index.md` | Project navigation. |
| `_wiki/recent.md` | Recent activity summary. |
| `_wiki/operations/<operation-UUID>.md` | An append-only Markdown record written in the same reviewed project operation as its related changes. |

For read-only evidence, invoke the CLI skill and specify the same store and project. It lists or searches within the selected project and reopens a versioned reference before quoting. [Reviewed project operations](../README.md#commit-related-notes-together) · [Evidence reads](../README.md#find-and-reopen-evidence)

## Try the disposable fixture

From a source checkout with `swift build` completed:

```sh
scratch="$(mktemp -d)"
python3 Scripts/build-wiki-fixture.py --directory "$scratch/demo" --mb .build/debug/mb
python3 Scripts/install-skills.py --project "$scratch/demo" --apply
```

The builder prints JSON with the selected store and project. Open the new directory in either host, then ask the wiki skill to preview adoption of `/projects/storage-review` in that store. Look for retained custom guides and index, proposed setup documents, and the operation note. After reviewing the preview, you can authorize it and use the CLI skill to inspect `decision.md` and reopen both reviews' cited passages.

The default fixture state, `adopt`, contains two opposing design reviews, a contested decision, the original source files including an opaque binary, a JSON Canvas board, a saved `.base` definition, and a similarly named sibling project. `--state empty` leaves the selected subtree empty and keeps the originals, global guide, and sibling project. `--state initialized` also seeds the configuration, recent summary, and an operation note. The fixture builder requires a new output directory.

```sh
python3 Scripts/test-wiki-skills.py
MB_TEST_SOCKET=1 python3 Scripts/test-wiki-skills.py
```

The second test command adds the same-store CLI comparison over a temporary Unix socket. Use it where local sockets are allowed. `MB_TEST_CLI` and `MB_TEST_DAEMON` can select different built binaries.
