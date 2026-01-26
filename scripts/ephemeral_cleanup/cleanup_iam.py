from __future__ import annotations

from .doer import Doer


def delete_tagged_oidc_providers(doer: Doer, tagged_arns: list[str]) -> None:
    for arn in tagged_arns:
        if ":oidc-provider/" in arn:
            doer.run_allow_fail(
                f"iam delete oidc provider {arn}",
                [
                    "iam",
                    "delete-open-id-connect-provider",
                    "--open-id-connect-provider-arn",
                    arn,
                ],
            )


def iam_cleanup_ephemeral_roles(doer: Doer) -> None:
    """
    IAM managed policies can't be deleted while attached.
    Clean up ephemeral roles/instance-profiles first, then policy
    deletion becomes possible.
    """
    ctx = doer.ctx
    prefix = f"{ctx.env_id}-ephemeral"

    profiles = doer.aws.json(["iam", "list-instance-profiles"]) or {}
    for prof in profiles.get("InstanceProfiles", []) or []:
        name = prof.get("InstanceProfileName") or ""
        if not name.startswith(prefix):
            continue
        for role in prof.get("Roles", []) or []:
            rname = role.get("RoleName")
            if rname:
                doer.run_allow_fail(
                    f"iam remove role from instance profile {name}/{rname}",
                    [
                        "iam",
                        "remove-role-from-instance-profile",
                        "--instance-profile-name",
                        name,
                        "--role-name",
                        rname,
                    ],
                )
        doer.run_allow_fail(
            f"iam delete instance profile {name}",
            ["iam", "delete-instance-profile", "--instance-profile-name", name],
        )

    roles = doer.aws.json(["iam", "list-roles"]) or {}
    for role in roles.get("Roles", []) or []:
        name = role.get("RoleName") or ""
        if not name.startswith(prefix):
            continue

        attached = (
            doer.aws.json(["iam", "list-attached-role-policies", "--role-name", name])
            or {}
        )
        for ap in attached.get("AttachedPolicies", []) or []:
            arn = ap.get("PolicyArn")
            if arn:
                doer.run_allow_fail(
                    f"iam detach role policy {name} {arn}",
                    [
                        "iam",
                        "detach-role-policy",
                        "--role-name",
                        name,
                        "--policy-arn",
                        arn,
                    ],
                )

        inline = doer.aws.json(["iam", "list-role-policies", "--role-name", name]) or {}
        for pname in inline.get("PolicyNames", []) or []:
            doer.run_allow_fail(
                f"iam delete role inline policy {name}/{pname}",
                [
                    "iam",
                    "delete-role-policy",
                    "--role-name",
                    name,
                    "--policy-name",
                    pname,
                ],
            )

        doer.run_allow_fail(
            f"iam delete role {name}",
            ["iam", "delete-role", "--role-name", name],
        )
