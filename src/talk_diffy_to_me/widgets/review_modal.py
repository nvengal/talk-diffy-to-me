from __future__ import annotations

from typing import TYPE_CHECKING

from textual.binding import Binding
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import OptionList, Static
from textual.widgets.option_list import Option

from talk_diffy_to_me.widgets.comment_modal import CommentModal
from talk_diffy_to_me.widgets.diff_view import CommentKey

if TYPE_CHECKING:
    from talk_diffy_to_me.app import TalkDiffyApp


class ReviewModal(ModalScreen[None]):
    BINDINGS = [
        Binding("j", "cursor_down", show=False),
        Binding("down", "cursor_down", show=False),
        Binding("k", "cursor_up", show=False),
        Binding("up", "cursor_up", show=False),
        Binding("ctrl+enter", "send_all", "send all", priority=True),
        Binding("shift+s", "send_all", show=False, priority=True),
        Binding("S", "send_all", show=False, priority=True),
        Binding("e", "edit", "edit"),
        Binding("d", "delete", "delete"),
        Binding("escape", "back", "back"),
        Binding("q", "back", show=False),
    ]

    DEFAULT_CSS = """
    ReviewModal {
        align: center middle;
    }
    ReviewModal > Vertical {
        width: 90%;
        height: 70%;
        background: $surface;
        border: tall $accent;
        padding: 1 2;
    }
    ReviewModal #title {
        height: auto;
        color: $text-muted;
    }
    ReviewModal OptionList {
        height: 1fr;
        margin: 1 0;
    }
    ReviewModal #hint {
        height: 1;
        color: $text-muted;
    }
    """

    def __init__(self) -> None:
        super().__init__()
        self._keys: list[CommentKey] = []

    def compose(self):
        with Vertical():
            yield Static("Review comments", id="title")
            yield OptionList(id="list")
            yield Static(
                "enter = send · ctrl+enter / shift+s = send all · e edit · d delete · esc back",
                id="hint",
            )

    def on_mount(self) -> None:
        self.query_one("#list", OptionList).focus()
        self.rebuild()

    # ---- list management ---------------------------------------------------

    def rebuild(self) -> None:
        app = self._ctx()
        self._keys = sorted(app.diff_view.comments.keys())
        ol = self.query_one("#list", OptionList)
        highlighted = ol.highlighted
        ol.clear_options()
        for key in self._keys:
            ol.add_option(Option(self._format(key), id=self._oid(key)))
        if self._keys:
            ol.highlighted = min(highlighted or 0, len(self._keys) - 1)

    def _oid(self, key: CommentKey) -> str:
        return "k:" + ":".join(str(x) for x in key)

    def _format(self, key: CommentKey) -> str:
        app = self._ctx()
        fi, hi, s, e = key
        f = app.files[fi]
        h = f.hunks[hi]
        ln_s = _line_no(h.lines[s])
        ln_e = _line_no(h.lines[e])
        loc = f"{f.path}:{ln_s}" if s == e else f"{f.path}:{ln_s}-{ln_e}"
        body = app.diff_view.comments[key]
        first = body.splitlines()[0] if body else ""
        snippet = first if len(first) <= 80 else first[:77] + "…"
        return f"{loc:<40}  {snippet}"

    def _current_key(self) -> CommentKey | None:
        ol = self.query_one("#list", OptionList)
        idx = ol.highlighted
        if idx is None or idx < 0 or idx >= len(self._keys):
            return None
        return self._keys[idx]

    def _ctx(self) -> "TalkDiffyApp":
        from talk_diffy_to_me.app import TalkDiffyApp
        assert isinstance(self.app, TalkDiffyApp)
        return self.app

    # ---- navigation --------------------------------------------------------

    def action_cursor_down(self) -> None:
        self.query_one("#list", OptionList).action_cursor_down()

    def action_cursor_up(self) -> None:
        self.query_one("#list", OptionList).action_cursor_up()

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        # Enter on the list = send the highlighted comment.
        event.stop()
        self.action_send_one()

    # ---- actions -----------------------------------------------------------

    def action_send_one(self) -> None:
        key = self._current_key()
        if key is None:
            return
        self._ctx().review_send_keys([key], self)

    def action_send_all(self) -> None:
        if not self._keys:
            return
        self._ctx().review_send_keys(list(self._keys), self)

    def action_edit(self) -> None:
        key = self._current_key()
        if key is None:
            return
        app = self._ctx()
        fi, hi, s, e = key
        h = app.files[fi].hunks[hi]
        path = app.files[fi].path
        if s == e:
            line = h.lines[s]
            ln = _line_no(line)
            label = f"Edit comment on {path}:{ln}"
        else:
            ln_s = _line_no(h.lines[s])
            ln_e = _line_no(h.lines[e])
            label = f"Edit comment on {path}:{ln_s}-{ln_e}  ({e - s + 1} lines)"
        preview = h.lines[s : e + 1]
        existing = app.diff_view.comments.get(key, "")

        def done(text: str | None) -> None:
            if text:
                app.diff_view.set_comment(key, text)
            self.rebuild()

        self.app.push_screen(CommentModal(label, existing, preview), done)

    def action_delete(self) -> None:
        key = self._current_key()
        if key is None:
            return
        self._ctx().diff_view.delete_comment(key)
        if not self._ctx().diff_view.comments:
            self.dismiss(None)
            return
        self.rebuild()

    def action_back(self) -> None:
        self.dismiss(None)


def _line_no(line) -> int | None:
    return line.new_ln if line.new_ln is not None else line.old_ln
