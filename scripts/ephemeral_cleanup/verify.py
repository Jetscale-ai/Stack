from __future__ import annotations

from dataclasses import dataclass
import json
from typing import List

from .awscli import AwsCli
from .model import Ctx


@dataclass(frozen=True)
class VerificationResult:
    existing: List[str]
    stale: List[str]
    unknown: List[str]
    eventual: List[str]


def _ec2_instance_exists(ctx: Ctx, aws: AwsCli, instance_id: str) -> bool:
    data = aws.json(
        [
            "ec2",
            "describe-instances",
            "--instance-ids",
            instance_id,
            "--region",
            ctx.region,
            "--query",
            "Reservations",
        ]
    )
    return bool(data)


def _ec2_simple_exists(ctx: Ctx, aws: AwsCli, args: list[str], not_found_substrings: list[str]) -> bool | None:
    res = aws.run(args + ["--region", ctx.region])
    if res.rc == 0:
        return True
    err = (res.stderr or "").lower()
    for s in not_found_substrings:
        if s.lower() in err:
            return False
    return None


def verify_tagged_arns(ctx: Ctx, aws: AwsCli, arns: List[str]) -> VerificationResult:
    existing: List[str] = []
    stale: List[str] = []
    unknown: List[str] = []
    eventual: List[str] = []

    for arn in arns:
        try:
            # Secrets Manager secrets
            # - If DeletedDate is present, AWS still returns it for some time after deletion requests.
            # - We classify those as "eventual" to avoid failing the cleanup run on async deletion.
            if ":secretsmanager:" in arn and ":secret:" in arn:
                res = aws.run(["secretsmanager", "describe-secret", "--secret-id", arn, "--region", ctx.region, "--output", "json"])
                if res.rc == 0:
                    try:
                        payload = json.loads(res.stdout) if res.stdout else {}
                    except Exception:
                        unknown.append(arn)
                        continue
                    if payload.get("DeletedDate"):
                        eventual.append(arn)
                    else:
                        existing.append(arn)
                else:
                    err = (res.stderr or "").lower()
                    if "resourcenotfoundexception" in err or "not found" in err:
                        stale.append(arn)
                    else:
                        unknown.append(arn)
                continue

            # EBS volumes
            if ":volume/" in arn:
                vol = arn.split(":volume/", 1)[-1]
                res = aws.run(["ec2", "describe-volumes", "--volume-ids", vol, "--region", ctx.region, "--output", "json"])
                if res.rc == 0:
                    try:
                        payload = json.loads(res.stdout) if res.stdout else {}
                        vols = payload.get("Volumes", []) or []
                        state = (vols[0].get("State") if vols else None) or ""
                    except Exception:
                        unknown.append(arn)
                        continue
                    # States include: creating, available, in-use, deleting, deleted, error
                    if state in ("deleting", "deleted"):
                        eventual.append(arn)
                    elif state:
                        existing.append(arn)
                    else:
                        unknown.append(arn)
                else:
                    err = (res.stderr or "").lower()
                    if "invalidvolume.notfound" in err or "not found" in err:
                        stale.append(arn)
                    else:
                        unknown.append(arn)
                continue

            if ":natgateway/" in arn:
                nat = arn.split(":natgateway/", 1)[-1]
                ok = _ec2_simple_exists(
                    ctx,
                    aws,
                    ["ec2", "describe-nat-gateways", "--nat-gateway-ids", nat],
                    ["InvalidNatGatewayID.NotFound", "NatGatewayNotFound", "does not exist"],
                )
                if ok is True:
                    existing.append(arn)
                elif ok is False:
                    stale.append(arn)
                else:
                    unknown.append(arn)
                continue

            if ":internet-gateway/" in arn:
                igw = arn.split(":internet-gateway/", 1)[-1]
                ok = _ec2_simple_exists(
                    ctx,
                    aws,
                    ["ec2", "describe-internet-gateways", "--internet-gateway-ids", igw],
                    ["InvalidInternetGatewayID.NotFound", "does not exist"],
                )
                if ok is True:
                    existing.append(arn)
                elif ok is False:
                    stale.append(arn)
                else:
                    unknown.append(arn)
                continue

            if ":route-table/" in arn:
                rtb = arn.split(":route-table/", 1)[-1]
                ok = _ec2_simple_exists(
                    ctx,
                    aws,
                    ["ec2", "describe-route-tables", "--route-table-ids", rtb],
                    ["InvalidRouteTableID.NotFound", "does not exist"],
                )
                if ok is True:
                    existing.append(arn)
                elif ok is False:
                    stale.append(arn)
                else:
                    unknown.append(arn)
                continue

            if ":subnet/" in arn:
                subnet = arn.split(":subnet/", 1)[-1]
                ok = _ec2_simple_exists(
                    ctx,
                    aws,
                    ["ec2", "describe-subnets", "--subnet-ids", subnet],
                    ["InvalidSubnetID.NotFound", "does not exist"],
                )
                if ok is True:
                    existing.append(arn)
                elif ok is False:
                    stale.append(arn)
                else:
                    unknown.append(arn)
                continue

            if ":elastic-ip/" in arn:
                alloc = arn.split(":elastic-ip/", 1)[-1]
                ok = _ec2_simple_exists(
                    ctx,
                    aws,
                    ["ec2", "describe-addresses", "--allocation-ids", alloc],
                    ["InvalidAllocationID.NotFound", "does not exist"],
                )
                if ok is True:
                    existing.append(arn)
                elif ok is False:
                    stale.append(arn)
                else:
                    unknown.append(arn)
                continue

            if ":instance/" in arn:
                iid = arn.split(":instance/", 1)[-1]
                if _ec2_instance_exists(ctx, aws, iid):
                    existing.append(arn)
                else:
                    stale.append(arn)
                continue

            if ":vpc-endpoint/" in arn:
                vpce_id = arn.split(":vpc-endpoint/", 1)[-1]
                ok = _ec2_simple_exists(ctx, aws, ["ec2", "describe-vpc-endpoints", "--vpc-endpoint-ids", vpce_id], ["InvalidVpcEndpointId.NotFound", "does not exist"])
                if ok is True:
                    existing.append(arn)
                elif ok is False:
                    stale.append(arn)
                else:
                    unknown.append(arn)
                continue

            if ":network-interface/" in arn:
                eni = arn.split(":network-interface/", 1)[-1]
                ok = _ec2_simple_exists(ctx, aws, ["ec2", "describe-network-interfaces", "--network-interface-ids", eni], ["InvalidNetworkInterfaceID.NotFound", "does not exist"])
                if ok is True:
                    existing.append(arn)
                elif ok is False:
                    stale.append(arn)
                else:
                    unknown.append(arn)
                continue

            if ":launch-template/" in arn:
                lt = arn.split(":launch-template/", 1)[-1]
                ok = _ec2_simple_exists(ctx, aws, ["ec2", "describe-launch-templates", "--launch-template-ids", lt], ["InvalidLaunchTemplateId.NotFound", "does not exist"])
                if ok is True:
                    existing.append(arn)
                elif ok is False:
                    stale.append(arn)
                else:
                    unknown.append(arn)
                continue

            if ":vpc/" in arn:
                vpc_id = arn.split(":vpc/", 1)[-1]
                ok = _ec2_simple_exists(ctx, aws, ["ec2", "describe-vpcs", "--vpc-ids", vpc_id], ["InvalidVpcID.NotFound", "does not exist"])
                if ok is True:
                    existing.append(arn)
                elif ok is False:
                    stale.append(arn)
                else:
                    unknown.append(arn)
                continue

            if ":security-group/" in arn:
                sg = arn.split(":security-group/", 1)[-1]
                ok = _ec2_simple_exists(ctx, aws, ["ec2", "describe-security-groups", "--group-ids", sg], ["InvalidGroup.NotFound", "does not exist"])
                if ok is True:
                    existing.append(arn)
                elif ok is False:
                    stale.append(arn)
                else:
                    unknown.append(arn)
                continue

            unknown.append(arn)
        except Exception:
            unknown.append(arn)

    return VerificationResult(existing=existing, stale=stale, unknown=unknown, eventual=eventual)

