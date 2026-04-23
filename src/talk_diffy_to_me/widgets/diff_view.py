from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from rich.segment import Segment
from rich.style import Style
from textual.geometry import Region, Size
from textual.scroll_view import ScrollView
from textual.strip import Strip

from talk_diffy_to_me.diff import DiffLine, File as DiffFile


RowKind = Literal["file_header", "hunk_header", "diff_line"]


@dataclass
class Row:
    kind: RowKind
    text: str
    file_idx: int | None = None
    hunk_idx: int | None = None
    line_idx: int | None = None


# (file_idx, hunk_idx, start_line_idx, end_line_idx) — end is inclusive.
# A single-line comment has start == end.
CommentKey = tuple[int, int, int, int]


class DiffView(ScrollView):
    can_focus = True

    def __init__(self, files: list[DiffFile], **kwargs) -> None:
        super().__init__(**kwargs)
        self.files = files
        self.rows: list[Row] = []
        for fi, f in enumerate(files):
            label = f.path if f.status == "modified" else f"{f.path} ({f.status})"
            self.rows.append(Row("file_header", label, file_idx=fi))
            if f.binary:
                self.rows.append(Row("hunk_header", "(binary)", file_idx=fi))
                continue
            for hi, h in enumerate(f.hunks):
                self.rows.append(Row("hunk_header", h.header, file_idx=fi, hunk_idx=hi))
                for li, line in enumerate(h.lines):
                    body = f"{line.kind}{line.text}"
                    self.rows.append(
                        Row("diff_line", body, file_idx=fi, hunk_idx=hi, line_idx=li)
                    )
        self.cursor: int = self._first_commentable()
        self.selection_anchor: int | None = None
        self.comments: dict[CommentKey, str] = {}
        max_w = max((len(r.text) + 10 for r in self.rows), default=80)
        self.virtual_size = Size(max(max_w, 1), len(self.rows))

    def _first_commentable(self) -> int:
        for i, r in enumerate(self.rows):
            if r.kind == "diff_line":
                return i
        return 0

    # ---- rendering ---------------------------------------------------------

    def render_line(self, y: int) -> Strip:
        scroll_x, scroll_y = self.scroll_offset
        idx = y + int(scroll_y)
        width = self.size.width
        if idx < 0 or idx >= len(self.rows):
            return Strip.blank(width)
        segments = self._render_row(idx, width)
        strip = Strip(segments)
        return strip.crop(int(scroll_x), int(scroll_x) + width)

    def _render_row(self, idx: int, width: int) -> list[Segment]:
        row = self.rows[idx]
        is_cursor = idx == self.cursor
        is_selected = self._in_selection(idx)
        base: Style
        body: str
        if row.kind == "file_header":
            body = f"── {row.text}"
            base = Style(color="cyan", bold=True)
        elif row.kind == "hunk_header":
            body = f"  {row.text}"
            base = Style(color="magenta")
        else:
            assert row.file_idx is not None and row.hunk_idx is not None and row.line_idx is not None
            line = self.files[row.file_idx].hunks[row.hunk_idx].lines[row.line_idx]
            ln = line.new_ln if line.new_ln is not None else line.old_ln
            gutter = f"{ln if ln is not None else '':>5}"
            marker = "▸ " if self._is_commented(row) else "  "
            body = f"{marker}{gutter} {row.text}"
            if line.kind == "+":
                base = Style(color="green")
            elif line.kind == "-":
                base = Style(color="red")
            else:
                base = Style()
        if is_cursor:
            style = base + Style(bgcolor="grey35")
        elif is_selected:
            style = base + Style(bgcolor="grey19")
        else:
            style = base
        padded = body[:width].ljust(width) if len(body) >= width else body.ljust(width)
        return [Segment(padded, style)]

    def _is_commented(self, row: Row) -> bool:
        if row.file_idx is None or row.hunk_idx is None or row.line_idx is None:
            return False
        for (fi, hi, s, e) in self.comments:
            if fi == row.file_idx and hi == row.hunk_idx and s <= row.line_idx <= e:
                return True
        return False

    def _in_selection(self, idx: int) -> bool:
        if self.selection_anchor is None:
            return False
        lo, hi = sorted((self.cursor, self.selection_anchor))
        return lo <= idx <= hi

    # ---- cursor navigation -------------------------------------------------

    @property
    def selecting(self) -> bool:
        return self.selection_anchor is not None

    def _anchor_hunk(self) -> tuple[int, int] | None:
        if self.selection_anchor is None:
            return None
        a = self.rows[self.selection_anchor]
        if a.file_idx is None or a.hunk_idx is None:
            return None
        return (a.file_idx, a.hunk_idx)

    def _in_anchor_hunk(self, idx: int) -> bool:
        anchor = self._anchor_hunk()
        if anchor is None:
            return True
        r = self.rows[idx]
        return (r.file_idx, r.hunk_idx) == anchor

    def move_cursor(self, delta: int) -> None:
        step = 1 if delta > 0 else -1
        new = self.cursor
        for _ in range(abs(delta)):
            c = new + step
            while 0 <= c < len(self.rows) and self.rows[c].kind != "diff_line":
                c += step
            if not (0 <= c < len(self.rows)):
                break
            if not self._in_anchor_hunk(c):
                break  # visual-mode clamp
            new = c
        self._set_cursor(new)

    def jump_hunk(self, delta: int) -> None:
        if self.selecting or not self.rows:
            return
        cur = self.rows[self.cursor]
        global_hunks: list[tuple[int, int]] = [
            (fi, hi) for fi, f in enumerate(self.files) for hi in range(len(f.hunks))
        ]
        if not global_hunks:
            return
        if cur.file_idx is not None and cur.hunk_idx is not None:
            try:
                gi = global_hunks.index((cur.file_idx, cur.hunk_idx))
            except ValueError:
                gi = 0
        else:
            gi = 0
        gi = max(0, min(len(global_hunks) - 1, gi + (1 if delta > 0 else -1)))
        tfi, thi = global_hunks[gi]
        for i, r in enumerate(self.rows):
            if r.kind == "diff_line" and r.file_idx == tfi and r.hunk_idx == thi:
                self._set_cursor(i)
                return

    def go_top(self) -> None:
        if self.selecting:
            anchor = self._anchor_hunk()
            if anchor is not None:
                for i, r in enumerate(self.rows):
                    if r.kind == "diff_line" and (r.file_idx, r.hunk_idx) == anchor:
                        self._set_cursor(i)
                        return
        self._set_cursor(self._first_commentable())

    def go_bottom(self) -> None:
        if self.selecting:
            anchor = self._anchor_hunk()
            if anchor is not None:
                last = self.cursor
                for i, r in enumerate(self.rows):
                    if r.kind == "diff_line" and (r.file_idx, r.hunk_idx) == anchor:
                        last = i
                self._set_cursor(last)
                return
        for i in range(len(self.rows) - 1, -1, -1):
            if self.rows[i].kind == "diff_line":
                self._set_cursor(i)
                return

    def _set_cursor(self, idx: int) -> None:
        if idx == self.cursor:
            return
        self.cursor = idx
        self.scroll_to_region(Region(0, idx, self.size.width or 1, 1))
        self.refresh()

    # ---- selection ---------------------------------------------------------

    def start_selection(self) -> None:
        if self.rows and self.rows[self.cursor].kind == "diff_line":
            self.selection_anchor = self.cursor
            self.refresh()

    def end_selection(self) -> None:
        if self.selection_anchor is not None:
            self.selection_anchor = None
            self.refresh()

    # ---- accessors ---------------------------------------------------------

    def current_row(self) -> Row | None:
        if not self.rows:
            return None
        return self.rows[self.cursor]

    def current_line(self) -> DiffLine | None:
        row = self.current_row()
        if row is None or row.kind != "diff_line":
            return None
        assert row.file_idx is not None and row.hunk_idx is not None and row.line_idx is not None
        return self.files[row.file_idx].hunks[row.hunk_idx].lines[row.line_idx]

    def current_file_path(self) -> str | None:
        row = self.current_row()
        if row is None or row.file_idx is None:
            return None
        return self.files[row.file_idx].path

    def current_key(self) -> CommentKey | None:
        row = self.current_row()
        if row is None or row.kind != "diff_line":
            return None
        assert row.file_idx is not None and row.hunk_idx is not None and row.line_idx is not None
        if self.selection_anchor is not None:
            a = self.rows[self.selection_anchor]
            if a.file_idx == row.file_idx and a.hunk_idx == row.hunk_idx:
                assert a.line_idx is not None
                s, e = sorted((a.line_idx, row.line_idx))
                return (row.file_idx, row.hunk_idx, s, e)
        return (row.file_idx, row.hunk_idx, row.line_idx, row.line_idx)

    def keys_covering_cursor(self) -> list[CommentKey]:
        row = self.current_row()
        if row is None or row.kind != "diff_line":
            return []
        assert row.file_idx is not None and row.hunk_idx is not None and row.line_idx is not None
        return [
            k for k in self.comments
            if k[0] == row.file_idx and k[1] == row.hunk_idx and k[2] <= row.line_idx <= k[3]
        ]

    # ---- comments ----------------------------------------------------------

    def get_comment(self, key: CommentKey) -> str | None:
        return self.comments.get(key)

    def set_comment(self, key: CommentKey, text: str) -> None:
        self.comments[key] = text
        self.refresh()

    def delete_comment(self, key: CommentKey) -> None:
        if key in self.comments:
            del self.comments[key]
            self.refresh()

    def clear_comments(self) -> None:
        self.comments.clear()
        self.refresh()
