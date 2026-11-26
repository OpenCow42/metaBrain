---
name: metabrain-markdown
description: Read or edit a metaBrain Markdown note with properties, links, headings, blocks, embeds, and percent comments.
---

# Read and verify Markdown

Pin the selected store, connection, and project root with the [CLI skill](../metabrain-wiki-cli/SKILL.md). Markdown indexing covers `.md` documents and documents explicitly marked as Markdown. Read `mb get PATH --format json` to retain the exact body, revision, and document ID as the basis for any edit.

- Flat YAML frontmatter between `---` lines supports scalar and flat list properties. A `tags` scalar or list adds tag postings. Explicit store metadata takes precedence over matching frontmatter keys in metadata filters. Check with `mb search --path-prefix ROOT/ --view refs --tag TAG --meta status=contested`. Keep frontmatter and separately stored tags and metadata when editing the body.
- Use one-line wiki and Markdown links. Use an unambiguous project target for wiki links, such as `[[/projects/storage-review/reviews/field-review.md#^result]]`. A target heading can be linked with `#Heading`; terminate a block with a stable ID such as `^result` to cite it with `#^result`. Relative Markdown links resolve from the source note. A standalone `^id` after a closed top-level fence labels its literal contents, including when blank lines separate the marker from the closing fence. A retained citation can be linked in the store as `[Source](metabrain-ref:REF)`, using the exact `REF` verified by `mb get --ref`. An embed such as `![[note.md#^result]]` is indexed as a link occurrence. Text inside `%% ... %%` comments and code examples is ignored by citation indexing.
- Use `mb links PATH` for outgoing occurrences and `mb links TARGET --incoming` for backlinks. Check resolved target paths against `mb list ROOT --recursive --format json` before opening them. Read cited content with `mb get TARGET --heading HEADING`, `mb get TARGET --block ID`, or a retained `mb get --ref REF` for exact evidence. Use `mb lint PATH` for current link and anchor findings.

Indexing lets you verify link targets and search properties. Display can use the original markup, so verify a passage by opening it and preserve embeds and comments when editing unrelated text.

# Make a focused edit

1. Edit the original body in a local draft. Show the exact diff when the user asks for a preview. Preserve unrelated syntax, headings, stable block IDs, and citations. Check changed link targets against the scoped `mb list ROOT --recursive --format json` output and open their headings or blocks with `mb get TARGET --heading HEADING` or `mb get TARGET --block ID`. Check a changed anchor in the local draft when it belongs to the note being edited. If you generated a unified diff, `mb patch PATH --patch-file DIFF --check` can validate that it applies to the existing body.
2. Use `mb operation inspect DRAFT --check-citations` and the [versioned write workflow](../metabrain-wiki-cli/references/reviewed-write.md). Compare the returned target passages with the evidence the edit should cite. Apply the inspected preview for a requested edit.
3. After apply, verify the indexed links with `mb links PATH` and check for anchor or link findings with `mb lint PATH`. Inspect retained changes with `mb versions PATH` and `mb get PATH --version VERSION`.
