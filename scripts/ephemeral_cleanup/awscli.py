from __future__ import annotations

import json
import os
import shlex
import subprocess
from dataclasses import dataclass
from typing import Any, Mapping, Sequence


class AwsCliError(RuntimeError):
    pass


@dataclass(frozen=True)
class AwsResult:
    rc: int
    stdout: str
    stderr: str


def _fmt(args: Sequence[str]) -> str:
    return " ".join(shlex.quote(a) for a in args)


class AwsCli:
    def __init__(self, *, env: Mapping[str, str] | None = None):
        self._env = dict(env) if env else None

    def _merged_env(self) -> Mapping[str, str] | None:
        if not self._env:
            return None
        merged = os.environ.copy()
        merged.update(self._env)
        return merged

    def json(self, args: Sequence[str]) -> Any:
        cmd = ["aws", *args, "--output", "json"]
        p = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self._merged_env(),
        )
        if p.returncode != 0:
            raise AwsCliError(f"aws {_fmt(args)} failed: {p.stderr.strip()}")
        out = p.stdout.strip()
        return None if not out else json.loads(out)

    def text(self, args: Sequence[str]) -> str:
        cmd = ["aws", *args, "--output", "text"]
        p = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self._merged_env(),
        )
        if p.returncode != 0:
            raise AwsCliError(f"aws {_fmt(args)} failed: {p.stderr.strip()}")
        return p.stdout.strip()

    def run(self, args: Sequence[str]) -> AwsResult:
        cmd = ["aws", *args]
        p = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self._merged_env(),
        )
        return AwsResult(
            rc=p.returncode, stdout=p.stdout.strip(), stderr=p.stderr.strip()
        )
