from __future__ import annotations

from .doer import Doer


def eks_delete(doer: Doer) -> None:
    """
    Best-effort EKS cleanup (nodegroups then cluster).
    In preflight contexts, the cluster may not exist; that's fine.
    """
    ctx = doer.ctx
    res = doer.aws.run(
        ["eks", "describe-cluster", "--name", ctx.env_id, "--region", ctx.region]
    )
    if res.rc != 0:
        print("--- EKS: cluster not found")
        return

    ngs = (
        doer.aws.json(
            [
                "eks",
                "list-nodegroups",
                "--cluster-name",
                ctx.env_id,
                "--region",
                ctx.region,
            ]
        )
        or {}
    )
    nodegroups = ngs.get("nodegroups", []) or []
    for ng in nodegroups:
        doer.run_allow_fail(
            f"eks delete nodegroup {ctx.env_id}/{ng}",
            [
                "eks",
                "delete-nodegroup",
                "--cluster-name",
                ctx.env_id,
                "--nodegroup-name",
                ng,
                "--region",
                ctx.region,
            ],
        )

    if ctx.mode == "apply":
        for ng in nodegroups:
            doer.aws.run(
                [
                    "eks",
                    "wait",
                    "nodegroup-deleted",
                    "--cluster-name",
                    ctx.env_id,
                    "--nodegroup-name",
                    ng,
                    "--region",
                    ctx.region,
                ]
            )
        doer.run_allow_fail(
            f"eks delete cluster {ctx.env_id}",
            ["eks", "delete-cluster", "--name", ctx.env_id, "--region", ctx.region],
        )
        doer.aws.run(
            [
                "eks",
                "wait",
                "cluster-deleted",
                "--name",
                ctx.env_id,
                "--region",
                ctx.region,
            ]
        )
