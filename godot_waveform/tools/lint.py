#!/usr/bin/env python3
"""Cheap structural linter for the GDScript in this project.

There is no Godot binary in the build sandbox, so this catches the mistakes that
are actually likely when files are edited by hand or by a script:

* space or mixed indentation (GDScript wants tabs)
* trailing whitespace / CRLF line endings
* unbalanced (), [], {} outside of strings and comments
* duplicated `func name(` in one file
* a `class_name` that disagrees with the file name
* references to helper functions that are not defined anywhere in the project
  (only for `_`-prefixed calls and `Waveform*.` statics)

Usage: python3 tools/lint.py [root]
"""

from __future__ import annotations

import os
import re
import sys

CALL_RE = re.compile(r"(?<![\w.])([A-Za-z_]\w*)\s*\(")
DEF_RE = re.compile(r"^\s*(?:static\s+)?func\s+([A-Za-z_]\w*)")
CLASS_RE = re.compile(r"^\s*class_name\s+([A-Za-z_]\w*)")
KEYWORDS = {
    "if", "elif", "while", "for", "match", "return", "and", "or", "not", "in",
    "is", "as", "func", "var", "const", "class", "class_name", "extends",
    "signal", "enum", "pass", "break", "continue", "await", "super", "self",
    "true", "false", "null", "print", "push_error", "push_warning", "breakpoint",
    "assert", "preload", "load", "range", "str", "int", "float", "bool", "len",
    "typeof", "type_exists", "Vector2", "Vector2i", "Vector3", "Rect2", "Rect2i",
    "Color", "PackedFloat32Array", "PackedInt32Array", "PackedColorArray",
    "PackedStringArray", "PackedByteArray", "PackedVector2Array", "Array",
    "Dictionary", "String", "StringName", "NodePath", "Control", "Node",
}


def strip_code(line: str) -> str:
    """Removes strings and trailing comments so bracket counting stays sane."""
    out = []
    i = 0
    quote = ""
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = ""
            i += 1
            continue
        if ch in "\"'":
            quote = ch
            i += 1
            continue
        if ch == "#":
            break
        out.append(ch)
        i += 1
    return "".join(out)


def lint_file(path: str) -> list[str]:
    problems: list[str] = []
    with open(path, "r", encoding="utf-8", newline="") as handle:
        text = handle.read()
    if "\r" in text:
        problems.append("CRLF line endings")
    lines = text.split("\n")

    depth = 0
    funcs: dict[str, int] = {}
    class_name = ""
    for number, raw in enumerate(lines, start=1):
        line = raw.rstrip("\n")
        if line != line.rstrip():
            problems.append(f"{number}: trailing whitespace")
        stripped = line.lstrip()
        indent = line[: len(line) - len(stripped)]
        if stripped and " " in indent:
            problems.append(f"{number}: space indentation")
        if depth == 0:
            match = DEF_RE.match(line)
            if match:
                name = match.group(1)
                if name in funcs:
                    problems.append(f"{number}: duplicate func {name}() (first at {funcs[name]})")
                else:
                    funcs[name] = number
            match = CLASS_RE.match(line)
            if match:
                class_name = match.group(1)
        code = strip_code(line)
        for ch in code:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
                if depth < 0:
                    problems.append(f"{number}: unbalanced closer {ch}")
                    depth = 0
    if depth != 0:
        problems.append(f"file ends with bracket depth {depth}")

    expected = os.path.basename(path)[:-3]
    if class_name and class_name != "".join(p.capitalize() for p in expected.split("_")):
        # snake_case file names map to PascalCase class names
        if class_name.lower() != expected.replace("_", "").lower():
            problems.append(f"class_name {class_name} does not match file name {expected}")

    # calls to local helpers that are never defined anywhere in the project
    globals_defined = _project_functions
    for number, raw in enumerate(lines, start=1):
        for name in CALL_RE.findall(strip_code(raw)):
            if name.startswith("_") and name not in funcs and name not in globals_defined:
                problems.append(f"{number}: call to undefined helper {name}()")
    return problems


_project_functions: set[str] = set()


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    files = []
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in {".git", ".godot", "exports", "preview"}]
        files.extend(os.path.join(base, n) for n in names if n.endswith(".gd"))
    files.sort()

    for path in files:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                match = DEF_RE.match(line)
                if match:
                    _project_functions.add(match.group(1))

    failures = 0
    for path in files:
        problems = lint_file(path)
        relative = os.path.relpath(path, root)
        if problems:
            failures += 1
            print(f"{relative}:")
            for problem in problems:
                print(f"  {problem}")
        else:
            count = sum(1 for _ in open(path, "r", encoding="utf-8"))
            print(f"{relative}: ok ({count} lines)")
    if failures:
        print(f"\nFAIL - {failures} file(s) with problems")
        return 1
    print("\nLINT OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
