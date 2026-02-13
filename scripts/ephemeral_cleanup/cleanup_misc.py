from __future__ import annotations

import time
from typing import List

from .doer import Doer


def _list_tagged_resources(doer: Doer, resource_type: str, tag_key: str) -> List[str]:
    """
    List resources by tag. Tries jetscale.cluster_id first (new convention),
    falls back to jetscale.env_id (legacy) for backward compatibility.
    """
    ctx = doer.ctx

    # Try new tag first: jetscale.cluster_id
    if tag_key == "jetscale.cluster_id":
        data = doer.aws.json(
            [
                "resourcegroupstaggingapi",
                "get-resources",
                "--tag-filters",
                f"Key=jetscale.cluster_id,Values={ctx.env_id}",
                "--resource-type-filters",
                resource_type,
                "--query",
                "ResourceTagMappingList[].ResourceARN",
                "--region",
                ctx.region,
            ]
        )
        if data:
            return data

        # Fall back to legacy tag: jetscale.env_id
        data = doer.aws.json(
            [
                "resourcegroupstaggingapi",
                "get-resources",
                "--tag-filters",
                f"Key=jetscale.env_id,Values={ctx.env_id}",
                "--resource-type-filters",
                resource_type,
                "--query",
                "ResourceTagMappingList[].ResourceARN",
                "--region",
                ctx.region,
            ]
        )
        return data or []

    # For other tags (e.g., elbv2.k8s.aws/cluster), use directly
    data = doer.aws.json(
        [
            "resourcegroupstaggingapi",
            "get-resources",
            "--tag-filters",
            f"Key={tag_key},Values={ctx.env_id}",
            "--resource-type-filters",
            resource_type,
            "--query",
            "ResourceTagMappingList[].ResourceARN",
            "--region",
            ctx.region,
        ]
    )
    return data or []


def delete_elbv2_by_cluster_tag(doer: Doer) -> None:
    """
    Delete ELBv2 resources created by AWS Load Balancer Controller.

    IMPORTANT:
    - These resources are tagged with `elbv2.k8s.aws/cluster=<env_id>`, not
      our `jetscale.cluster_id` tag, so they will not be discovered by the
      generic tag sweep.
    - If the EKS cluster is already deleted, these LBs will NOT be
      garbage-collected automatically and can block VPC teardown.
    """
    ctx = doer.ctx

    def _list_lb_arns() -> list[str]:
        return _list_tagged_resources(
            doer, "elasticloadbalancing:loadbalancer", "elbv2.k8s.aws/cluster"
        )

    def _list_tg_arns() -> list[str]:
        return _list_tagged_resources(
            doer, "elasticloadbalancing:targetgroup", "elbv2.k8s.aws/cluster"
        )

    # 1) Load balancers (ALB/NLB)
    lbs = _list_lb_arns()
    for arn in lbs:
        doer.run_allow_fail(
            f"elbv2 delete load balancer {arn}",
            [
                "elbv2",
                "delete-load-balancer",
                "--load-balancer-arn",
                arn,
                "--region",
                ctx.region,
            ],
        )

    # Wait/poll until LBs are truly gone before deleting target groups.
    # NOTE: the AWS waiter can return before tag propagation catches up,
    # so we poll tags too.
    if ctx.mode == "apply" and lbs:
        start = time.time()
        while True:
            remaining = _list_lb_arns()
            if not remaining:
                break
            if time.time() - start > 20 * 60:
                # Best-effort: proceed; TG deletes will retry below.
                break
            print(
                f"--- elbv2: waiting for load balancers to disappear "
                f"(remaining={len(remaining)})"
            )
            time.sleep(15)

    # 2) Target groups
    # Target group deletes can fail with ResourceInUse while
    # listeners/rules are being torn down. Retry with backoff to converge.
    tgs = _list_tg_arns()
    for arn in tgs:
        if ctx.mode in ("plan", "verify"):
            doer.plan(
                f"aws elbv2 delete-target-group --target-group-arn {arn} "
                f"--region {ctx.region}"
            )
            continue

        for attempt in range(1, 41):  # ~10 minutes @ 15s
            res = doer.run_allow_fail(
                f"elbv2 delete target group {arn}",
                [
                    "elbv2",
                    "delete-target-group",
                    "--target-group-arn",
                    arn,
                    "--region",
                    ctx.region,
                ],
                ignore_stderr_substrings=["TargetGroupNotFound", "not found"],
            )
            if res.rc == 0:
                break
            if "resourceinuse" in (res.stderr or "").lower():
                print(
                    f"--- elbv2: target group still in use; " f"retrying ({attempt}/40)"
                )
                time.sleep(15)
                continue
            break


def delete_non_vpc_tagged(doer: Doer) -> None:
    ctx = doer.ctx

    # EC2 Launch Templates
    lts = _list_tagged_resources(doer, "ec2:launch-template", "jetscale.cluster_id")
    for arn in lts:
        lt_id = arn.split(":launch-template/", 1)[-1]
        doer.run_allow_fail(
            f"ec2 delete launch template {lt_id}",
            [
                "ec2",
                "delete-launch-template",
                "--launch-template-id",
                lt_id,
                "--region",
                ctx.region,
            ],
        )

    # CloudWatch alarms
    alarms = _list_tagged_resources(doer, "cloudwatch:alarm", "jetscale.cluster_id")
    for arn in alarms:
        name = arn.split(":alarm:", 1)[-1]
        doer.run_allow_fail(
            f"cloudwatch delete alarm {name}",
            [
                "cloudwatch",
                "delete-alarms",
                "--alarm-names",
                name,
                "--region",
                ctx.region,
            ],
        )

    # Secrets Manager
    secrets = _list_tagged_resources(
        doer, "secretsmanager:secret", "jetscale.cluster_id"
    )
    for sid in secrets:
        doer.run_allow_fail(
            f"secretsmanager delete secret {sid}",
            [
                "secretsmanager",
                "delete-secret",
                "--secret-id",
                sid,
                "--force-delete-without-recovery",
                "--region",
                ctx.region,
            ],
        )

    # ECR repositories
    repos = _list_tagged_resources(doer, "ecr:repository", "jetscale.cluster_id")
    for arn in repos:
        repo = arn.split(":repository/", 1)[-1]
        doer.run_allow_fail(
            f"ecr delete repository {repo}",
            [
                "ecr",
                "delete-repository",
                "--repository-name",
                repo,
                "--force",
                "--region",
                ctx.region,
            ],
        )

    # IAM policies
    policies = _list_tagged_resources(doer, "iam:policy", "jetscale.cluster_id")
    for arn in policies:
        doer.run_allow_fail(
            f"iam delete policy {arn}",
            ["iam", "delete-policy", "--policy-arn", arn],
        )

    # EKS log group (best effort)
    doer.run_allow_fail(
        f"logs delete log group /aws/eks/{ctx.env_id}/cluster",
        [
            "logs",
            "delete-log-group",
            "--log-group-name",
            f"/aws/eks/{ctx.env_id}/cluster",
            "--region",
            ctx.region,
        ],
        ignore_stderr_substrings=["ResourceNotFoundException"],
    )
