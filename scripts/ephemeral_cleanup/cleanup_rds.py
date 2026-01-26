from __future__ import annotations

from .doer import Doer


def rds_delete(doer: Doer) -> None:
    ctx = doer.ctx
    data = doer.aws.json(["rds", "describe-db-instances", "--region", ctx.region]) or {}
    dbs = []
    for inst in data.get("DBInstances", []) or []:
        ident = inst.get("DBInstanceIdentifier", "")
        if ident.startswith(f"{ctx.env_id}-ephemeral"):
            dbs.append(ident)

    for db in dbs:
        doer.run_allow_fail(
            f"rds delete db-instance {db}",
            [
                "rds",
                "delete-db-instance",
                "--db-instance-identifier",
                db,
                "--skip-final-snapshot",
                "--delete-automated-backups",
                "--region",
                ctx.region,
            ],
            ignore_stderr_substrings=["DBInstanceNotFound"],
        )

    if ctx.mode == "apply":
        for db in dbs:
            doer.aws.run(
                [
                    "rds",
                    "wait",
                    "db-instance-deleted",
                    "--db-instance-identifier",
                    db,
                    "--region",
                    ctx.region,
                ]
            )

    # Best-effort: delete subnet/parameter groups after DBs are gone
    subgrps = (
        doer.aws.json(["rds", "describe-db-subnet-groups", "--region", ctx.region])
        or {}
    )
    for g in subgrps.get("DBSubnetGroups", []) or []:
        name = g.get("DBSubnetGroupName", "")
        if name.startswith(f"{ctx.env_id}-ephemeral"):
            doer.run_allow_fail(
                f"rds delete db-subnet-group {name}",
                [
                    "rds",
                    "delete-db-subnet-group",
                    "--db-subnet-group-name",
                    name,
                    "--region",
                    ctx.region,
                ],
            )

    pgs = (
        doer.aws.json(["rds", "describe-db-parameter-groups", "--region", ctx.region])
        or {}
    )
    for pg in pgs.get("DBParameterGroups", []) or []:
        name = pg.get("DBParameterGroupName", "")
        if name.startswith(f"{ctx.env_id}-ephemeral"):
            doer.run_allow_fail(
                f"rds delete db-parameter-group {name}",
                [
                    "rds",
                    "delete-db-parameter-group",
                    "--db-parameter-group-name",
                    name,
                    "--region",
                    ctx.region,
                ],
            )
