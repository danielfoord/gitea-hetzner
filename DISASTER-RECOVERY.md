# Disaster Recovery

How to restore this Gitea instance from the `restic`/B2 backups produced by `backup-cronjob.yaml`. Read this *before* you need it — confirm you can actually restore, on a test cluster, rather than finding out during a real outage.

## What's backed up, and what isn't

The nightly job (`backup-cronjob.yaml`) backs up, per run:
- The Gitea data volume (`/data` — repos, LFS objects, avatars, attachments, server config) via `restic backup`.
- A full Postgres dump (`pg_dump -F c`) of the `gitea` database, also pushed via `restic`.

Retention: 14 daily, 8 weekly, 6 monthly snapshots (pruned by `restic forget --prune` after each run).

**Not backed up by this job:**
- The Kubernetes manifests and Helm values themselves — recover those from this git repo.
- Secrets (`backup-secrets`, `act-runner-token`, any `gitea-admin-secret` you created) — these live only in the cluster (or wherever you separately stored them). **Keep a copy of every password and the `RESTIC_PASSWORD` outside the cluster.** If you lose `RESTIC_PASSWORD` with no other copy, the B2 bucket's contents become permanently unreadable, even though the data itself is still sitting there.
- The Actions runner's registration (it's re-registered fresh, cheaply, in recovery step 6).

## Recovery scenarios

