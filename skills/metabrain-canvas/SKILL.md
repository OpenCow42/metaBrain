---
name: metabrain-canvas
description: Inspect a portable JSON Canvas board in a metaBrain project or make a focused edit that adds one node.
---

# Inspect the board

1. Pin the selected store, connection, and project root with the [CLI skill](../metabrain-wiki-cli/SKILL.md). Read the board via `mb get PATH --format json`. Record its revision and document ID with its exact body. Use `mb list ROOT --recursive --format json` to check the board and any resolved file targets against the selected project.
2. Run `mb preview PATH --project ROOT` with the same connection options. Summarize the text, file, link, and group nodes and their edges. Report malformed source, invalid IDs, missing edge endpoints, or unresolved project file targets. If the preview cannot render the board, offer the original source from the read.

# Add one node

- Edit the original [JSON Canvas 1.0](https://jsoncanvas.org/spec/1.0/) source in a local draft. Preserve existing raw node and edge objects, unknown fields at every level, and the existing node array order, which determines stacking. Append the new node to place it on top, unless the user specifies another stacking position. Leave unrelated text and layout untouched.
- Use a unique node ID and integer `x`, `y`, `width`, and `height`. For a file node, use the resolved project-relative `file` path, such as `reviews/field-review.md`. An optional `subpath` starts with `#`, such as `#^result` for a block. Verify the target through the scoped listing and check an anchor with `mb get TARGET --heading HEADING` or `mb get TARGET --block ID`. Preserve existing edges and check that their IDs are unique and both endpoints name existing nodes. Limit the edit to the requested node.
- Run `mb preview PATH --project ROOT --body-file DRAFT` before review using the pinned direct or daemon connection. Address findings in the requested edit and report existing findings without rewriting unrelated source. Show the source change and verified destination. Use the [reviewed write workflow](../metabrain-wiki-cli/references/reviewed-write.md) to inspect the whole operation, verify the observed revision, and apply the resulting preview when asked to make the edit. For an explicit preview, show the changes. Inspect retained changes with `mb versions PATH` and `mb get PATH --version VERSION`.
