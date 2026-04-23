from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from talk_diffy_to_me.app import TalkDiffyApp
from talk_diffy_to_me.diff import parse as parse_diff


def _read_diff(fixture: str | None) -> str:
    if fixture:
        return Path(fixture).read_text()
    try:
        result = subprocess.run(
            ["jj", "diff", "--git"],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        sys.stderr.write("jj not found on PATH\n")
        sys.exit(1)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        sys.exit(result.returncode)
    return result.stdout


def main() -> None:
    ap = argparse.ArgumentParser(prog="talk-diffy")
    # Dev-only flags, intentionally hidden from --help.
    ap.add_argument("--fixture", help=argparse.SUPPRESS)
    ap.add_argument("--dry-run", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args()

    raw = _read_diff(args.fixture)
    files = parse_diff(raw)
    if not files:
        sys.stderr.write("no diff to review\n")
        sys.exit(0)

    app = TalkDiffyApp(files=files, dry_run=args.dry_run)
    app.run()
    if args.dry_run and app._dry_run_payload is not None:
        sys.stdout.write(app._dry_run_payload)


if __name__ == "__main__":
    main()
