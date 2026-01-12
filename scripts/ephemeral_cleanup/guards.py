from __future__ import annotations

from .awscli import AwsCli, AwsCliError
from .model import Ctx


def identity_guard(ctx: Ctx, aws: AwsCli) -> None:
    try:
        arn = aws.text(["sts", "get-caller-identity", "--query", "Arn"])
        acct = aws.text(["sts", "get-caller-identity", "--query", "Account"])
    except AwsCliError as e:
        raise SystemExit(str(e)) from e
    print(f"--- identity={arn}")
    if acct != ctx.expected_account_id:
        raise SystemExit(f"ERROR: expected account {ctx.expected_account_id}, got {acct}")

