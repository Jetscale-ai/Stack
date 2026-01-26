#!/usr/bin/env python3
from __future__ import annotations

import os
import re
import sys
from pathlib import Path


def extract_terraform_error_blocks(text: str) -> list[str]:
    # Terraform renders structured errors as:
    #   ╷
    #   │ Error: ...
    #   ╵
    blocks = []
    for m in re.finditer(r"\n\s*╷\n[\s\S]*?\n\s*╵\n", text):
        blocks.append(m.group(0).strip("\n"))
    return blocks


def strip_ansi(text: str) -> str:
    return re.sub(r"\x1B\[[0-9;]*[A-Za-z]", "", text)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: extract_tf_errors.py <path-to-tf-log>", file=sys.stderr)
        return 2
    p = Path(sys.argv[1])
    raw = p.read_text(errors="replace")
    clean = strip_ansi(raw)

    blocks = extract_terraform_error_blocks(clean)

    header = "## Terraform error summary\n"
    body_lines: list[str] = []
    if blocks:
        body_lines.append(f"Found {len(blocks)} Terraform error block(s):\n")
        for i, b in enumerate(blocks[:12], start=1):
            body_lines.append(f"### Error block {i}\n")
            body_lines.append("```text\n" + b.strip() + "\n```\n")
        if len(blocks) > 12:
            body_lines.append(f"(truncated; {len(blocks)-12} more blocks)\n")
    else:
        # Fallback: pull common error lines from the tail.
        body_lines.append("No `╷…╵` blocks found. Showing last 200 lines:\n")
        tail = "\n".join(clean.splitlines()[-200:])
        body_lines.append("```text\n" + tail + "\n```\n")

    out = header + "\n".join(body_lines)
    print(out)

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as f:
            f.write(out + "\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
