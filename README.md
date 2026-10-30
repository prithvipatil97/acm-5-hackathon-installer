# ACM 5.0 Hackathon Installer

Automated installer for **ACM 5.0** with bundled **MCE 5.0** (ART FBC staging catalogs) on **OCP 5.0**. Hub only — it does **not** install MultiClusterObservability.

This folder is standalone. Do **not** add it to `logging-hackathon-installer`. Logging and ACM stay in separate directories.

**This directory does not contain registry credentials, kubeadmin passwords, or cloud keys.** If the cluster pull-secret already has `registry.stage.redhat.io`, the script skips the token prompt. Otherwise encode the stage token locally and paste it when asked (hidden, never logged).

## Prerequisites

- **OpenShift cluster**: OCP **5.0**
- **`oc` CLI**: already logged in with cluster-admin (`oc login` is not stored here)
- **`jq`** and **`python3`**
- **Stage registry token** (only if pull-secret lacks stage auth): from the **internal hackathon email / Slack**, not from git

## Catalog images (public ART FBC, not secrets)

Default: Testathon-pinned digests.

```
quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc@sha256:31ad04c6ed1022944edec50584728b8d03d2828d170d685f79bbf454c307174e
quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc@sha256:8738712e8b525dd7351d72144d684b81f2f64fed38f4e3480a25b052a183c487
```

`--latest` uses floating tags `acm-5.0__v5.0__multiclusterhub-rhel9` and `mce-5.0__v5.0__backplane-rhel9-operator`.

## Quick start

```bash
git clone https://github.com/prithvipatil97/acm-5-hackathon-installer.git
cd acm-5-hackathon-installer
chmod +x install-acm-50.sh
./install-acm-50.sh --email <your-kerberos-id>
```

## Obtaining the registry token (never commit it)

Credentials come from the **internal** ACM 5 hackathon email or `#acm-5-hackathon`, not from this folder.

```bash
echo -n '<username>:<password>' | base64 -w 0
```

Paste when prompted. Do not put the output in git, Slack copies of the script, or this README.

You can also use `STAGE_REGISTRY_TOKEN` or `--token` on your machine only.

## Usage

```bash
./install-acm-50.sh --email pripatil
./install-acm-50.sh --email pripatil --timeout 45
./install-acm-50.sh --email pripatil --dry-run
./install-acm-50.sh --email pripatil --latest
./install-acm-50.sh --uninstall
```

The installer **does not exit after applying YAML**. It stays running and polls until MultiClusterHub is `Running` (default timeout 30 minutes; ACM install often takes 10–20 minutes). CSV, webhook, and MCE 5.0 are also waited on. Use `--timeout 45` if you want a longer wait. If a wait times out, the script exits with an error.

After testing, uninstall **everything this script installed** (not Logging/Loki/COO):

```bash
./install-acm-50.sh --uninstall
```

That deletes MultiClusterHub → MCE → ACM/MCE operators, namespaces, leftover ACM/MCE CRDs, `acm-art`/`mce-art`, and IDMS `acm-stage`. If a leftover MultiClusterObservability exists, it is removed first. It does **not** remove Logging, Loki, COO, `logging-stage`, or the cluster pull-secret. Uninstall also stays running until those deletes finish (MCH removal can take 5–15 minutes).

## What it does

| Step | Action |
|------|--------|
| 0 | Pre-flight (`oc` login, OCP 5.0, cluster-admin). Refuses ACM 2.x leftovers |
| 0.5 | Stage token only if pull-secret has no `registry.stage.redhat.io` |
| 1 | Merge stage auth into pull-secret (skip if already present) |
| 2 | CatalogSources `acm-art` and `mce-art` (priority 100) |
| 3 | IDMS `acm-stage` (does not delete `logging-stage`) |
| 4–5 | Wait READY; delete failed acm-art/mce-art unpack jobs only |
| 6 | Detect channels: ACM prefers `release-5.0`, MCE prefers `stable-5.0` |
| 7–8 | ACM Subscription from `acm-art`; wait CSV `advanced-cluster-management.v5` |
| 9–10 | MultiClusterHub with `mce-subscription-spec` pointing at `mce-art`; wait Running |
| 11 | Summary (no secret values printed) |

## Security rules for sharing

- Share the script + this README only. **No tokens, no kubeadmin, no AWS/GCP keys, no pull-secret dumps.**
- Token stays in the internal email. Engineers generate `base64` on their own laptop.
- Logs: `/tmp/acm5-hackathon-install-*.log` (mode 0600).
- `.gitignore` blocks `.env`, `*.token`, `*pull-secret*`, `.dockerconfigjson`.

## Compatible versions

| ACM | MCE | OCP |
|-----|-----|-----|
| 5.0.0 | 5.0.0 | 5.0 |

Public OperatorHub `redhat-operators` on OCP 5.0 still shows ACM 2.17. This installer does not use that catalog.
