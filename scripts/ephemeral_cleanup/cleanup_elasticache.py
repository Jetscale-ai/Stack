from __future__ import annotations

import time

from .doer import Doer


def elasticache_serverless_delete(doer: Doer) -> None:
    """
    Delete ElastiCache Serverless caches first; these create requester-managed VPC endpoints.
    """
    ctx = doer.ctx
    data = doer.aws.json(["elasticache", "describe-serverless-caches", "--region", ctx.region]) or {}
    caches = []
    for c in data.get("ServerlessCaches", []) or []:
        name = c.get("ServerlessCacheName", "")
        if name.startswith(f"{ctx.env_id}-ephemeral"):
            caches.append(name)

    for name in caches:
        doer.run_allow_fail(
            f"elasticache delete serverless cache {name}",
            ["elasticache", "delete-serverless-cache", "--region", ctx.region, "--serverless-cache-name", name],
        )

    if ctx.mode == "apply":
        for name in caches:
            while True:
                rc = doer.aws.run(["elasticache", "describe-serverless-caches", "--region", ctx.region, "--serverless-cache-name", name]).rc
                if rc != 0:
                    break
                print(f"--- waiting for serverless cache delete: {name}")
                time.sleep(30)

