#!/usr/bin/env python3
"""Report native wiki lint and supplemental checks without writing to the store."""

import argparse
import json
from pathlib import Path
import re
import subprocess


ATX = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*)|$)")
SETEXT = re.compile(r"^ {0,3}(=+|-+)\s*$")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
COMMENT = re.compile(r"<!--|-->|(?<!\\)%%")
RULE = re.compile(r"^ {0,3}([*_-])(?: *\1){2,}\s*$")
YAML_TITLE = re.compile(r"""^(?:title|'title'|"title")\s*:\s*(.*?)\s*$""", re.IGNORECASE)


def frontmatter_end(lines):
    if lines and lines[0] == "---":
        return next((index + 1 for index, line in enumerate(lines[1:], 1)
                     if line in ("---", "...")), 0)
    return 0


def markdown_lines(lines, first):
    """Yield top-level Markdown lines, masking fenced syntax and comments."""
    fence = None
    comment_end = None
    for number, line in enumerate(lines[first:], first + 1):
        marker = FENCE.fullmatch(line)
        if fence:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = None
                yield number, ""
            else:
                # Indentation keeps literal code from becoming a Setext title.
                yield number, "    code" if line.strip() else ""
            continue
        if not comment_end and marker and (marker[1][0] == "~" or "`" not in marker[2]):
            fence = marker[1]
            yield number, ""
            continue
        visible = []
        start = 0
        for match in COMMENT.finditer(line):
            if match[0] in ("<!--", "%%") and not comment_end:
                visible.append(line[start:match.start()])
                comment_end = "-->" if match[0] == "<!--" else "%%"
            elif match[0] == comment_end:
                start = match.end()
                comment_end = None
        if not comment_end:
            visible.append(line[start:])
        yield number, "".join(visible)


def markdown_sections(body):
    """Collect top-level ATX and Setext headings and find empty sections."""
    source = body.splitlines()
    first = frontmatter_end(source)
    # Recognize a frontmatter title declaration without interpreting arbitrary YAML.
    title = any(match and match[1] not in ("", "''", '""', "~", "null") and not match[1].startswith("#")
                for match in map(YAML_TITLE.fullmatch, source[1:first - 1])) if first else False
    empty = []
    active = []
    lines = list(markdown_lines(source, first))
    index = 0
    while index < len(lines):
        number, line = lines[index]
        heading = ATX.fullmatch(line)
        underline = SETEXT.fullmatch(lines[index + 1][1]) if index + 1 < len(lines) else None
        if heading:
            level = len(heading[1])
            label = re.sub(r"(?:^|[ \t]+)#+[ \t]*$", "", heading[2] or "").strip()
        elif underline and line.strip() and not line.startswith(("    ", "\t", ">")) and not RULE.fullmatch(line):
            level = 1 if underline[1][0] == "=" else 2
            label = line.strip()
            index += 1
        else:
            if line.strip() and not RULE.fullmatch(line):
                for section in active:
                    section["has_body"] = True
            index += 1
            continue
        while active and active[-1]["level"] >= level:
            section = active.pop()
            if not section["has_body"]:
                empty.append((section["line"], section["heading"]))
        title = title or (level == 1 and bool(label))
        active.append({"level": level, "line": number, "heading": label, "has_body": False})
        index += 1
    empty.extend((section["line"], section["heading"]) for section in active if not section["has_body"])
    return title, sorted(empty)


def findings(run, root, properties, additional_indexes):
    native = run("lint", root, "--orphans")
    indexes = {f"{root}/index.md", f"{root}/_wiki/recent.md", *additional_indexes}
    supplemental = []
    for note in sorted(run("dump", root), key=lambda note: note["path"]):
        path = note["path"]
        if not path.startswith(root + "/") or not note["isCurrent"]:
            continue
        if not path.lower().endswith(".md") and not note.get("markdown"):
            continue
        location = {"sourcePath": path, "sourceVersion": note["version"], "sourceID": note["documentID"]}
        title, empty = markdown_sections(note["body"])
        if path in indexes:
            for link in run("links", path):
                if (link["sourceVersion"], link["sourceID"]) != (note["version"], note["documentID"]):
                    raise ValueError(f"Navigation changed during audit: {path}")
                if link["status"] == "unresolved":
                    supplemental.append({"kind": "staleIndexEntry", **location, "link": link})
        if path == f"{root}/AGENTS.md" or path.startswith(f"{root}/_wiki/") or path in indexes:
            continue
        if not note["body"].strip():
            continue
        for prop in properties:
            value = note.get("title") if prop == "title" else note["metadata"].get(prop)
            if not (isinstance(value, str) and value.strip()) and not (prop == "title" and title):
                supplemental.append({"kind": "missingWikiProperty", **location, "property": prop})
        for number, label in empty:
            supplemental.append({"kind": "emptySection", **location, "line": number, "heading": label})
    return {"native": native, "wikiFindings": supplemental}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mb", default="mb")
    parser.add_argument("--store", required=True)
    connection = parser.add_mutually_exclusive_group(required=True)
    connection.add_argument("--no-server", action="store_true")
    connection.add_argument("--server")
    parser.add_argument("--project", required=True)
    properties = parser.add_mutually_exclusive_group()
    properties.add_argument("--require-property", action="append", metavar="NAME")
    properties.add_argument("--no-required-properties", action="store_true")
    parser.add_argument("--index", action="append", default=[], metavar="VIRTUAL_PATH")
    args = parser.parse_args()
    if not Path(args.store).is_dir():
        parser.error("select an existing store directory")
    segments = args.project.split("/")[1:]
    if not args.project.startswith("/") or any(segment in ("", ".", "..") for segment in segments):
        parser.error("use a normalized project root below /")
    for path in args.index:
        if not path.startswith(args.project + "/") or any(part in ("", ".", "..") for part in path.split("/")[1:]):
            parser.error("--index requires a normalized descendant of the selected project")
    command = [args.mb, "--store", args.store]
    command += ["--no-server"] if args.no_server else ["--server", args.server]

    def run(*arguments):
        result = subprocess.run([*command, *arguments, "--format", "json"], capture_output=True, text=True)
        if result.returncode:
            raise ValueError(result.stderr.strip() or "mb command failed")
        return json.loads(result.stdout)

    required = [] if args.no_required_properties else sorted(set(args.require_property or ["title"]))
    try:
        print(json.dumps(findings(run, args.project, required, args.index), ensure_ascii=False, sort_keys=True))
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
