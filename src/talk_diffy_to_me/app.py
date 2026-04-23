from __future__ import annotations

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.widgets import Static

from talk_diffy_to_me import zellij
from talk_diffy_to_me.diff import File as DiffFile
from talk_diffy_to_me.widgets.comment_modal import CommentModal
from talk_diffy_to_me.widgets.diff_view import CommentKey, DiffView
from talk_diffy_to_me.widgets.pane_modal import PaneModal
from talk_diffy_to_me.widgets.review_modal import ReviewModal


class TalkDiffyApp(App):
    CSS = """
    Screen { layout: vertical; }
    DiffView { height: 1fr; }
    #status {
        dock: bottom;
        height: 1;
        background: $boost;
        color: $text;
        padding: 0 1;
    }
    """

    BINDINGS = [
        Binding("j", "cursor(1)", "down"),
        Binding("down", "cursor(1)", "down", show=False),
        Binding("k", "cursor(-1)", "up"),
        Binding("up", "cursor(-1)", "up", show=False),
        Binding("shift+j", "hunk(1)", "next hunk"),
        Binding("shift+k", "hunk(-1)", "prev hunk"),
        Binding("g", "top", "top"),
        Binding("shift+g", "bottom", "bottom"),
        Binding("v", "toggle_select", "visual"),
        Binding("escape", "exit_select", show=False),
        Binding("c", "comment", "comment"),
        Binding("d", "delete_comment", "delete"),
        Binding("s", "send", "send"),
        Binding("q", "quit", "quit"),
    ]

    def __init__(self, files: list[DiffFile], dry_run: bool = False) -> None:
        super().__init__()
        self.files = files
        self.dry_run = dry_run
        self._status_msg = ""
        self._dry_run_payload: str | None = None
        self._pane_id: str | None = None

    def compose(self) -> ComposeResult:
        self.diff_view = DiffView(self.files, id="diff")
        yield self.diff_view
        self.status = Static("", id="status")
        yield self.status

    def on_mount(self) -> None:
        self.diff_view.focus()
        self._refresh_status()

    # ---- status ------------------------------------------------------------

    def _refresh_status(self) -> None:
        count = len(self.diff_view.comments)
        path = self.diff_view.current_file_path() or "—"
        line = self.diff_view.current_line()
        ln: int | None = None
        if line is not None:
            ln = line.new_ln if line.new_ln is not None else line.old_ln
        loc = f"{path}:{ln}" if ln is not None else path
        plural = "" if count == 1 else "s"
        extra = f"  ·  {self._status_msg}" if self._status_msg else ""
        self.status.update(f"{count} comment{plural}  ·  {loc}{extra}")

    # ---- actions -----------------------------------------------------------

    def action_cursor(self, delta: int) -> None:
        self.diff_view.move_cursor(delta)
        self._refresh_status()

    def action_hunk(self, delta: int) -> None:
        self.diff_view.jump_hunk(delta)
        self._refresh_status()

    def action_top(self) -> None:
        self.diff_view.go_top()
        self._refresh_status()

    def action_bottom(self) -> None:
        self.diff_view.go_bottom()
        self._refresh_status()

    def action_toggle_select(self) -> None:
        if self.diff_view.selecting:
            self.diff_view.end_selection()
        else:
            self.diff_view.start_selection()
        self._refresh_status()

    def action_exit_select(self) -> None:
        if self.diff_view.selecting:
            self.diff_view.end_selection()
            self._refresh_status()

    def action_comment(self) -> None:
        key = self.diff_view.current_key()
        if key is None:
            return
        fi, hi, s, e = key
        h = self.files[fi].hunks[hi]
        path = self.files[fi].path
        if s == e:
            line = h.lines[s]
            ln = _line_no(line)
            label = f"Comment on {path}:{ln}"
        else:
            ln_s = _line_no(h.lines[s])
            ln_e = _line_no(h.lines[e])
            label = f"Comment on {path}:{ln_s}-{ln_e}  ({e - s + 1} lines)"
        preview = h.lines[s : e + 1]
        existing = self.diff_view.get_comment(key) or ""

        def done(text: str | None) -> None:
            if text:
                self.diff_view.set_comment(key, text)
            self.diff_view.end_selection()
            self._refresh_status()

        self.push_screen(CommentModal(label, existing, preview), done)

    def action_delete_comment(self) -> None:
        keys = self.diff_view.keys_covering_cursor()
        if not keys:
            return
        for k in keys:
            self.diff_view.delete_comment(k)
        self._refresh_status()

    def action_send(self) -> None:
        if not self.diff_view.comments:
            self._status_msg = "no comments to send"
            self._refresh_status()
            return
        self.push_screen(ReviewModal())

    def review_send_keys(
        self,
        keys: list[CommentKey],
        review: ReviewModal | None,
    ) -> None:
        keys = [k for k in keys if k in self.diff_view.comments]
        if not keys:
            return
        if self._pane_id is not None:
            self._send_subset(keys, review)
            return
        self._resolve_pane_then(lambda: self._send_subset(keys, review))

    def _resolve_pane_then(self, then) -> None:
        try:
            panes = zellij.list_panes()
        except zellij.ZellijError as e:
            self._status_msg = f"list-panes failed: {str(e).splitlines()[0]}"
            self._refresh_status()
            return
        self_id = zellij.current_pane_id()
        self_pane = zellij.find_pane(panes, self_id)
        tab_id = self_pane.get("tab_id") if self_pane else None
        candidates = [
            p for p in panes
            if (tab_id is None or p.get("tab_id") == tab_id)
            and str(p.get("id")) != (self_id or "")
        ]
        if not candidates:
            self._status_msg = "no other panes in this tab"
            self._refresh_status()
            return
        claude_panes = [p for p in candidates if _looks_like_claude(p)]
        if len(claude_panes) == 1:
            self._pane_id = str(claude_panes[0].get("id"))
            then()
            return

        def picked(pane_id: str | None) -> None:
            if pane_id is None:
                self._status_msg = "send cancelled"
                self._refresh_status()
                return
            self._pane_id = pane_id
            then()

        self.push_screen(PaneModal(candidates), picked)

    def _send_subset(
        self,
        keys: list[CommentKey],
        review: ReviewModal | None,
    ) -> None:
        subset = {k: self.diff_view.comments[k] for k in keys if k in self.diff_view.comments}
        if not subset:
            return
        payload = bundle_payload(self.files, subset)
        if self.dry_run:
            self._dry_run_payload = payload
            self.exit()
            return
        assert self._pane_id is not None
        try:
            zellij.send_payload(self._pane_id, payload)
            for k in subset:
                self.diff_view.comments.pop(k, None)
            self.diff_view.refresh()
            n = len(subset)
            noun = "comment" if n == 1 else "comments"
            self._status_msg = f"sent {n} {noun} to pane #{self._pane_id}"
        except zellij.ZellijError as e:
            self._status_msg = f"send failed: {str(e).splitlines()[0]}"
        self._refresh_status()
        if review is not None:
            if not self.diff_view.comments:
                review.dismiss(None)
            else:
                review.rebuild()


