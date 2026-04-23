from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Literal

LineKind = Literal["+", "-", " "]

HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$")


@dataclass
class DiffLine:
    kind: LineKind
    text: str
    old_ln: int | None
    new_ln: int | None


@dataclass
class Hunk:
    header: str
    old_start: int
    old_count: int
    new_start: int
    new_count: int
    lines: list[DiffLine] = field(default_factory=list)


@dataclass
class File:
    path: str
    old_path: str | None
    status: str  # modified | added | deleted | renamed
    hunks: list[Hunk] = field(default_factory=list)
    binary: bool = False


def parse(text: str) -> list[File]:
    files: list[File] = []
    current: File | None = None
    hunk: Hunk | None = None
    old_ln = 0
    new_ln = 0

    for raw in text.splitlines():
        if raw.startswith("diff --git "):
            parts = raw.split(" ")
            a = parts[2][2:] if parts[2].startswith("a/") else parts[2]
            b = parts[3][2:] if parts[3].startswith("b/") else parts[3]
            current = File(
                path=b,
                old_path=a if a != b else None,
                status="modified",
            )
            files.append(current)
            hunk = None
            continue

        if current is None:
            continue

        if raw.startswith("new file mode"):
            current.status = "added"
        elif raw.startswith("deleted file mode"):
            current.status = "deleted"
            if current.old_path:
                current.path = current.old_path
        elif raw.startswith("rename from "):
            current.status = "renamed"
            current.old_path = raw[len("rename from "):]
        elif raw.startswith("rename to "):
            current.path = raw[len("rename to "):]
        elif raw.startswith("Binary files"):
            current.binary = True
        elif raw.startswith("--- ") or raw.startswith("+++ ") or raw.startswith("index "):
            continue
        elif raw.startswith("@@"):
            m = HUNK_RE.match(raw)
            if not m:
                continue
            os_, oc_, ns_, nc_, _suffix = m.groups()
            hunk = Hunk(
                header=raw,
                old_start=int(os_),
                old_count=int(oc_) if oc_ is not None else 1,
                new_start=int(ns_),
                new_count=int(nc_) if nc_ is not None else 1,
            )
            current.hunks.append(hunk)
            old_ln = hunk.old_start
            new_ln = hunk.new_start
        elif hunk is not None:
            if raw.startswith("\\"):
                continue  # "\ No newline at end of file"
            if raw.startswith("+"):
                hunk.lines.append(DiffLine("+", raw[1:], old_ln=None, new_ln=new_ln))
                new_ln += 1
            elif raw.startswith("-"):
                hunk.lines.append(DiffLine("-", raw[1:], old_ln=old_ln, new_ln=None))
                old_ln += 1
            elif raw.startswith(" "):
                hunk.lines.append(DiffLine(" ", raw[1:], old_ln=old_ln, new_ln=new_ln))
                old_ln += 1
                new_ln += 1
            elif raw == "":
                # empty context line (git sometimes strips the leading space)
                hunk.lines.append(DiffLine(" ", "", old_ln=old_ln, new_ln=new_ln))
                old_ln += 1
                new_ln += 1

    return files
