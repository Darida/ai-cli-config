---
name: cloud-run-app-setup
description: How to stand up a new Go Connect RPC server plus a static web UI on Google Cloud Run in a fresh GCP project — service accounts, least-privilege IAM, deploy scripts, and the first-deploy runbook.
---

# New Cloud Run server and web app

A server (Go, Connect RPC) and a web UI (Vite build served by nginx) as
two Cloud Run services in one GCP project. Every deploy step runs as a
dedicated service account by impersonation; the VM agents run on holds
no project role of its own.

Worked examples: `Darida/dream` (one repo: `deploy/`, `server/deploy/`,
`ui/deploy/`) and `Darida/Critter-Genetics-Breeder-Workspace` (one repo
per service, workspace-level `deploy/`).

---

## Highlights

- **Five accounts, one job each.** Project manager (grants IAM), deploy,
  debug (read-only), one runtime account per service.
- **Only the human grants the project manager's roles.** Everything else
  is granted by an idempotent `deploy/setup.sh` that runs *as* the
  project manager.
- **Scripts that change IAM or create or delete resources are
  human-run.** Agents run `push.sh`/`push-all` only when a human asks for
  a deploy.
- **Least privilege by condition.** A runtime account gets data access
  through an IAM condition naming its one bucket or secret.
- **Names in one file.** `deploy/env.sh` holds the project, region,
  accounts, and resource names; every script sources it.
- **Fail loudly.** A create step accepts only "already exists"; a delete
  step accepts only "not found". Everything else stops the script.

---

## Layout

```
deploy/
  env.sh        # project, region, accounts, names; sourced, never run
  lib.sh        # cloud_build, create_or_exists, delete_or_missing
  setup.sh      # APIs + every IAM grant; runs as project manager; human-run
  push-all      # both services' push.sh in parallel, both results reported
  README.md     # account table + first-deploy runbook
server/deploy/  # setup.sh, push.sh, wipe.sh, cloudbuild.yaml
ui/deploy/      # setup.sh, push.sh, wipe.sh, cloudbuild.yaml
```

- `setup.sh` (per service): one-time resources — its Artifact Registry
  repo, and any bucket it owns. Human-run.
- `push.sh`: Cloud Build, `gcloud run deploy`, smoke test. Prints
  `Deployed: <url>` for `push-all` to report.
- `wipe.sh`: deletes the service and its image repo; keeps data,
  secrets, accounts, and IAM. Human-run.

---

## Service accounts

| Account | Roles |
|---|---|
| project manager | `iam.serviceAccountAdmin`, `serviceusage.serviceUsageAdmin`, `resourcemanager.projectIamAdmin` (granted by the human) |
| deploy | `run.admin`, `artifactregistry.admin`, `cloudbuild.builds.editor`, `storage.admin`, `logging.logWriter`, `logging.viewer`; `iam.serviceAccountUser` on itself and on each runtime account |
| debug | `iam.securityAuditor`, `logging.viewer` |
| server runtime | only what the server touches, each by condition (e.g. `storage.objectUser` on its bucket, `secretmanager.secretAccessor` on its secret) |
| UI runtime | none |

Why these roles:
- `run.admin`, not `run.developer`: making a service public sets its IAM
  policy.
- `storage.admin`: creates the data bucket and Cloud Build's source
  staging bucket.
- `serviceAccountUser` on itself: Cloud Build runs as the deploy account
  (`--service-account`), which also needs `logging: CLOUD_LOGGING_ONLY`
  in `cloudbuild.yaml`.
- The VM gets `iam.serviceAccountTokenCreator` on the project manager
  (by the human), and on deploy and debug (by `setup.sh`).

Conditions, as project-level bindings the project manager can grant:
```
bucket: resource.name == "projects/_/buckets/B" || resource.name.startsWith("projects/_/buckets/B/objects/")
secret: resource.name.startsWith("projects/<NUMBER>/secrets/S/")
```

---

## First deploy

1. **Human, own Owner login:**
   - enable `iamcredentials.googleapis.com` and
     `serviceusage.googleapis.com` (impersonation needs the first before
     any script can run);
   - create the five accounts; the human picks the IDs and gives the
     agent the emails;
   - grant the project manager its three roles, and the VM
     `serviceAccountTokenCreator` on it.
2. Agent writes `env.sh` with those emails, and the scripts.
3. Human runs `deploy/setup.sh`: enables `iam`, `cloudresourcemanager`,
   `run`, `cloudbuild`, `artifactregistry`, `storage`, `secretmanager`,
   `logging`, then grants every row above.
4. Human creates secrets with their values
   (`printf %s "$KEY" | gcloud secrets create NAME --data-file=-`).
5. Human runs each service's `setup.sh`.
6. `deploy/push-all`.

---

## Scripts: what to get right

- **`--condition=None` on every unconditional project grant.** Once the
  policy holds one conditional binding, gcloud refuses a non-interactive
  unconditional one without it.
- **Service URLs are known before deploy:**
  `https://<service>-<project-number>.<region>.run.app`. Put both in
  `env.sh`; the server gets the UI's as its CORS origin, the UI gets the
  server's, and neither deploy waits on the other.
- **Server build context is the repo root** when the server imports
  shared packages; `cloudbuild.yaml` passes `-f server/Dockerfile`.
  Without a `.gcloudignore`, `gcloud builds submit` honors `.gitignore`.
- **A UI built from its subfolder needs `ui/.gcloudignore`**
  (`node_modules/`, `dist/`): the root `.gitignore` doesn't apply there.
- **Cache only the Docker build stage** (`--target=build`, pushed as
  `:build-cache`); the small final stage isn't worth caching.
- **On a failed build, print the build ID, the `gcloud builds log`
  command, and the log's last 30 lines.**
- **Secrets reach the server as env**:
  `--set-secrets=ENV=secret:latest`. Flags go in `--args`.
- **Request timeout** (`--timeout`) must cover the longest RPC; the
  default is 5 minutes.
- **`--max-instances=1`** when the server derives IDs by listing storage,
  or keeps any state on local disk.
- **The container disk is memory and is lost on restart.** Nothing the
  server needs later lives there; disable file-based caches or history.
- **UI runtime config:** nginx writes `/config.js` from env at start
  (served `no-store`), so one image works against any server URL.
- **Smoke tests:** the server — an RPC that reads its storage (proves
  runtime IAM); the UI — `/` has the page title and `/config.js` names
  the server URL.

---

## Access

`--allow-unauthenticated` makes each service public. A public server is
open to anyone with its URL — state that in `deploy/README.md` and
decide it with the human. Restricting access later means IAP or auth in
the app, and a browser calling an IAP-protected API cross-origin needs
extra work; serving the UI from the server (one service, one origin) is
the simpler path to IAP.

---

## Agent limits

- IAM changes (`setup.sh`) are human-run; agent auto-mode may block them
  anyway. Hand the human the exact command (`! deploy/setup.sh`).
- A `PERMISSION_DENIED` right after a grant can be propagation; wait a
  minute before concluding the grant is wrong.
- When a routine step lacks a permission, propose the one narrowest role
  for the account that failed and get approval before granting it.
