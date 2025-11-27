# Live Environment Infrastructure

This directory contains the IaC definition for the Production EKS Cluster.

## State Management

- Backend: S3
- Locking: DynamoDB

## Modules

- VPC
- EKS (Blue/Green compatible)
- RDS (if not using Bitnami in chart)
- ElastiCache (if not using Bitnami in chart)

