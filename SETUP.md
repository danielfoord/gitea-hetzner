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
| 22/tcp | SSH to the host (your login, the real OS sshd) |
| 443/tcp | HTTPS — Gitea web UI and git-over-HTTPS |
| 2222/tcp | Gitea git-over-SSH (see note below) |
| 80/tcp | HTTP — required for Let's Encrypt HTTP-01 validation and HTTP→HTTPS redirect |
| 6443/tcp | k3s API server (only if you'll manage the cluster remotely with `kubectl`) |

On Hetzner Cloud, set this via a Cloud Firewall attached to the server, not just `ufw`/`iptables` on the box.

> **Note on git-over-SSH:** the host's own sshd already owns port 22, and Traefik/ingress can't proxy raw SSH (it's L7 HTTP only) — so Gitea's SSH is exposed separately, on **2222**, via `service.ssh.hostPort` in `gitea-values.yaml` (binds straight to the node, no NodePort range needed; fine for this single-node setup). `gitea.config.server.SSH_PORT` is set to match, so the UI/clone instructions show the right port.
>
> Because it's a non-standard port, plain `git@host:owner/repo.git` won't work (that syntax assumes 22) — use either:
> - `ssh://git@git.<SERVER_IP>.sslip.io:2222/owner/repo.git`, or
>
> **Don't** try `git@git.<SERVER_IP>.sslip.io:2222/owner/repo.git` — that's not
> valid port syntax. scp-shorthand (`user@host:path`) has no port field; git
> silently reads `2222/owner/repo.git` as the *path* and connects on the
> default port 22 (your OS sshd) instead, which just prompts for a system
> password. The port only works with an explicit `ssh://` scheme, or via:
> - a `~/.ssh/config` entry:
>   ```
>   Host git.<SERVER_IP>.sslip.io
>     Port 2222
>   ```
>   after which plain `git@git.<SERVER_IP>.sslip.io:owner/repo.git` works as normal.
>
> Make sure your public key is added under the Gitea user's *Settings → SSH/GPG Keys* (`https://git.<SERVER_IP>.sslip.io/user/settings/keys`) — that's separate from any key your OS sshd on port 22 already trusts.

## 2. Install k3s

```bash
curl -sfL https://get.k3s.io | sh -
```

This installs a single-node k3s cluster with Traefik (ingress) and `local-path-provisioner` (storage) enabled by default — both of which `gitea-values.yaml` relies on.

**If you're running `kubectl`/`helm` directly on the server** (e.g. you SSH'd in and are working as root there), k3s writes its kubeconfig to `/etc/rancher/k3s/k3s.yaml`, not the default `~/.kube/config` — `kubectl`/`helm` won't find the cluster until you point at it:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes   # sanity check
```

Without this, `kubectl`/`helm` fall back to `http://localhost:8080` and fail with `Kubernetes cluster unreachable: ... dial tcp [::1]:8080: connect: connection refused`. Make it stick across sessions:

```bash
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
```

**If you're managing the cluster from your local machine instead**, fetch the kubeconfig from the server:

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
- Replace `your-email@example.com` with a real address (Let's Encrypt sends expiry/problem notices here). This isn't optional — Let's Encrypt's ACME server rejects known placeholder domains, so leaving it as-is fails with:
  ```
  Failed to register ACME account: 400 urn:ietf:params:acme:error:invalidContact:
  Error validating contact(s) :: contact email has forbidden domain "example.com"
  ```
  If you hit this, fix the email in `cluster-issuer.yaml` and re-apply (step below) — the `ClusterIssuer` retries registration on each apply.

Then apply:

```bash
kubectl apply -f cluster-issuer.yaml
kubectl get clusterissuer letsencrypt-prod   # should show READY=True once it can reach ACME
```

**If you're still iterating** (DNS/ingress not confirmed working yet, or you're debugging a challenge failure), use `cluster-issuer-staging.yaml` instead/first and point `gitea-values.yaml`'s ingress annotation at `letsencrypt-staging`. Staging certs aren't trusted by browsers, but retries there don't count against Let's Encrypt's production rate limits (5 duplicate certs per registered domain per week — easy to hit while troubleshooting). Switch the annotation back to `letsencrypt-prod` once a staging cert issues cleanly.

## 7. Configure and install Gitea

Edit `gitea-values.yaml`:

1. Find your server's public IP: `curl -4 ifconfig.me`
2. Replace every `<SERVER_IP>` placeholder (`DOMAIN`, `ROOT_URL`, `SSH_DOMAIN`, ingress `hosts`) with that IP — run `./set-server-ip.sh <IP>` to do this in one shot (it backs up the file to `gitea-values.yaml.bak` and prints what changed). The resulting hostname (e.g. `git.203.0.113.5.sslip.io`) resolves automatically via [sslip.io](https://sslip.io) — no DNS records needed. Swap in a real domain instead if you have one.
3. **`gitea-values.yaml` declares no passwords at all** — don't add any. It's tracked in git, and a committed password stays in history even after you later change it. Instead:

   ```bash
   cp secrets.local.yaml.example secrets.local.yaml   # gitignored, never commit this copy
   ```

   Fill in the Gitea admin password and email in `secrets.local.yaml` — required, since the chart only creates the admin user if a password is set. Leave the commented-out Postgres password block alone unless you specifically need a predictable one; left unset, the `postgresql` subchart generates a strong random password itself.

Install, passing both files — the later one wins on any overlapping key:

```bash
helm repo add gitea-charts https://dl.gitea.com/charts/
helm repo update
helm install gitea gitea-charts/gitea -f gitea-values.yaml -f secrets.local.yaml -n gitea --create-namespace
```

`gitea-values.yaml` already disables `postgresql-ha` — the chart enables it by default alongside plain `postgresql`, and having both on fails install with `Only one of postgresql or postgresql-ha can be enabled at the same time.` If you hit that anyway (e.g. after a values change), check `postgresql-ha.enabled: false` is still present.

Watch the rollout:

```bash
kubectl get pods -n gitea -w
```

Once the `gitea-0` pod (or `gitea-...` deployment pod, depending on chart version) and `gitea-postgresql-0` are `Running`/`Ready`, check the certificate:

```bash
kubectl get certificate -n gitea
```

`READY=True` means Let's Encrypt issued the cert. If it stays `False`, check `kubectl describe certificate gitea-tls -n gitea` and `kubectl describe challenge -n gitea` — the usual cause is port 80 not reachable from the internet (firewall, or Traefik not bound to the host correctly).

Browse to `https://git.<SERVER_IP>.sslip.io/` and log in with the admin credentials from `secrets.local.yaml`.

## 8. Set up backups (do this before you have anything you can't afford to lose)

1. Create a B2 bucket (e.g. `gitea-backups`) and an application key scoped to it, in the Backblaze console.
2. Note the S3-compatible endpoint for your bucket's region, e.g. `https://s3.us-west-004.backblazeb2.com`.
3. Create the secret the CronJob reads from:

   ```bash
   kubectl create secret generic backup-secrets -n gitea \
     --from-literal=RESTIC_REPOSITORY="s3:https://s3.us-west-004.backblazeb2.com/gitea-backups" \
     --from-literal=RESTIC_PASSWORD="<a strong, separately-stored passphrase — losing this makes backups unrecoverable>" \
     --from-literal=AWS_ACCESS_KEY_ID="<B2 key ID>" \
     --from-literal=AWS_SECRET_ACCESS_KEY="<B2 application key>"
   ```

   No `PGPASSWORD` here — the backup job's `pg-dump` container reads that directly from the `gitea-postgresql` Secret the `postgresql` subchart already created, so the Postgres password only ever needs to be entered once (in `secrets.local.yaml`).

4. Apply the CronJob:

   ```bash
   kubectl apply -f backup-cronjob.yaml
   ```

5. Confirm the PVC name referenced in `backup-cronjob.yaml` (`gitea-shared-storage`) matches what the chart actually created:

   ```bash
   kubectl get pvc -n gitea
   ```

   If the chart names it differently, edit the `claimName` in `backup-cronjob.yaml` to match before relying on it.

   Also confirm the `pg-dump` init container's image tag (`postgres:16-alpine`) matches the Postgres version the subchart actually deployed:

   ```bash
   kubectl exec -n gitea gitea-postgresql-0 -- psql --version
   ```

   A newer `pg_dump` client talking to an older server is generally fine; a client *older* than the server often isn't — bump the tag in `backup-cronjob.yaml` if these don't line up.

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
- [ ] The Gitea admin password lives only in `secrets.local.yaml` (never hardcoded into the tracked `gitea-values.yaml`) and is stored somewhere durable outside the cluster (password manager, etc.) — it's the one credential nothing in this repo can recover for you.
- [ ] `secrets.local.yaml` was never `git add`ed (check `git status` — it should show as untracked, not staged).
- [ ] `backup-secrets` holds the B2/restic credentials, and only those — no `PGPASSWORD` in it (that's read from the `gitea-postgresql` Secret directly; see [What's backed up](DISASTER-RECOVERY.md#whats-backed-up-and-what-isnt)).
- [ ] You've read [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md) *before* you need it, not after.