- **[A. Cluster/server totally lost, rebuilding on a new host](#scenario-a-full-rebuild-on-a-new-host)** — hardware failure, accidental server deletion, etc.
- **[B. Gitea data volume corrupted/lost but cluster is otherwise fine](#scenario-b-restore-data-only-cluster-intact)** — bad PVC, `local-path` disk issue, accidental `kubectl delete pvc`.
- **[C. Need to recover a specific accidentally-deleted repo/file, not a full restore](#scenario-c-partial-restore)**.

---

## Scenario A: Full rebuild on a new host

Starting from nothing (new Hetzner server, or same server reprovisioned).

### 1. Rebuild the cluster

Follow [SETUP.md](SETUP.md) steps 1–6 (firewall, k3s, Helm, cert-manager, ClusterIssuer) exactly as for a fresh install. Use the same domain/IP scheme if possible (a new server IP means a new `sslip.io` hostname and a fresh cert — that's fine, just update DNS/bookmarks after).

### 2. Install Gitea, but don't let it initialize fresh

```bash
helm install gitea gitea-charts/gitea -f gitea-values.yaml -f secrets.local.yaml -n gitea --create-namespace
```

`secrets.local.yaml` is gitignored, so it isn't in this repo — recreate it from wherever the real passwords are separately stored (password manager, etc; see [What's backed up](#whats-backed-up-and-what-isnt)) before running this.

Let it come up once (this creates the PVCs and an initial, empty database) — you're about to overwrite its contents, not use this data.

### 3. Scale everything down before touching data

```bash
kubectl scale deployment gitea -n gitea --replicas=0        # exact deployment name may differ by chart version — check: kubectl get deploy -n gitea
kubectl scale statefulset gitea-postgresql -n gitea --replicas=0
```

Confirm no pods are still running before continuing:

```bash
kubectl get pods -n gitea
```

### 4. Restore the data volume via restic

Recreate the `backup-secrets` secret (from your separately-stored copy of the credentials — see [What's backed up](#whats-backed-up-and-what-isnt)):

```bash
kubectl create secret generic backup-secrets -n gitea \
  --from-literal=RESTIC_REPOSITORY="s3:https://s3.us-west-004.backblazeb2.com/gitea-backups" \
  --from-literal=RESTIC_PASSWORD="<your restic passphrase>" \
  --from-literal=AWS_ACCESS_KEY_ID="<B2 key ID>" \
  --from-literal=AWS_SECRET_ACCESS_KEY="<B2 application key>" \
  --from-literal=PGPASSWORD="<postgres password>"
```

Find the PVC name and run a one-off restore pod mounting it:

```bash
kubectl get pvc -n gitea   # note the Gitea data PVC name, e.g. gitea-shared-storage

kubectl run restic-restore -n gitea --rm -it --restart=Never \
  --image=restic/restic:0.16 \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "restic-restore",
      "image": "restic/restic:0.16",
      "command": ["sh"],
      "stdin": true,
      "tty": true,
      "envFrom": [{"secretRef": {"name": "backup-secrets"}}],
      "volumeMounts": [{"name": "data", "mountPath": "/data"}]
    }],
    "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "gitea-shared-storage"}}]
  }
}'
```

Inside the resulting shell:

```bash
restic snapshots                       # confirm the repo is reachable and pick a snapshot ID
                                        # (leave blank / use `latest` for the most recent)
restic restore latest --target / --include /data
exit
```

This overwrites the PVC's contents with the backed-up repos/LFS/config. The Postgres dump was also captured under `/dump/gitea-db.dump` at backup time — it's *inside this same snapshot*, but not under `/data`, so restore it separately:

```bash
kubectl run restic-restore-db -n gitea --rm -it --restart=Never \
  --image=restic/restic:0.16 \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "restic-restore-db",
      "image": "restic/restic:0.16",
      "command": ["sh"],
      "stdin": true,
      "tty": true,
      "envFrom": [{"secretRef": {"name": "backup-secrets"}}],
      "volumeMounts": [{"name": "data", "mountPath": "/restore"}]
    }],
    "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "gitea-shared-storage"}}]
  }
}'
```

```bash
restic restore latest --target /restore --include /dump/gitea-db.dump
exit
```

You now have `gitea-db.dump` sitting inside the same PVC (under a `dump/` subdirectory) — a `kubectl cp` from a pod with that PVC mounted, or a quick `kubectl exec`, gets it to wherever you'll run `pg_restore` from next.

### 5. Restore Postgres

Scale Postgres back up (leave Gitea itself at 0 replicas until the DB is confirmed restored):

```bash
kubectl scale statefulset gitea-postgresql -n gitea --replicas=1
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql -n gitea --timeout=120s
```

Copy `gitea-db.dump` into a pod that can reach Postgres (or `kubectl cp` it in from your local machine), then:

```bash
kubectl exec -it -n gitea gitea-postgresql-0 -- bash
PGPASSWORD="<postgres password>" pg_restore -h localhost -U gitea -d gitea --clean --if-exists /path/to/gitea-db.dump
exit
```

`--clean --if-exists` drops and recreates conflicting objects so this is safe to run against the just-initialized, empty database from step 2.

### 6. Bring Gitea back up

```bash
kubectl scale deployment gitea -n gitea --replicas=1
kubectl get pods -n gitea -w
```

Once ready, log in and spot-check: a few repos have their expected commits/issues, LFS objects pull correctly, admin settings look right.

Re-register the Actions runner (registration tokens aren't part of the backup — see [SETUP.md](SETUP.md) step 9):

```bash
kubectl create secret generic act-runner-token --from-literal=token=<NEW_TOKEN> -n gitea
kubectl apply -f act-runner.yaml
```

Re-apply the backup CronJob so nightly backups resume:

```bash
kubectl apply -f backup-cronjob.yaml
```

---

## Scenario B: Restore data only, cluster intact

Same as Scenario A steps 3–6, skipping the cluster/Gitea reinstall in steps 1–2 (Gitea, cert-manager, etc. are already there — just scale down, restore, scale up).

---

## Scenario C: Partial restore

To recover a single repo or file without touching the live instance, restore into a scratch location instead of overwriting `/data`:

```bash
kubectl run restic-browse -n gitea --rm -it --restart=Never \
  --image=restic/restic:0.16 \
  --overrides='{"spec":{"containers":[{"name":"restic-browse","image":"restic/restic:0.16","command":["sh"],"stdin":true,"tty":true,"envFrom":[{"secretRef":{"name":"backup-secrets"}}]}]}}'
```

```bash
restic snapshots                                  # pick the snapshot to pull from
restic ls latest                                   # find the path you need
restic restore latest --target /scratch --include /data/gitea-repositories/<owner>/<repo>.git
```

Copy the recovered `.git` directory back out with `kubectl cp`, then either re-add it to Gitea's repo storage directly (with the pod scaled down) or push it into a fresh repo via a normal `git push`.

---

## Verifying backups actually work

Don't wait for a real disaster to find out `RESTIC_PASSWORD` was wrong or the PVC name changed. At minimum quarterly:

1. Spin up a throwaway namespace or cluster.
2. Run through Scenario A steps 4–5 against it.
3. Confirm a known repo and its commit history come back intact.
4. Tear the throwaway environment down.

If you change `backup-cronjob.yaml`'s target PVC name, the chart version, or the B2 bucket/keys, re-run this check — silent backup failures are the whole point of a disaster recovery doc no one has tested.
