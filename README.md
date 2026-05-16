# metaBrain

`metaBrain` is an early-stage Swift project for building an AI-native memory and knowledge store.

The goal is to help AI tools store, retrieve, discover, and navigate large bodies of content without being limited to loose `.json`, `.jsonl`, and `.md` files scattered through folders. The long-term direction is a compressed NoSQL-style store that remains as discoverable to AI tools as a filesystem while supporting richer structure, indexing, metadata, relationships, and search.

## Project Shape

This repository is a Swift package with three products:

- `MetaBrainCore`: the shared library where storage, indexing, retrieval, and domain behavior should live.
- `metabrain`: the command-line tool.
- `MetaBrainApp`: a SwiftUI app target for a graphical interface.

The CLI and app should stay thin. Shared behavior belongs in `MetaBrainCore` so every interface uses the same underlying model.

## Requirements

- Swift 6.3 or newer
- macOS 14 or newer

## Build

```bash
swift build
```

## Run The CLI

```bash
swift run metabrain "hello"
```

## Run The App

```bash
swift run MetaBrainApp
```

The SwiftUI app target is useful for local development. A polished distributable app may later move to an Xcode app project that depends on `MetaBrainCore`.

## Testing Philosophy

Deep automated testing is a cornerstone of the project.

The shared library and CLI-facing logic should strive for 100% coverage. The UI app should strive for 80-90% coverage. As the storage layer grows, tests should make subtle failures visible: missed content, broken indexes, corrupted migrations, incomplete retrieval, and misleading metadata.

## Project Documents

- [MANIFESTO.md](MANIFESTO.md) explains the project vision and principles.
- [AGENTS.md](AGENTS.md) defines repository rules for coding agents and contributors.
