#!/usr/bin/env python3
"""
K8s Project Cleanup (Stack)

Justified Action
Goal: Force-delete stuck Kubernetes namespaces and their resources when
      normal deletion fails (e.g., stuck finalizers, terminating state).
Justification: Vigor (fix root cause), Justice (clear blockers),
               Prudence (safe defaults with explicit flags).

Usage:
  # Plan mode (dry-run)
  ./scripts/k8s_project_cleanup.py plan --cluster jetscale-prod --project jetscale-demo

  # Apply mode (destructive)
  ./scripts/k8s_project_cleanup.py apply --cluster jetscale-prod --project jetscale-demo

  # Force remove finalizers (use with caution)
  ./scripts/k8s_project_cleanup.py apply --cluster jetscale-prod \
    --project jetscale-demo --force-finalizers

Requirements:
  - kubectl configured with cluster access
  - AWS CLI configured (for EKS kubeconfig update)
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from typing import List, Optional


@dataclass
class Ctx:
    mode: str  # plan|apply
    cluster_id: str
    project_id: str
    region: str
    force_finalizers: bool = False


def run_cmd(
    cmd: List[str],
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess:
    """Run a command and return the result."""
    print(f"  $ {' '.join(cmd)}")
    return subprocess.run(
        cmd,
        check=check,
        capture_output=capture,
        text=True,
    )


def kubectl_json(cmd: List[str]) -> Optional[dict]:
    """Run kubectl command and return JSON output."""
    full_cmd = ["kubectl"] + cmd + ["-o", "json"]
    try:
        result = run_cmd(full_cmd, check=True)
        return json.loads(result.stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return None


def configure_kubeconfig(ctx: Ctx) -> bool:
    """Configure kubectl for the target cluster."""
    print(f"--- Configuring kubeconfig for cluster: {ctx.cluster_id}")
    try:
        run_cmd(
            [
                "aws",
                "eks",
                "update-kubeconfig",
                "--name",
                ctx.cluster_id,
                "--region",
                ctx.region,
            ]
        )
        return True
    except subprocess.CalledProcessError as e:
        print(f"ERROR: Failed to configure kubeconfig: {e}")
        return False


def get_namespace_status(ctx: Ctx) -> Optional[dict]:
    """Get namespace details."""
    ns = kubectl_json(["get", "namespace", ctx.project_id])
    return ns


def list_namespace_resources(ctx: Ctx) -> List[str]:
    """List all resources in the namespace."""
    resources = []

    # Get all API resources that are namespaced
    try:
        result = run_cmd(
            [
                "kubectl",
                "api-resources",
                "--namespaced=true",
                "--verbs=list",
                "-o",
                "name",
            ]
        )
        resource_types = result.stdout.strip().split("\n")
    except subprocess.CalledProcessError:
        resource_types = [
            "pods",
            "services",
            "deployments",
            "replicasets",
            "statefulsets",
            "daemonsets",
            "jobs",
            "cronjobs",
            "configmaps",
            "secrets",
            "persistentvolumeclaims",
            "serviceaccounts",
            "roles",
            "rolebindings",
            "networkpolicies",
            "ingresses",
        ]

    for rt in resource_types:
        if not rt:
            continue
        try:
            result = run_cmd(
                [
                    "kubectl",
                    "get",
                    rt,
                    "-n",
                    ctx.project_id,
                    "-o",
                    "name",
                ],
                check=False,
            )
            if result.returncode == 0 and result.stdout.strip():
                for line in result.stdout.strip().split("\n"):
                    if line:
                        resources.append(line)
        except Exception:
            pass

    return resources


def delete_namespace_resources(ctx: Ctx, resources: List[str]) -> None:
    """Delete all resources in the namespace."""
    for resource in resources:
        if ctx.mode == "plan":
            print(f"  [PLAN] kubectl delete {resource} -n {ctx.project_id}")
        else:
            try:
                run_cmd(
                    [
                        "kubectl",
                        "delete",
                        resource,
                        "-n",
                        ctx.project_id,
                        "--grace-period=0",
                        "--force",
                    ],
                    check=False,
                )
            except Exception as e:
                print(f"  WARNING: Failed to delete {resource}: {e}")


def remove_finalizers(ctx: Ctx) -> None:
    """Remove finalizers from the namespace to force deletion."""
    if ctx.mode == "plan":
        cmd = (
            f"kubectl patch namespace {ctx.project_id} -p "
            f'\'{{"metadata":{{"finalizers":[]}}}}\' --type=merge'
        )
        print(f"  [PLAN] {cmd}")
        return

    try:
        run_cmd(
            [
                "kubectl",
                "patch",
                "namespace",
                ctx.project_id,
                "-p",
                '{"metadata":{"finalizers":[]}}',
                "--type=merge",
            ]
        )
        print(f"  Removed finalizers from namespace {ctx.project_id}")
    except subprocess.CalledProcessError as e:
        print(f"  WARNING: Failed to remove finalizers: {e}")


def delete_namespace(ctx: Ctx) -> None:
    """Delete the namespace."""
    if ctx.mode == "plan":
        print(f"  [PLAN] kubectl delete namespace {ctx.project_id}")
        return

    try:
        run_cmd(
            [
                "kubectl",
                "delete",
                "namespace",
                ctx.project_id,
                "--grace-period=0",
                "--force",
            ],
            check=False,
        )
    except Exception as e:
        print(f"  WARNING: Failed to delete namespace: {e}")


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="k8s_project_cleanup.py",
        description="Force-delete stuck Kubernetes namespaces and resources.",
    )
    parser.add_argument("mode", choices=["plan", "apply"])
    parser.add_argument(
        "--cluster",
        required=True,
        help="Cluster ID (e.g., jetscale-prod, pr-6)",
    )
    parser.add_argument(
        "--project",
        required=True,
        help="Project ID / namespace (e.g., jetscale-demo)",
    )
    parser.add_argument(
        "--region",
        default="us-east-1",
        help="AWS region (default: us-east-1)",
    )
    parser.add_argument(
        "--force-finalizers",
        action="store_true",
        help="Remove finalizers from namespace (use with caution)",
    )

    args = parser.parse_args(argv[1:])

    ctx = Ctx(
        mode=args.mode,
        cluster_id=args.cluster,
        project_id=args.project,
        region=args.region,
        force_finalizers=args.force_finalizers,
    )

    print("=" * 60)
    print("K8s Project Cleanup")
    print("=" * 60)
    print(f"Mode:     {ctx.mode}")
    print(f"Cluster:  {ctx.cluster_id}")
    print(f"Project:  {ctx.project_id}")
    print(f"Region:   {ctx.region}")
    print(f"Force Finalizers: {ctx.force_finalizers}")
    print("=" * 60)

    # Configure kubeconfig
    if not configure_kubeconfig(ctx):
        return 1

    # Check namespace exists
    print(f"\n--- Checking namespace: {ctx.project_id}")
    ns = get_namespace_status(ctx)
    if not ns:
        print(f"Namespace {ctx.project_id} not found. Nothing to clean up.")
        return 0

    phase = ns.get("status", {}).get("phase", "Unknown")
    finalizers = ns.get("metadata", {}).get("finalizers", [])
    print(f"  Phase: {phase}")
    print(f"  Finalizers: {finalizers}")

    # List resources
    print(f"\n--- Listing resources in namespace: {ctx.project_id}")
    resources = list_namespace_resources(ctx)
    print(f"  Found {len(resources)} resources")
    for r in resources[:20]:  # Show first 20
        print(f"    - {r}")
    if len(resources) > 20:
        print(f"    ... and {len(resources) - 20} more")

    # Delete resources
    if resources:
        print(f"\n--- Deleting resources in namespace: {ctx.project_id}")
        delete_namespace_resources(ctx, resources)

    # Handle stuck finalizers
    if ctx.force_finalizers and finalizers:
        print(f"\n--- Removing finalizers from namespace: {ctx.project_id}")
        remove_finalizers(ctx)
    elif finalizers and phase == "Terminating":
        print("\n--- Namespace has finalizers and is stuck in Terminating state.")
        print("    To force removal, re-run with --force-finalizers")

    # Delete namespace
    print(f"\n--- Deleting namespace: {ctx.project_id}")
    delete_namespace(ctx)

    # Verify
    if ctx.mode == "apply":
        print("\n--- Verifying cleanup")
        ns = get_namespace_status(ctx)
        if ns:
            phase = ns.get("status", {}).get("phase", "Unknown")
            print(f"  Namespace still exists (phase: {phase})")
            if phase == "Terminating":
                print("  Namespace is terminating. May need --force-finalizers.")
                return 1
        else:
            print(f"  Namespace {ctx.project_id} successfully deleted.")

    print("\n" + "=" * 60)
    print("Cleanup complete.")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
