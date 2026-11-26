---
name: metabrain-save
description: Save the answer, decision, or insight the user selected into a metaBrain project wiki with its supporting evidence.
---

Pin the project with the [CLI skill](../metabrain-wiki-cli/SKILL.md) and use [reviewed wiki writes](../metabrain-wiki-cli/references/reviewed-write.md).

- Identify the exact answer, conclusion, or excerpt the user selected. Preserve its wording, relevant qualifiers, and versioned citations. Leave unrelated turns and transcript material out. Use the [retrieval skill](../metabrain-wiki-retrieve/SKILL.md) to reopen cited passages and check project scope. Retain applicable support and contradiction and surface unavailable citations as such. Ask for the selected material if it is genuinely ambiguous.
- Search the project for the topic and read likely destination notes. Prefer a focused addition to an existing home when it fits, or propose a distinct note with a descriptive path. Skip an identical saved selection with the same evidence. Preserve existing fields and unrelated text. If maintaining structured claims, preserve their IDs and use verified references and accurate claim states.
- Keep verified retained references clickable in the saved Markdown with `[Source](metabrain-ref:REF)`. Inspect the chosen text, citations, destination, index, recent summary, and UUID log in one operation. Apply when asked to save. For a preview request, report the proposed changes.
