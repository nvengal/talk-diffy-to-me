from __future__ import annotations

from rich.text import Text
from textual.binding import Binding
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Static, TextArea

from talk_diffy_to_me.diff import DiffLine


class CommentModal(ModalScreen[str | None]):
    BINDINGS = [
        Binding("escape", "cancel", "cancel"),
        Binding("enter", "save", "save", priority=True),
        Binding("ctrl+s", "save", show=False),
        Binding("ctrl+enter", "newline", "newline"),
        Binding("ctrl+j", "newline", show=False),
    ]

    DEFAULT_CSS = """
    CommentModal {
        align: center middle;
    }
    CommentModal > Vertical {
        width: 80%;
        height: 60%;
        background: $surface;
        border: tall $accent;
        padding: 1 2;
    }
    CommentModal #label {
        height: auto;
        color: $text-muted;
    }
    CommentModal #preview {
        height: auto;
        max-height: 12;
        padding: 0 1;
        margin: 1 0 0 0;
        border: round $panel;
        overflow-y: auto;
    }
    CommentModal #ta {
        height: 1fr;
        margin: 1 0;
    }
    CommentModal #hint {
        height: 1;
        color: $text-muted;
    }
    """

    def __init__(
        self,
        label: str,
        initial: str = "",
        preview_lines: list[DiffLine] | None = None,
    ) -> None:
        super().__init__()
        self._label = label
        self._initial = initial
        self._preview_lines = preview_lines or []

    def compose(self):
        with Vertical():
            yield Static(self._label, id="label")
            if self._preview_lines:
                yield Static(self._build_preview(), id="preview")
            yield TextArea(self._initial, id="ta")
            yield Static(
                "enter = save · ctrl+enter (or ctrl+j) = newline · esc = cancel",
                id="hint",
            )

    def on_mount(self) -> None:
        ta = self.query_one("#ta", TextArea)
        ta.focus()
        ta.move_cursor(ta.document.end)

    def _build_preview(self) -> Text:
        t = Text(no_wrap=True, overflow="ellipsis")
        for i, line in enumerate(self._preview_lines):
            ln = line.new_ln if line.new_ln is not None else line.old_ln
            gutter = f"{ln if ln is not None else '':>5} "
            body = f"{line.kind}{line.text}"
            if line.kind == "+":
                style = "green"
            elif line.kind == "-":
                style = "red"
            else:
                style = "dim"
            if i:
                t.append("\n")
            t.append(gutter, style="dim")
            t.append(body, style=style)
        return t

    def action_save(self) -> None:
        ta = self.query_one("#ta", TextArea)
        text = ta.text.strip()
        self.dismiss(text or None)

    def action_newline(self) -> None:
        self.query_one("#ta", TextArea).insert("\n")

    def action_cancel(self) -> None:
        self.dismiss(None)