def _looks_like_claude(pane: dict) -> bool:
    haystack = f"{pane.get('title') or ''} {pane.get('pane_command') or ''}".lower()
    return "claude" in haystack


def _line_no(line) -> int | None:
    return line.new_ln if line.new_ln is not None else line.old_ln


PREAMBLE = (
    "The following are review comments. Respond to questions within this "
    "conversation (not in code comments). Make requested changes."
)


def bundle_payload(files: list[DiffFile], comments: dict[CommentKey, str]) -> str:
    if not comments:
        return ""

    by_file: dict[int, list[tuple[int, int, int, str]]] = {}
    for (fi, hi, s, e), text in comments.items():
        by_file.setdefault(fi, []).append((hi, s, e, text))

    out: list[str] = [PREAMBLE, ""]
    for fi in sorted(by_file):
        f = files[fi]
        out.append(f"## {f.path}")
        for hi, s, e, body in sorted(by_file[fi]):
            h = f.hunks[hi]
            if s == e:
                line = h.lines[s]
                ln = _line_no(line)
                out.append(f"- Line {ln} (`{line.text}`): {body}")
            else:
                ln_s = _line_no(h.lines[s])
                ln_e = _line_no(h.lines[e])
                out.append(f"- Lines {ln_s}-{ln_e}: {body}")
                out.append("  ```")
                for li in range(s, e + 1):
                    ll = h.lines[li]
                    out.append(f"  {ll.kind}{ll.text}")
                out.append("  ```")
        out.append("")
    return "\n".join(out).rstrip() + "\n"
