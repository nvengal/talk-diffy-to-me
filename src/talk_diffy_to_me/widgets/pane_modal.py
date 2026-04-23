from __future__ import annotations

from textual.binding import Binding
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import OptionList, Static
from textual.widgets.option_list import Option


class PaneModal(ModalScreen[str | None]):
    BINDINGS = [
        Binding("escape", "cancel", "cancel"),
    ]

    DEFAULT_CSS = """
    PaneModal {
        align: center middle;
    }
    PaneModal > Vertical {
        width: 90%;
        height: 60%;
        background: $surface;
        border: tall $accent;
        padding: 1 2;
    }
    PaneModal #title {
        height: auto;
        color: $text-muted;
    }
    PaneModal OptionList {
        height: 1fr;
        margin: 1 0;
    }
    PaneModal #hint {
        height: 1;
        color: $text-muted;
    }
    """

    def __init__(self, panes: list[dict]) -> None:
        super().__init__()
        self._panes = panes

    def compose(self):
        with Vertical():
            yield Static("Pick a pane to send comments to", id="title")
            options: list[Option] = []
            initial_index = 0
            for i, p in enumerate(self._panes):
                if p.get("is_focused"):
                    initial_index = i
                options.append(Option(_format_pane(p), id=str(p.get("id"))))
            ol = OptionList(*options, id="panes")
            yield ol
            yield Static("↑/↓ or j/k · enter to select · esc to cancel", id="hint")
            self._initial_index = initial_index

    def on_mount(self) -> None:
        ol = self.query_one("#panes", OptionList)
        ol.focus()
        if self._panes:
            ol.highlighted = self._initial_index

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        self.dismiss(str(event.option.id) if event.option.id is not None else None)

    def action_cancel(self) -> None:
        self.dismiss(None)


def _format_pane(p: dict) -> str:
    pid = p.get("id", "?")
    focus = "●" if p.get("is_focused") else " "
    tab = p.get("tab_name") or ""
    title = p.get("title") or "—"
    cwd = p.get("pane_cwd") or ""
    cmd = p.get("pane_command") or ""
    return f"{focus}  #{pid:<3}  {tab:<10}  {title:<20}  ({cmd})  {cwd}"
