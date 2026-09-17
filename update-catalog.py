#!/usr/bin/env python3
"""Regenerate catalog.toml from the plugin.toml of every plugin in this repo.

Noctalia refuses to read a git source without a root catalog.toml, and the rows
have to track each plugin's manifest, so this keeps the two in sync. Run it after
any version/description/tag change and commit the result:

    ./update-catalog.py

Trimmed down from the community-plugins generator: no [[plugin.release]] ladder,
since this repo ships a single plugin_api level rather than older revisions for
older Noctalia builds.
"""

from __future__ import annotations

import subprocess
import sys
import tomllib
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent
CATALOG_PATH = ROOT_DIR / "catalog.toml"
REQUIRED_FIELDS = ("id", "name", "version", "author", "plugin_api", "tags")
OPTIONAL_STRING_FIELDS = ("license", "icon", "description")
OPTIONAL_BOOL_FIELDS = ("deprecated",)

HEADER = """\
# Noctalia plugins catalog.
# Index of every plugin this source ships: the minimum Noctalia needs to render,
# search and compat-check the list before anything is enabled. The per-plugin
# plugin.toml stays authoritative; the host re-reads it on enable.
#
# Noctalia requires this file at the root of a *git* source ("no catalog.toml in
# source '<name>'" otherwise). Keep one [[plugin]] row per plugin subdirectory
# and mirror the fields from that plugin's plugin.toml on every version bump.
# Regenerate with: ./update-catalog.py
"""


def git_output(*args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(ROOT_DIR), *args], capture_output=True, text=True, check=True
    ).stdout


def version_first_shipped(subdir: str, version: str) -> int | None:
    """Commit time of the oldest commit whose plugin.toml carried `version`.

    A later edit that does not bump the version (tags, description, README) must
    not move the date, so the bump commit is what dates the row.
    """
    found = None
    for line in git_output("log", "--format=%H %ct", "--", f"{subdir}/plugin.toml").splitlines():
        revision, _, commit_time = line.partition(" ")
        try:
            manifest = tomllib.loads(git_output("show", f"{revision}:{subdir}/plugin.toml"))
        except (subprocess.CalledProcessError, tomllib.TOMLDecodeError):
            continue
        if manifest.get("version") == version:
            found = int(commit_time)  # keep walking; log is newest-first
    return found


def git_commit_time(subdir: str, *extra_args: str) -> int | None:
    stdout = git_output(
        "log", "-1", *extra_args, "--format=%ct", "--", f"{subdir}/plugin.toml"
    ).strip()
    return int(stdout) if stdout else None


def load_plugin(manifest_path: Path) -> dict:
    with manifest_path.open("rb") as handle:
        manifest = tomllib.load(handle)

    missing = [field for field in REQUIRED_FIELDS if field not in manifest]
    if missing:
        raise ValueError(
            f"{manifest_path.relative_to(ROOT_DIR)} is missing: {', '.join(missing)}"
        )

    row = {field: manifest[field] for field in REQUIRED_FIELDS}
    for field in OPTIONAL_STRING_FIELDS + OPTIONAL_BOOL_FIELDS:
        if field in manifest:
            row[field] = manifest[field]

    # An uncommitted plugin has no history, so fall back to the file's mtime and
    # the catalog can still be generated mid-development.
    subdir = manifest_path.parent.name
    mtime = int(manifest_path.stat().st_mtime)
    row["updated_at"] = version_first_shipped(subdir, row["version"]) or mtime
    row["added_at"] = git_commit_time(subdir, "--diff-filter=A") or row["updated_at"]
    row["_directory"] = subdir
    return row


def toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render(plugins: list[dict]) -> str:
    lines = [HEADER]
    for plugin in plugins:
        lines.append("[[plugin]]")
        lines.append(f"id = {toml_string(plugin['id'])}")
        lines.append(f"name = {toml_string(plugin['name'])}")
        lines.append(f"version = {toml_string(plugin['version'])}")
        lines.append(f"updated_at = {plugin['updated_at']}")
        lines.append(f"added_at = {plugin['added_at']}")
        lines.append(f"author = {toml_string(plugin['author'])}")
        for field in OPTIONAL_STRING_FIELDS:
            if field in plugin:
                lines.append(f"{field} = {toml_string(plugin[field])}")
        if "deprecated" in plugin:
            lines.append(f"deprecated = {'true' if plugin['deprecated'] else 'false'}")
        lines.append(f"plugin_api = {plugin['plugin_api']}")
        lines.append("tags = [" + ", ".join(toml_string(tag) for tag in plugin["tags"]) + "]")
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    plugins = [load_plugin(path) for path in sorted(ROOT_DIR.glob("*/plugin.toml"))]
    if not plugins:
        print("no */plugin.toml found", file=sys.stderr)
        return 1

    CATALOG_PATH.write_text(render(plugins), encoding="utf-8")
    print(f"wrote {CATALOG_PATH.relative_to(ROOT_DIR)} ({len(plugins)} plugin(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
