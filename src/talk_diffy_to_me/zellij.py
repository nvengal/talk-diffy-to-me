from __future__ import annotations

import json
import os
import re
import subprocess


class ZellijError(RuntimeError):
    pass


def current_pane_id() -> str | None:
    """Zellij's own pane id for the pane talk-diffy is running in.

    Zellij exports `$ZELLIJ_PANE_ID` into each pane's environment. Value is
    usually bare numeric (e.g. "58") but older builds use "terminal_58".
    """
    raw = os.environ.get("ZELLIJ_PANE_ID")
    if not raw:
        return None
    m = re.search(r"\d+", raw)
    return m.group(0) if m else None


def find_pane(panes: list[dict], pane_id: str | None) -> dict | None:
    if not pane_id:
        return None
    for p in panes:
        if str(p.get("id")) == pane_id:
            return p
    return None


def list_panes() -> list[dict]:
    """Return selectable, non-plugin terminal panes from `zellij action list-panes --json`."""
    try:
        result = subprocess.run(
            ["zellij", "action", "list-panes", "--json"],
            capture_output=True,
            text=True,
            check=True,
        )
    except FileNotFoundError as e:
        raise ZellijError("zellij not found on PATH") from e
    except subprocess.CalledProcessError as e:
        msg = (e.stderr or e.stdout or "").strip() or str(e)
        raise ZellijError(f"list-panes failed: {msg}") from e

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        raise ZellijError("list-panes did not return JSON") from e

    if not isinstance(data, list):
        raise ZellijError(f"unexpected list-panes payload: {type(data).__name__}")

    return [
        p for p in data
        if isinstance(p, dict)
        and not p.get("is_plugin")
        and p.get("is_selectable", True)
    ]


def send_payload(pane_id: str, payload: str) -> None:
    _run(["zellij", "action", "paste", "--pane-id", pane_id, "--", payload])
    _run(["zellij", "action", "send-keys", "--pane-id", pane_id, "--", "Enter"])


def _run(cmd: list[str]) -> None:
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
    except FileNotFoundError as e:
        raise ZellijError("zellij not found on PATH") from e
    except subprocess.CalledProcessError as e:
        msg = (e.stderr or e.stdout or "").strip() or str(e)
        raise ZellijError(f"{cmd[1]} {cmd[2]} failed: {msg}") from e
