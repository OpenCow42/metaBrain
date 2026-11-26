---
name: metabrain-wiki-mode
description: Suggest a destination using the selected wiki filing mode or change to that mode.
---

# Read the mode and suggest a destination

Pin the existing store, connection, and virtual root with [the wiki router](../metabrain-wiki/SKILL.md). Read both guides and inspect the exact config path. An absent config selects Generic for suggestions. A connection failure, a folder at the config path, malformed JSON, an unsupported version, or an unrecognized mode blocks the workflow.

Choose a lowercase hyphenated slug and a kind from `note`, `source`, `decision`, `map`, `concept`, `entity`, and `session`. From this skill directory, use `python3 scripts/suggest.py --project "$root" --slug "$slug" --kind "$kind" --config-stdin`, passing the exact config body on standard input. Use `--absent-config` instead only after confirming absence. Use the following filing rules under the virtual root:

| Mode | Suggested filing |
| --- | --- |
| Generic (`generic`) | File by type in `notes/`, `sources/`, `decisions/`, `maps/`, `concepts/`, `entities/`, or `sessions/`. |
| LYT (`lyt`) | Keep one idea per note in `notes/`, preserve originals in `sources/`, and group related ideas in link-based maps in `maps/`. Suggest relevant links to inspected maps and notes. |
| PARA (`para`) | File by actionability. Use `--actionability project` for a current outcome with a finish condition, `area` for a continuing responsibility, `resource` for reference material, or `archive` for inactive material. The folders are `projects/`, `areas/`, `resources/`, and `archives/`. Ask when the user's intended use would change the choice and cannot be inferred. |
| Zettelkasten (`zettelkasten`) | Put single-idea notes and concepts in `zettels/` with a UTC timestamp, a random UUID suffix before the slug, and related-note links. The helper generates the time-sortable, collision-resistant name. Other kinds keep their type folders. |

Apply any more specific project guidance and explain the suggestion with the selected mode and kind or actionability. Check the proposed path and ancestors for collisions, and show them before filing. A suggestion alone performs no writes.

# Change the mode

1. Require an initialized wiki. Confirm the current config is usable, retain its document ID and version, and compare the requested mode with the existing one. If unchanged, report that and skip the operation. For an uninitialized project, route to setup before changing mode.
2. Replace only the `mode` property in the parsed JSON object, preserving other keys and the config document's fields. Use the [reviewed write workflow](../metabrain-wiki-cli/references/reviewed-write.md) for that replacement, a focused recent activity entry, and one new append-only operation record. Record the exact old and new mode values and config path. Show the old and new config for a preview, with a representative filing suggestion under each mode using the same input. If a representative PARA suggestion needs more context, state the example actionability. A mode change applies to future suggestions and keeps existing paths in place.
3. Apply the exact inspected preview when asked to change the mode. For a conflict, reread the config and rebuild the operation if the requested mode is still clear. Repeat planning after a successful change will report that the requested mode is already active.
