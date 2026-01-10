from __future__ import annotations

import time
from typing import Optional

from .doer import Doer


def ec2_terminate_instances_in_vpc(doer: Doer, vpc_id: str) -> None:
    ctx = doer.ctx
    data = doer.aws.json(
        [
            "ec2",
            "describe-instances",
            "--filters",
            f"Name=vpc-id,Values={vpc_id}",
            "Name=instance-state-name,Values=pending,running,stopping,stopped",
            "--region",
            ctx.region,
        ]
    ) or {}
    ids = []
    for r in data.get("Reservations", []) or []:
        for inst in r.get("Instances", []) or []:
            iid = inst.get("InstanceId")
            if iid:
                ids.append(iid)
    if not ids:
        return
    doer.run_allow_fail(
        f"ec2 terminate instances in {vpc_id}",
        ["ec2", "terminate-instances", "--instance-ids", *ids, "--region", ctx.region],
    )
    if ctx.mode == "apply":
        doer.aws.run(["ec2", "wait", "instance-terminated", "--instance-ids", *ids, "--region", ctx.region])


def vpc_endpoints_delete(doer: Doer, vpc_id: str) -> None:
    ctx = doer.ctx
    data = doer.aws.json(["ec2", "describe-vpc-endpoints", "--filters", f"Name=vpc-id,Values={vpc_id}", "--region", ctx.region]) or {}
    ids = [vpce.get("VpcEndpointId") for vpce in data.get("VpcEndpoints", []) or [] if vpce.get("VpcEndpointId")]
    if not ids:
        return
    doer.run_allow_fail(
        f"ec2 delete vpc endpoints ({len(ids)})",
        ["ec2", "delete-vpc-endpoints", "--vpc-endpoint-ids", *ids, "--region", ctx.region],
        ignore_stderr_substrings=["Operation is not allowed for requester-managed VPC endpoints"],
    )


def nat_delete(doer: Doer, vpc_id: str) -> None:
    ctx = doer.ctx
    data = doer.aws.json(["ec2", "describe-nat-gateways", "--filter", f"Name=vpc-id,Values={vpc_id}", "--region", ctx.region]) or {}
    for nat in data.get("NatGateways", []) or []:
        nat_id = nat.get("NatGatewayId")
        if not nat_id:
            continue
        allocs = []
        for addr in nat.get("NatGatewayAddresses", []) or []:
            a = addr.get("AllocationId")
            if a:
                allocs.append(a)
        doer.run_allow_fail(
            f"ec2 delete nat gateway {nat_id}",
            ["ec2", "delete-nat-gateway", "--nat-gateway-id", nat_id, "--region", ctx.region],
        )
        if ctx.mode == "apply":
            doer.aws.run(["ec2", "wait", "nat-gateway-deleted", "--nat-gateway-id", nat_id, "--region", ctx.region])
            for a in allocs:
                doer.run_allow_fail(
                    f"ec2 release address {a}",
                    ["ec2", "release-address", "--allocation-id", a, "--region", ctx.region],
                )


def eni_wait_zero(doer: Doer, vpc_id: str, timeout_seconds: int = 30 * 60) -> None:
    ctx = doer.ctx
    if ctx.mode in ("plan", "verify"):
        doer.plan("would wait for ENIs to drain to 0")
        return
    start = time.time()
    while True:
        data = doer.aws.json(["ec2", "describe-network-interfaces", "--filters", f"Name=vpc-id,Values={vpc_id}", "--region", ctx.region]) or {}
        enis = data.get("NetworkInterfaces", []) or []
        print(f"--- ENIs={len(enis)}")
        if not enis:
            return
        if time.time() - start > timeout_seconds:
            raise SystemExit("Timed out waiting for ENIs to drain. Inspect remaining ENIs via describe-network-interfaces.")
        time.sleep(15)


def igw_detach_delete(doer: Doer, vpc_id: str) -> None:
    ctx = doer.ctx
    data = doer.aws.json(["ec2", "describe-internet-gateways", "--filters", f"Name=attachment.vpc-id,Values={vpc_id}", "--region", ctx.region]) or {}
    for igw in data.get("InternetGateways", []) or []:
        igw_id = igw.get("InternetGatewayId")
        if not igw_id:
            continue
        doer.run_allow_fail(
            f"ec2 detach igw {igw_id}",
            ["ec2", "detach-internet-gateway", "--internet-gateway-id", igw_id, "--vpc-id", vpc_id, "--region", ctx.region],
        )
        doer.run_allow_fail(
            f"ec2 delete igw {igw_id}",
            ["ec2", "delete-internet-gateway", "--internet-gateway-id", igw_id, "--region", ctx.region],
        )


def route_tables_disassociate_delete(doer: Doer, vpc_id: str) -> None:
    ctx = doer.ctx
    data = doer.aws.json(["ec2", "describe-route-tables", "--filters", f"Name=vpc-id,Values={vpc_id}", "--region", ctx.region]) or {}
    for rt in data.get("RouteTables", []) or []:
        rtb = rt.get("RouteTableId")
        if not rtb:
            continue
        assocs = rt.get("Associations", []) or []
        is_main = any(a.get("Main") for a in assocs)
        for a in assocs:
            if a.get("Main"):
                continue
            assoc_id = a.get("RouteTableAssociationId")
            if assoc_id:
                doer.run_allow_fail(
                    f"ec2 disassociate route table {assoc_id}",
                    ["ec2", "disassociate-route-table", "--association-id", assoc_id, "--region", ctx.region],
                )
        if not is_main:
            doer.run_allow_fail(
                f"ec2 delete route table {rtb}",
                ["ec2", "delete-route-table", "--route-table-id", rtb, "--region", ctx.region],
            )


def subnets_delete(doer: Doer, vpc_id: str) -> None:
    ctx = doer.ctx
    data = doer.aws.json(["ec2", "describe-subnets", "--filters", f"Name=vpc-id,Values={vpc_id}", "--region", ctx.region]) or {}
    for s in data.get("Subnets", []) or []:
        sid = s.get("SubnetId")
        if sid:
            doer.run_allow_fail(
                f"ec2 delete subnet {sid}",
                ["ec2", "delete-subnet", "--subnet-id", sid, "--region", ctx.region],
            )


def security_groups_delete(doer: Doer, vpc_id: str) -> None:
    ctx = doer.ctx
    data = doer.aws.json(["ec2", "describe-security-groups", "--filters", f"Name=vpc-id,Values={vpc_id}", "--region", ctx.region]) or {}
    sgs = data.get("SecurityGroups", []) or []
    default_sg: Optional[str] = None
    for sg in sgs:
        if sg.get("GroupName") == "default":
            default_sg = sg.get("GroupId")
            break
    for sg in sgs:
        sgid = sg.get("GroupId")
        if not sgid or sgid == default_sg:
            continue
        doer.run_allow_fail(
            f"ec2 delete security group {sgid}",
            ["ec2", "delete-security-group", "--group-id", sgid, "--region", ctx.region],
        )


def vpc_delete(doer: Doer, vpc_id: str) -> None:
    ctx = doer.ctx
    doer.run_allow_fail(
        f"ec2 delete vpc {vpc_id}",
        ["ec2", "delete-vpc", "--vpc-id", vpc_id, "--region", ctx.region],
    )

