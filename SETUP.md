# Full Setup Guide

End-to-end instructions for standing up this Gitea deployment on a fresh Hetzner VPS (or any single-node host you can install k3s on). See [README.md](README.md) for a summary of what each manifest does, and [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md) for restoring from backup.

## 0. Prerequisites

- A Hetzner Cloud server (or equivalent) running a recent Ubuntu/Debian, with a public IPv4 address. 2 vCPU / 4GB RAM is a reasonable floor for Gitea + Postgres + an Actions runner.
- Root or sudo SSH access to that server.
- A local machine with `kubectl` and `helm` installed (or install them on the server and work there directly).
- A Backblaze B2 account, if you want the automated backup job (optional but strongly recommended — see step 8).

## 1. Firewall

Open, at minimum:

| Port | Purpose |
|---|---|
| 22/tcp | SSH to the host |
| 80/tcp | HTTP — required for Let's Encrypt HTTP-01 validation and HTTP→HTTPS redirect |
| 443/tcp | HTTPS — Gitea web UI and git-over-HTTPS |
| 6443/tcp | k3s API server (only if you'll manage the cluster remotely with `kubectl`) |

On Hetzner Cloud, set this via a Cloud Firewall attached to the server, not just `ufw`/`iptables` on the box.

> **Note on git-over-SSH:** the manifests in this repo expose Gitea only over HTTP(S) via Traefik. Gitea's own SSH server (used for `git@host:...` clone URLs) runs inside the cluster but isn't published to the internet by these manifests. If you want SSH-based git access, you'll need to additionally expose the Gitea SSH service (e.g. a `NodePort` or `hostPort` on 22/2222) — decide this before opening extra firewall ports. HTTPS clone/push works out of the box either way.

## 2. Install k3s

```bash
curl -sfL https://get.k3s.io | sh -
```

This installs a single-node k3s cluster with Traefik (ingress) and `local-path-provisioner` (storage) enabled by default — both of which `gitea-values.yaml` relies on.

Fetch the kubeconfig for use from your local machine:

```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```

Copy it locally as `~/.kube/config`, replacing `127.0.0.1` with the server's public IP (or tunnel over SSH instead of exposing 6443 publicly). Verify:

```bash
kubectl get nodes
```

## 3. Install Helm

On whichever machine you'll run `helm install` from:

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## 4. Clone this repo onto that machine

```bash
git clone <this-repo-url>
cd gitea
```

## 5. Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set crds.enabled=true
```

Wait for it to be ready:

```bash
kubectl get pods -n cert-manager
```

## 6. Create the ClusterIssuer

Edit `cluster-issuer.yaml`:
- Replace `your-email@example.com` with a real address (Let's Encrypt sends expiry/problem notices here).

Then apply:

```bash
kubectl apply -f cluster-issuer.yaml
kubectl get clusterissuer letsencrypt-prod   # should show READY=True once it can reach ACME
```

## 7. Configure and install Gitea

Edit `gitea-values.yaml`:

1. Find your server's public IP: `curl -4 ifconfig.me`
2. Replace every `<SERVER_IP>` placeholder (`DOMAIN`, `ROOT_URL`, `SSH_DOMAIN`, ingress `hosts`) with that IP. The resulting hostname (e.g. `git.203.0.113.5.sslip.io`) resolves automatically via [sslip.io](https://sslip.io) — no DNS records needed. Swap in a real domain instead if you have one.
3. Replace both `CHANGE_ME_STRONG_PASSWORD` placeholders (Postgres user, Gitea admin) with strong, unique passwords. For anything beyond a throwaway instance, move these into a `Secret` and reference it via the chart's `existingSecret` options instead of leaving plaintext in the values file — check the chart's `values.yaml` for the exact keys, as they vary by chart version.

Install:

```bash
helm repo add gitea-charts https://dl.gitea.com/charts/
helm repo update
helm install gitea gitea-charts/gitea -f gitea-values.yaml -n gitea --create-namespace
```

Watch the rollout:

```bash
kubectl get pods -n gitea -w
```

Once the `gitea-0` pod (or `gitea-...` deployment pod, depending on chart version) and `gitea-postgresql-0` are `Running`/`Ready`, check the certificate:

```bash
kubectl get certificate -n gitea
```

`READY=True` means Let's Encrypt issued the cert. If it stays `False`, check `kubectl describe certificate gitea-tls -n gitea` and `kubectl describe challenge -n gitea` — the usual cause is port 80 not reachable from the internet (firewall, or Traefik not bound to the host correctly).

Browse to `https://git.<SERVER_IP>.sslip.io/` and log in with the admin credentials from `gitea-values.yaml`.

## 8. Set up backups (do this before you have anything you can't afford to lose)

1. Create a B2 bucket (e.g. `gitea-backups`) and an application key scoped to it, in the Backblaze console.
2. Note the S3-compatible endpoint for your bucket's region, e.g. `https://s3.us-west-004.backblazeb2.com`.
3. Create the secret the CronJob reads from:

   ```bash
   kubectl create secret generic backup-secrets -n gitea \
     --from-literal=RESTIC_REPOSITORY="s3:https://s3.us-west-004.backblazeb2.com/gitea-backups" \
     --from-literal=RESTIC_PASSWORD="<a strong, separately-stored passphrase — losing this makes backups unrecoverable>" \
     --from-literal=AWS_ACCESS_KEY_ID="<B2 key ID>" \
     --from-literal=AWS_SECRET_ACCESS_KEY="<B2 application key>" \
     --from-literal=PGPASSWORD="<same Postgres password as in gitea-values.yaml>"
   ```

4. Apply the CronJob:

   ```bash
   kubectl apply -f backup-cronjob.yaml
   ```

5. Confirm the PVC name referenced in `backup-cronjob.yaml` (`gitea-shared-storage`) matches what the chart actually created:

   ```bash
   kubectl get pvc -n gitea
   ```

   If the chart names it differently, edit the `claimName` in `backup-cronjob.yaml` to match before relying on it.

6. Trigger a manual run to confirm it works, rather than waiting until 3am:

   ```bash
   kubectl create job --from=cronjob/gitea-backup gitea-backup-manual-test -n gitea
   kubectl logs -n gitea job/gitea-backup-manual-test -f
   ```

   Look for `Backup complete.` at the end. **Do not consider backups working until you've verified this run succeeded.**

## 9. Install the Actions runner (optional — only if you want Gitea's built-in CI)

1. In the Gitea web UI: *Site Administration → Actions → Runners → Create new runner*, and copy the registration token shown.
2. Create the secret and apply:

   ```bash
   kubectl create secret generic act-runner-token --from-literal=token=<TOKEN> -n gitea
   kubectl apply -f act-runner.yaml
   ```

3. Confirm the runner registered: *Site Administration → Actions → Runners* should show it online.

Note this runner uses a privileged Docker-in-Docker sidecar (see the security note in the README) — fine for a personal single-node instance, but be aware any workflow that runs here has effective root on that sidecar container.

## 10. Post-install checklist

- [ ] Can log in to the web UI over HTTPS with a valid (non-self-signed) certificate.
- [ ] Can `git clone`/`git push` over HTTPS against a test repo.
- [ ] Manual backup job run completed successfully (step 8.6).
- [ ] Actions runner shows online, if installed (step 9).
- [ ] Passwords in `gitea-values.yaml` and `backup-secrets` are not the placeholder values, and are stored somewhere durable outside the cluster (password manager, etc.) — if you lose the Postgres password with no other copy, you lose the ability to restore a Postgres dump even if the backup itself is intact.
- [ ] You've read [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md) *before* you need it, not after.
