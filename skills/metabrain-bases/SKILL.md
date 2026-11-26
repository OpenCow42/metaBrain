---
name: metabrain-bases
description: Inspect or make a focused edit to a YAML .base saved table using properties from the selected metaBrain project.
---

# Inspect a saved table

1. Pin the selected store, connection, and project root with the [CLI skill](../metabrain-wiki-cli/SKILL.md). Read the exact YAML body with `mb get PATH --format json`. For an edit, retain the body, revision, and document ID together. Use `mb list ROOT --recursive --format json` to verify project scope for resolved rows.
2. Run `mb preview PATH --project ROOT` using the pinned direct or daemon connection. The supported subset is a YAML table with `order` for column order and `limit` for row count. Combine top-level and view-level `filters` with AND. Supported predicates include `file.inFolder("folder")`, `file.hasTag("tag")`, property equality, and Boolean combinations. Use project-relative folders and property names established from project notes. Table columns can include `file.name` and note properties such as `status`.
3. An unsupported filter anywhere in the definition stops evaluation before any rows are returned. Report the unsupported expression or diagnostic and offer the original source. Always use the native preview to evaluate tables.

# Edit one part of the definition

- Patch the original YAML in a local draft. Preserve comments, unknown fields, and unaffected views. Keep an unsupported filter byte-for-byte when the edit is elsewhere. For example, adjust the selected table's `limit` without rewriting its filters.
- Run `mb preview PATH --project ROOT --body-file DRAFT` before review. If the definition still has an unsupported expression, report it with the source diff. Preserve the original source and make only the requested change.
- Use the [reviewed write workflow](../metabrain-wiki-cli/references/reviewed-write.md) to inspect the whole operation, verify the observed revision, and apply the resulting preview when asked to make the edit. For an explicit preview, show the changes. Inspect retained changes with `mb versions PATH` and `mb get PATH --version VERSION`.
