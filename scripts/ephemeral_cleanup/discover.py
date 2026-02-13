from __future__ import annotations

from typing import List, Optional

from .awscli import AwsCli
from .model import Ctx


def list_tagged_arns(ctx: Ctx, aws: AwsCli) -> List[str]:
    """
    Discover resources by tag. Tries jetscale.cluster_id first (new convention),
    falls back to jetscale.env_id (legacy) for backward compatibility.
    """
    # Try new tag first: jetscale.cluster_id
    data = aws.json(
        [
            "resourcegroupstaggingapi",
            "get-resources",
            "--tag-filters",
            f"Key=jetscale.cluster_id,Values={ctx.env_id}",
            "--query",
            "ResourceTagMappingList[].ResourceARN",
        ]
    )
    if data:
        return data

    # Fall back to legacy tag: jetscale.env_id
    data = aws.json(
        [
            "resourcegroupstaggingapi",
            "get-resources",
            "--tag-filters",
            f"Key=jetscale.env_id,Values={ctx.env_id}",
            "--query",
            "ResourceTagMappingList[].ResourceARN",
        ]
    )
    return data or []


def discover_vpc_id(ctx: Ctx, aws: AwsCli) -> Optional[str]:
    """
    Discover VPC by tag. Tries jetscale.cluster_id first (new convention),
    falls back to jetscale.env_id (legacy) for backward compatibility.
    """
    # Try new tag first: jetscale.cluster_id
    vpc_id = aws.json(
        [
            "ec2",
            "describe-vpcs",
            "--filters",
            f"Name=tag:jetscale.cluster_id,Values={ctx.env_id}",
            "--query",
            "Vpcs[0].VpcId",
            "--region",
            ctx.region,
        ]
    )
    if vpc_id and vpc_id != "None":
        return str(vpc_id)

    # Fall back to legacy tag: jetscale.env_id
    vpc_id = aws.json(
        [
            "ec2",
            "describe-vpcs",
            "--filters",
            f"Name=tag:jetscale.env_id,Values={ctx.env_id}",
            "--query",
            "Vpcs[0].VpcId",
            "--region",
            ctx.region,
        ]
    )
    if not vpc_id or vpc_id == "None":
        return None
    return str(vpc_id)
