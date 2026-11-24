---
name: metabrain-wiki-query
description: Answer questions from a selected metaBrain wiki using verified passages, with Quick, Standard, or Deep investigation.
---

Pin the store, connection and project with the [CLI skill](../metabrain-wiki-cli/SKILL.md). Use the [retrieval skill](../metabrain-wiki-retrieve/SKILL.md) to search and verify passages. Respect a requested depth and default to Standard.

- **Quick** reads the named decision or directly relevant hits and verifies their direct evidence. Follow both sides of a recorded disputed claim when it matters to the question.
- **Standard** also searches related terms, reads materially relevant additional notes and link neighbors, and checks those passages for qualifications and disagreement. Use `mb links PATH` and `mb links PATH --incoming` for neighbor candidates. Inspect their paths before reading.
- **Deep** deliberately searches for competing explanations, opposing terms, exceptions and gaps. Read the current decision claims and their recorded states, seek distinct origins and reporting groups, check pinned passages against current sources, and inspect relevant claim findings from `mb lint PROJECT --format json`. Explain unresolved conflicts and what evidence is missing. A readable historical passage can still be ineligible for current acceptance. Report its eligibility and any unavailable evidence explicitly.

Answer the question with a versioned citation for each material factual claim. Separate recorded support and contradiction, label uncertain conclusions, and surface relevant stale, superseded, disputed, or unavailable evidence. A note repeating a source does not make it another independent account. Stay within the selected project. The workflow reads local project knowledge and leaves notes, navigation, and log untouched. Web research and saving require separate requests.
