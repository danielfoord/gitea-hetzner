# Troubleshooting

Common failures after install/upgrade and how to diagnose them.

## `helm install` fails: "cannot re-use a name that is still in use"

A release named `gitea` already exists in the namespace (prior install,
possibly failed/partial).

```bash
helm list -n gitea
helm status gitea -n gitea
```

- **Release healthy, you just want to apply new values:**
  ```bash
  helm upgrade gitea gitea-charts/gitea -f gitea-values.yaml -f secrets.local.yaml -n gitea
  ```
- **Release stuck (`failed`/`pending-install`) and no data worth keeping:**
  ```bash
  helm uninstall gitea -n gitea
  kubectl delete pvc -n gitea -l app.kubernetes.io/instance=gitea
  helm install gitea gitea-charts/gitea -f gitea-values.yaml -f secrets.local.yaml -n gitea --create-namespace
  ```
  Delete the PVCs too if you want a truly clean slate — `helm uninstall`
  alone leaves them behind (see next section for why that matters).

## Gitea pod crash-looping: `password authentication failed for user "gitea"`

```
Failed to initialize ORM engine: pq: password authentication failed for user "gitea" (28P01)
```

Cause: the `postgresql` subchart generates a new random password into the
`gitea-postgresql` Secret on every fresh `helm install`, but `helm uninstall`
does **not** delete PVCs — so a reinstall can leave the old Postgres data
volume (with the *old* password baked into its `pg_authid`) paired with a
*new* Secret. Gitea reads the new Secret and gets rejected by the old DB.

Confirm:

```bash
kubectl get pvc -n gitea
kubectl get secret gitea-postgresql -n gitea -o jsonpath='{.data.password}' | base64 -d; echo
```

Fix — pick one:

- **No real data on that PVC (fresh/test cluster):** wipe Postgres's PVC so
  it reinitializes from the current Secret:
  ```bash
  helm uninstall gitea -n gitea
  kubectl delete pvc -n gitea -l app.kubernetes.io/instance=gitea
  helm install gitea gitea-charts/gitea -f gitea-values.yaml -f secrets.local.yaml -n gitea --create-namespace
  ```
- **Data on that PVC needs to be kept:** reset the DB password to match the
  current Secret instead of wiping anything:
  ```bash
  NEWPW=$(kubectl get secret gitea-postgresql -n gitea -o jsonpath='{.data.password}' | base64 -d)
  kubectl exec -it -n gitea gitea-postgresql-0 -- env PGPASSWORD=<OLD_PASSWORD> \
    psql -U postgres -c "ALTER USER gitea WITH PASSWORD '$NEWPW';"
  ```
  Needs the *old* password to authenticate first.

## Browser shows "Deployment is not secure" / Traefik's default cert

Symptom: TLS inspector shows `CN = TRAEFIK DEFAULT CERT` instead of a
Let's Encrypt cert.

1. **Check cert-manager actually issued a cert:**
   ```bash
   kubectl get certificate -n gitea
   kubectl describe certificate gitea-tls -n gitea
   ```
   Look for `Status: Ready, True` and the right DNS name (matches
   `gitea-values.yaml`'s current `<SERVER_IP>` substitution). If not
   `Ready`, chase the HTTP-01 challenge instead (see below) — the default
   cert is what Traefik falls back to when no valid cert-manager cert
   exists yet for that host.
2. **If the Certificate is `Ready`,** the problem is Ingress/Traefik, not
   cert-manager:
   ```bash
   kubectl get ingress -n gitea -o yaml
   ```
   Check `spec.tls[].hosts` and `spec.rules[].host` both match the
   hostname exactly, and `secretName: gitea-tls`.
3. **Most common cause: browsing to the bare IP instead of the hostname.**
   TLS (SNI) routing means `https://<IP>/` always gets Traefik's default
   cert, even with a valid cert configured for the hostname. Must browse
   to `https://git.<SERVER_IP>.sslip.io/`, not the IP directly.
4. If the Certificate is stuck (not `Ready`), the HTTP-01 challenge likely
   never completed — check:
   ```bash
   kubectl get certificaterequest,order,challenge -n gitea
   kubectl describe challenge -n gitea
   kubectl logs -n cert-manager deploy/cert-manager
   ```
   Usual reasons: port 80 not reachable from the internet (firewall/cloud
   firewall rule), or `gitea-values.yaml` still has the old IP/placeholder
   — re-run `./set-server-ip.sh <IP>` and `helm upgrade` before retrying.
