#!/usr/bin/env python3
"""
Ephemeral Cleanup (Stack)

Justified Action
Goal: Provide a single, reusable cleanup entrypoint for GitHub Actions and humans to purge orphaned
      ephemeral PR environments based on `jetscale.env_id` tags, with dependency-aware ordering.
Justification: Prudence (assume failures), Clarity (single tool), Vigor (delete root causes), Justice (clear blockers).

Usage:
  ./scripts/ephemeral_cleanup.py plan   pr-123 us-east-1 134051052096
  ./scripts/ephemeral_cleanup.py verify pr-123 us-east-1 134051052096
  ./scripts/ephemeral_cleanup.py apply  pr-123 us-east-1 134051052096
"""

from __future__ import annotations

import sys
from pathlib import Path


def _bootstrap_import_path() -> None:
    script_dir = Path(__file__).resolve().parent
    if str(script_dir) not in sys.path:
        sys.path.insert(0, str(script_dir))


def main() -> int:
    _bootstrap_import_path()
    from ephemeral_cleanup.main import main as impl_main  # type: ignore

    return impl_main(sys.argv)


if __name__ == "__main__":
    raise SystemExit(main())

