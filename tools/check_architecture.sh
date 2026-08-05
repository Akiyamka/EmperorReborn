#!/usr/bin/env bash
set -euo pipefail

readonly PROJECT_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

python3 - "${PROJECT_ROOT}" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
scripts = root / "scripts"
files = sorted(scripts.rglob("*.gd"))
failed = False

def code_lines(path, keep_strings=False):
    in_triple = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw
        out = []
        quote = None
        escaped = False
        i = 0
        while i < len(line):
            if in_triple:
                end = line.find(in_triple, i)
                if end < 0:
                    i = len(line)
                    continue
                i = end + 3
                in_triple = None
                continue
            if line.startswith('"""', i) or line.startswith("'''", i):
                in_triple = line[i:i + 3]
                i += 3
                continue
            char = line[i]
            if quote:
                if keep_strings:
                    out.append(char)
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
                i += 1
                continue
            if char in "\"'":
                quote = char
                if keep_strings:
                    out.append(char)
            elif char == "#":
                break
            else:
                out.append(char)
            i += 1
        yield "".join(out)

def report(path, line_number, rule, line):
    global failed
    failed = True
    print(f"{path.relative_to(root)}:{line_number}: {rule}: {line.strip()}", file=sys.stderr)

class_paths = {}
for path in files:
    for line in code_lines(path):
        match = re.search(r"\bclass_name\s+(\w+)", line)
        if match:
            class_paths[match.group(1)] = path

owner_pattern = re.compile(r"\b(?:_facade|_owner|_unit|_source)\._\w+")
facade_sibling_pattern = re.compile(
    r"\b_facade\.(?:runtime_map|planner|avoidance|registry|spatial_hash|"
    r"slot_allocator|path_follower|path_funnel|blocker_tracker|"
    r"ground_navigation|air_navigation)\b"
)
autoload_pattern = re.compile(r"\bget_node_or_null\s*\(\s*[\"']/root/(?:Players|Cursors)[\"']")
for path in files:
    relative = path.relative_to(root).as_posix()
    lines = list(code_lines(path))
    lines_with_strings = list(code_lines(path, keep_strings=True))
    source = "\n".join(lines)
    comment_free_source = "\n".join(code_lines(path, keep_strings=True))
    preloaded_paths = set(re.findall(r"preload\s*\(\s*[\"'](res://[^\"']+)[\"']\s*\)", comment_free_source))
    for number, line in enumerate(lines, 1):
        if owner_pattern.search(line):
            report(path, number, "private owner access", line)
        if facade_sibling_pattern.search(line):
            report(path, number, "navigation sibling access through facade", line)
        if autoload_pattern.search(lines_with_strings[number - 1]):
            if relative != "scripts/players/autoload_lookup.gd":
                report(path, number, "direct autoload path lookup", lines_with_strings[number - 1])
        for name, declaration_path in class_paths.items():
            if declaration_path == path or not re.search(rf"\b{re.escape(name)}\s*\.", line):
                continue
            expected = "res://" + declaration_path.relative_to(root).as_posix()
            if expected not in preloaded_paths:
                report(path, number, f"bare class_name reference {name}", line)

sys.exit(1 if failed else 0)
PY
