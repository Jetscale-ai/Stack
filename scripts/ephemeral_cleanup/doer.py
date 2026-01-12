from __future__ import annotations

from typing import Iterable, Optional, Sequence

from .awscli import AwsCli, AwsResult
from .model import ActionRecord, Ctx, Summary


class Doer:
    def __init__(self, ctx: Ctx, aws: AwsCli, summary: Summary):
        self.ctx = ctx
        self.aws = aws
        self.summary = summary

    def plan(self, desc: str) -> None:
        print(f"+ (plan) {desc}")
        self.summary.add_action(ActionRecord(desc=desc, mode="plan", ok=True))

    def run_allow_fail(
        self,
        desc: str,
        args: Sequence[str],
        *,
        ignore_stderr_substrings: Optional[Iterable[str]] = None,
    ) -> AwsResult:
        if self.ctx.mode in ("plan", "verify"):
            self.plan(" ".join(["aws", *args]))
            return AwsResult(rc=0, stdout="", stderr="")

        print(f"+ aws {' '.join(args)}")
        res = self.aws.run(args)
        ok = res.rc == 0

        if not ok and ignore_stderr_substrings:
            lowered = res.stderr.lower()
            for s in ignore_stderr_substrings:
                if s.lower() in lowered:
                    ok = True
                    break

        self.summary.add_action(ActionRecord(desc=desc, mode="apply", ok=ok, rc=res.rc, stderr=res.stderr))
        return res

