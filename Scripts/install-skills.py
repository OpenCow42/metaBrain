#!/usr/bin/env python3
"""Preview or install the bundled skills into one local project."""

import argparse
import shutil
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[1] / "skills"
HOSTS = (".agents", ".claude")


def inventory(directory):
    """Return matching paths and file contents, rejecting links and special files."""
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"Expected a regular directory: {directory}")
    entries = {}
    for child in sorted(directory.iterdir()):
        if child.is_symlink():
            raise ValueError(f"Symbolic link: {child}")
        if child.is_dir():
            entries[child.name] = inventory(child)
        elif child.is_file():
            entries[child.name] = child.read_bytes()
        else:
            raise ValueError(f"Unsupported file: {child}")
    return entries


def plan(project):
    skills = sorted(SOURCE.glob("metabrain-*"))
    if not skills:
        raise ValueError("No bundled skills found.")
    manifests = {skill: inventory(skill) for skill in skills}
    for skill, contents in manifests.items():
        if not isinstance(contents.get("SKILL.md"), bytes):
            raise ValueError(f"Missing SKILL.md: {skill}")

    pending = []
    conflicts = []
    for host in HOSTS:
        host_path = project / host
        destination = host_path / "skills"
        for directory in (host_path, destination):
            if directory.is_symlink() or (directory.exists() and not directory.is_dir()):
                conflicts.append(f"Blocked directory: {directory}")
                break
        else:
            for skill, contents in manifests.items():
                target = destination / skill.name
                if not target.is_symlink() and not target.exists():
                    print(f"add       {target}")
                    pending.append((skill, target))
                    continue
                try:
                    identical = inventory(target) == contents
                except (OSError, ValueError):
                    identical = False
                if identical:
                    print(f"installed {target}")
                else:
                    conflicts.append(f"Skill already exists with different contents: {target}")
    if conflicts:
        raise ValueError("\n".join(conflicts))
    return pending


def install(pending):
    created_dirs = []
    created_skills = []
    try:
        for source, target in pending:
            for directory in (target.parent.parent, target.parent):
                try:
                    directory.mkdir()
                except FileExistsError:
                    if directory.is_symlink() or not directory.is_dir():
                        raise
                else:
                    created_dirs.append(directory)
            # Reserve the name without replacing a directory added after planning.
            target.mkdir()
            created_skills.append(target)
            shutil.copytree(source, target, dirs_exist_ok=True)
    except (OSError, KeyboardInterrupt):
        for directory in reversed(created_skills):
            shutil.rmtree(directory)
        for directory in reversed(created_dirs):
            if not any(directory.iterdir()):
                directory.rmdir()
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True, help="Existing local project directory")
    parser.add_argument("--apply", action="store_true", help="Install the previewed copies")
    args = parser.parse_args()
    try:
        project = args.project.resolve(strict=True)
        if not project.is_dir():
            raise ValueError(f"Expected a project directory: {project}")
        pending = plan(project)
        if args.apply:
            install(pending)
            print(f"Copied {len(pending)} skill directories.")
        else:
            print("Preview only. Pass --apply to install.")
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
