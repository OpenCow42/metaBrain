# metaBrain Manifesto

`metaBrain` exists to give AI systems a richer place to remember.

AI tools need to store and access more than short prompts, loose notes, and scattered exports. They need a memory substrate that can hold large bodies of content, preserve structure, expose relationships, and stay easy to discover from the outside. A useful AI memory should feel navigable, inspectable, and queryable, not like a pile of disconnected files.

The project starts from a simple belief: flat `.json`, `.jsonl`, and `.md` files in folders are a good beginning, but they should not be the ceiling. They are easy to inspect, yet they become awkward when content grows, when metadata matters, when relationships become important, or when retrieval needs to be fast and precise.

`metaBrain` aims to move beyond that flat-file model with a compressed NoSQL-style store designed for AI-native content. The store should support richer structure, indexing, metadata, relationships, and search while remaining approachable to developer tools and AI agents.

The goal is not to hide knowledge inside an opaque database. The goal is to make a more capable store feel as discoverable to AI tools as a filesystem: understandable paths, inspectable records, predictable commands, searchable content, and clear ways to move from overview to detail.

## Principles

- Store content in forms that can scale beyond loose files and folders.
- Keep knowledge discoverable, inspectable, and navigable by AI tools.
- Preserve enough structure and metadata to make retrieval meaningful.
- Prefer durable, compressed storage for large collections of content.
- Build interfaces that let the CLI, app, and future tools share the same core behavior.
- Treat correctness, migration safety, and retrieval quality as first-class project concerns.

## Stability

Deep automated testing is a foundation of this project, not a finishing touch.

The shared library and CLI-facing logic should strive for 100% coverage because they will hold the core storage, indexing, and retrieval guarantees. The UI app should strive for 80-90% coverage so user workflows remain stable while leaving room for pragmatic visual and interaction testing.

If `metaBrain` becomes a memory layer for AI systems, its failures will be subtle: missed content, broken indexes, corrupted migrations, incomplete retrieval, or misleading metadata. The project should grow with tests that make those failures difficult to introduce and easy to diagnose.
