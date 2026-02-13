from __future__ import annotations

import argparse
import os
import sys
from typing import List

from .awscli import AwsCli
from .cleanup_eks import eks_delete
from .cleanup_elasticache import elasticache_serverless_delete
from .cleanup_iam import delete_tagged_oidc_providers, iam_cleanup_ephemeral_roles
from .cleanup_misc import delete_elbv2_by_cluster_tag, delete_non_vpc_tagged
from .cleanup_rds import rds_delete
from .cleanup_vpc import (
    ec2_terminate_instances_in_vpc,
    eni_wait_zero,
    igw_detach_delete,
    nat_delete,
    route_tables_disassociate_delete,
    security_groups_delete,
    subnets_delete,
    vpc_delete,
    vpc_endpoints_delete,
)
from .discover import discover_vpc_id, list_tagged_arns
from .doer import Doer
from .guards import identity_guard
from .model import Ctx, Summary
from .verify import verify_tagged_arns


def _print_summary(ctx: Ctx, summary: Summary) -> None:
    print("### Summary")
    print(f"- **mode**: {ctx.mode}")
    print(f"- **env_id**: {ctx.env_id}")
    print(f"- **region**: {ctx.region}")
    print(f"- **initial_tagged_count**: {len(summary.initial_tagged)}")
    print(f"- **final_tagged_count**: {len(summary.final_tagged)}")
    print(f"- **remaining_exists_count**: {len(summary.final_existing)}")
    print(f"- **remaining_eventual_count**: {len(summary.final_eventual)}")
    print(f"- **remaining_unknown_count**: {len(summary.final_unknown)}")
    print(f"- **remaining_stale_count**: {len(summary.final_stale)}")

    planned = [a for a in summary.actions if a.mode == "plan"]
    applied = [a for a in summary.actions if a.mode == "apply"]
    failed = summary.failed_actions()
    print(f"- **actions_planned**: {len(planned)}")
    print(f"- **actions_executed**: {len(applied)}")
    print(f"- **actions_failed**: {len(failed)}")

    if failed:
        print("")
        print("### Failed actions (apply)")
        for a in failed[:12]:
            msg = (a.stderr or "").splitlines()[-1] if a.stderr else ""
            print(f"- **{a.desc}**: rc={a.rc} {msg}")

    print("")
    print("### Remaining tagged resources (verification-aware)")
    if summary.final_existing:
        print("- **still exists**:")
        for arn in summary.final_existing:
            print(f"  - {arn}")
    if summary.final_eventual:
        print("- **eventual (deleting / will disappear with time)**:")
        for arn in summary.final_eventual:
            print(f"  - {arn}")
    if summary.final_unknown:
        print("- **unknown (could not verify; likely AccessDenied)**:")
        for arn in summary.final_unknown:
            print(f"  - {arn}")
    if summary.final_stale:
        print("- **stale (verified not found)**:")
        for arn in summary.final_stale:
            print(f"  - {arn}")
    if not (
        summary.final_existing
        or summary.final_eventual
        or summary.final_unknown
        or summary.final_stale
    ):
        print("- (none)")


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="ephemeral_cleanup.py",
        add_help=True,
        description=(
            "Ephemeral cleanup via tag discovery (jetscale.cluster_id) "
            "and dependency-aware deletes."
        ),
    )
    parser.add_argument("mode", choices=["plan", "apply", "verify"])
    parser.add_argument("env_id", help="e.g. pr-123")
    parser.add_argument("region", nargs="?", default="us-east-1")
    parser.add_argument("expected_account_id", nargs="?", default="134051052096")

    args = parser.parse_args(argv[1:])

    os.environ.setdefault("AWS_PAGER", "")
    os.environ["AWS_REGION"] = args.region
    os.environ["AWS_DEFAULT_REGION"] = args.region

    ctx = Ctx(
        mode=args.mode,
        env_id=args.env_id,
        region=args.region,
        expected_account_id=args.expected_account_id,
    )
    aws = AwsCli()
    summary = Summary()
    doer = Doer(ctx=ctx, aws=aws, summary=summary)

    identity_guard(ctx, aws)

    print(f"--- discover tagged resources (jetscale.cluster_id={ctx.env_id})")
    summary.initial_tagged = list_tagged_arns(ctx, aws)
    if summary.initial_tagged:
        print("\n".join(summary.initial_tagged))
    else:
        print("(none)")

    if ctx.mode == "verify":
        summary.final_tagged = summary.initial_tagged
        vr = verify_tagged_arns(ctx, aws, summary.final_tagged)
        summary.final_existing = vr.existing
        summary.final_stale = vr.stale
        summary.final_unknown = vr.unknown
        summary.final_eventual = vr.eventual
        _print_summary(ctx, summary)
        # Success if nothing still exists or unknown; "eventual" is treated as success.
        return 1 if (summary.final_existing or summary.final_unknown) else 0

    # Root-cause order
    eks_delete(doer)
    delete_elbv2_by_cluster_tag(doer)
    delete_tagged_oidc_providers(doer, summary.initial_tagged)
    elasticache_serverless_delete(doer)
    rds_delete(doer)

    vpc_id = discover_vpc_id(ctx, aws)
    if not vpc_id:
        print("--- VPC: not found (tag jetscale.cluster_id or jetscale.env_id)")
    else:
        print(f"--- VPC_ID={vpc_id}")
        ec2_terminate_instances_in_vpc(doer, vpc_id)
        vpc_endpoints_delete(doer, vpc_id)
        nat_delete(doer, vpc_id)
        eni_wait_zero(doer, vpc_id)
        igw_detach_delete(doer, vpc_id)
        route_tables_disassociate_delete(doer, vpc_id)
        subnets_delete(doer, vpc_id)
        security_groups_delete(doer, vpc_id)
        vpc_delete(doer, vpc_id)

    # IAM roles/profiles before IAM policy deletion
    iam_cleanup_ephemeral_roles(doer)
    delete_non_vpc_tagged(doer)

    summary.final_tagged = list_tagged_arns(ctx, aws)
    vr = verify_tagged_arns(ctx, aws, summary.final_tagged)
    summary.final_existing = vr.existing
    summary.final_stale = vr.stale
    summary.final_unknown = vr.unknown
    summary.final_eventual = vr.eventual
    _print_summary(ctx, summary)

    # In apply mode, only "existing" or "unknown" should fail the run.
    # "eventual" means AWS reports it as present but it is demonstrably deleting.
    if ctx.mode == "apply" and (summary.final_existing or summary.final_unknown):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
