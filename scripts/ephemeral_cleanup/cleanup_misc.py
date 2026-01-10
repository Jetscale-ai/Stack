from __future__ import annotations

from .doer import Doer


def delete_non_vpc_tagged(doer: Doer) -> None:
    ctx = doer.ctx

    # EC2 Launch Templates
    lts = doer.aws.json(
        [
            "resourcegroupstaggingapi",
            "get-resources",
            "--tag-filters",
            f"Key=jetscale.env_id,Values={ctx.env_id}",
            "--resource-type-filters",
            "ec2:launch-template",
            "--query",
            "ResourceTagMappingList[].ResourceARN",
            "--region",
            ctx.region,
        ]
    ) or []
    for arn in lts:
        lt_id = arn.split(":launch-template/", 1)[-1]
        doer.run_allow_fail(
            f"ec2 delete launch template {lt_id}",
            ["ec2", "delete-launch-template", "--launch-template-id", lt_id, "--region", ctx.region],
        )

    # CloudWatch alarms
    alarms = doer.aws.json(
        [
            "resourcegroupstaggingapi",
            "get-resources",
            "--tag-filters",
            f"Key=jetscale.env_id,Values={ctx.env_id}",
            "--resource-type-filters",
            "cloudwatch:alarm",
            "--query",
            "ResourceTagMappingList[].ResourceARN",
            "--region",
            ctx.region,
        ]
    ) or []
    for arn in alarms:
        name = arn.split(":alarm:", 1)[-1]
        doer.run_allow_fail(
            f"cloudwatch delete alarm {name}",
            ["cloudwatch", "delete-alarms", "--alarm-names", name, "--region", ctx.region],
        )

    # Secrets Manager
    secrets = doer.aws.json(
        [
            "resourcegroupstaggingapi",
            "get-resources",
            "--tag-filters",
            f"Key=jetscale.env_id,Values={ctx.env_id}",
            "--resource-type-filters",
            "secretsmanager:secret",
            "--query",
            "ResourceTagMappingList[].ResourceARN",
            "--region",
            ctx.region,
        ]
    ) or []
    for sid in secrets:
        doer.run_allow_fail(
            f"secretsmanager delete secret {sid}",
            ["secretsmanager", "delete-secret", "--secret-id", sid, "--force-delete-without-recovery", "--region", ctx.region],
        )

    # ECR repositories
    repos = doer.aws.json(
        [
            "resourcegroupstaggingapi",
            "get-resources",
            "--tag-filters",
            f"Key=jetscale.env_id,Values={ctx.env_id}",
            "--resource-type-filters",
            "ecr:repository",
            "--query",
            "ResourceTagMappingList[].ResourceARN",
            "--region",
            ctx.region,
        ]
    ) or []
    for arn in repos:
        repo = arn.split(":repository/", 1)[-1]
        doer.run_allow_fail(
            f"ecr delete repository {repo}",
            ["ecr", "delete-repository", "--repository-name", repo, "--force", "--region", ctx.region],
        )

    # IAM policies
    policies = doer.aws.json(
        [
            "resourcegroupstaggingapi",
            "get-resources",
            "--tag-filters",
            f"Key=jetscale.env_id,Values={ctx.env_id}",
            "--resource-type-filters",
            "iam:policy",
            "--query",
            "ResourceTagMappingList[].ResourceARN",
            "--region",
            ctx.region,
        ]
    ) or []
    for arn in policies:
        doer.run_allow_fail(
            f"iam delete policy {arn}",
            ["iam", "delete-policy", "--policy-arn", arn],
        )

    # EKS log group (best effort)
    doer.run_allow_fail(
        f"logs delete log group /aws/eks/{ctx.env_id}/cluster",
        ["logs", "delete-log-group", "--log-group-name", f"/aws/eks/{ctx.env_id}/cluster", "--region", ctx.region],
        ignore_stderr_substrings=["ResourceNotFoundException"],
    )

