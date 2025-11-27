# Preview Environment Infrastructure

This directory contains the IaC (Terraform/Pulumi) to provision the base
dependencies for ephemeral preview environments if they require dedicated
resources (e.g. VPCs, wildcards).

Often, preview envs share the **Live** cluster, so this might remain empty or
just contain namespace constraints.

