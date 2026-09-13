# Gitea on k3s (Hetzner)

Kubernetes manifests for running a self-hosted Gitea instance with CI (Gitea Actions), TLS, and automated backups. Targeted at a single-node k3s cluster (e.g. a Hetzner VPS), using Traefik ingress and `local-path` storage.

## Documentation

- **[SETUP.md](SETUP.md)** — full setup instructions, from a bare server to a running instance.
- **[DISASTER-RECOVERY.md](DISASTER-RECOVERY.md)** — restoring from backup after data loss, on a new host or in place.

## Contents

| File | Purpose |
|---|---|
| [`gitea-values.yaml`](gitea-values.yaml) | Helm values for the `gitea-charts/gitea` chart — Gitea itself, in-cluster Postgres, persistence, ingress, and Gitea Actions. |
| [`cluster-issuer.yaml`](cluster-issuer.yaml) | cert-manager `ClusterIssuer` for Let's Encrypt via HTTP-01, used to provision the ingress TLS cert. |
| [`act-runner.yaml`](act-runner.yaml) | Gitea Actions runner (`act_runner`) plus a Docker-in-Docker sidecar it uses to execute job containers. |
| [`backup-cronjob.yaml`](backup-cronjob.yaml) | Nightly `CronJob` that dumps Postgres and backs up Gitea's data volume to a Backblaze B2 bucket via `restic`. |

## Prerequisites

- A k3s cluster (Traefik ingress and `local-path` storage class ship with it by default).
- `helm` and `kubectl` configured against the cluster.
- A domain/hostname pointing at the server. These manifests default to a [sslip.io](https://sslip.io) hostname (`git.<SERVER_IP>.sslip.io`) so no DNS setup is required — swap in a real domain if you have one.
- A Backblaze B2 bucket (or any S3-compatible store) if you want the backup job.

## Setup

See **[SETUP.md](SETUP.md)** for the full walkthrough (firewall, k3s, Helm, cert-manager, Gitea, Actions runner, backups, and a post-install checklist). Short version: cert-manager → `ClusterIssuer` → Gitea chart → Actions runner → backup CronJob, in that order, since each later step depends on the one before it.

## Notes

- Single-node design: Postgres and Redis-backed queues are skipped in favor of built-in level/memory queues, and storage uses `local-path` (no replication). Fine for a small self-hosted instance, not for HA.
- The Actions runner talks to a privileged DinD sidecar over plain HTTP inside the cluster network — acceptable for a single-node setup, but tighten (e.g. rootless DinD, TLS) before exposing the runner more broadly.
- All secrets in these files are placeholders (`CHANGE_ME_STRONG_PASSWORD`, `your-email@example.com`, etc.) — replace them, and prefer Kubernetes `Secret` objects over inline values for anything sensitive.
