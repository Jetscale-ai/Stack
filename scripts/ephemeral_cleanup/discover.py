from __future__ import annotations

from typing import List, Optional

from .awscli import AwsCli
from .model import Ctx


def list_tagged_arns(ctx: Ctx, aws: AwsCli) -> List[str]:
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
