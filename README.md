# OCI-Terraform

Claims an Oracle Cloud **Always Free** Ampere A1 instance by retrying until
capacity appears.

Oracle's free ARM instances are permanently oversubscribed in most regions, so
`terraform apply` fails with `Out of host capacity`. There is no waitlist and no
notification — capacity is released in small windows and taken within seconds.
The only reliable strategy is to keep asking.

This repo runs that loop in two places at once:

| Runner | Cadence | Runs when the laptop is off? |
|---|---|---|
| GitHub Actions | every ~5 min | yes |
| macOS `launchd` | every 60 s | only while the Mac is awake |

Whichever wins first stops the other, because both check the OCI API for an
existing instance before every attempt.

---

## Current Always Free limits

Oracle **halved** the A1 allowance on **15 June 2026** without announcing it.
The defaults in this repo are the current ceiling:

| Resource | Allowance |
|---|---|
| OCPUs | **2** (was 4) |
| Memory | **12 GB** (was 24) |
| Block storage | 200 GB total, across *all* boot + block volumes |
| Boot volume | 47 GB minimum, 50 GB default |

Two caveats worth knowing before you start:

- The default `boot_volume_size_in_gbs = 200` consumes your **entire** storage
  allowance. You will not be able to create any other volume. Drop it to 50 if
  you would rather keep room to spare.
- Always Free A1 exists **only in your home region**. Pointing `region` at
  anything else either fails or quietly bills you.

Sources: [Oracle Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) ·
[InfoQ on the June 2026 cut](https://www.infoq.com/news/2026/07/oracle-cloud-free-tier-limits/)

---

## Setup

### 1. Credentials

```bash
./scripts/setup-oci-keys.sh
```

Generates an API signing key and prints the public key to paste into
**Console → Profile → My profile → API keys**, along with every OCID you need
and where to find it.

### 2. Configure

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars
```

`terraform.tfvars` and `*.pem` are gitignored. Keep them that way.

### 3a. Run it on the Mac

```bash
./scripts/install-macos.sh
```

Installs Terraform and the OCI CLI, registers a `launchd` agent that fires at
login and every 60 s thereafter, and disables sleep **on AC power** so attempts
continue with the lid shut.

```bash
tail -f .run/attempts.log          # watch it work
launchctl list | grep oci-capacity # confirm it is loaded
./scripts/uninstall-macos.sh       # stop, and restore normal sleep
```

### 3b. Run it on GitHub Actions

Add these under **Settings → Secrets and variables → Actions**:

`OCI_TENANCY_OCID` · `OCI_USER_OCID` · `OCI_FINGERPRINT` · `OCI_REGION` ·
`OCI_COMPARTMENT_OCID` · `OCI_PRIVATE_KEY` · `SSH_PUBLIC_KEY`

The workflow then runs on its own. On success it opens an issue with the public
IP — which emails you — and disables itself.

---

## What happens on a win

The instance is created, `.run/SUCCESS` is written, a macOS notification fires,
and both runners shut themselves off. Connect with:

```bash
ssh ubuntu@$(terraform -chdir=terraform output -raw public_ip)
```

---

## How the retry loop behaves

[`scripts/attempt.sh`](scripts/attempt.sh) is a single attempt, safe to fire
blindly. It:

- **checks the OCI API first**, not Terraform state, so two runners sharing no
  state file still agree on whether you have already won;
- **rotates availability domain** each attempt, since capacity frees up in one
  AD at a time;
- **backs off 15 minutes on HTTP 429**, because hammering the API gets you
  throttled and slows you down;
- **stops hard** on quota or auth errors instead of retrying forever against a
  problem retrying cannot fix;
- **holds a lock**, so a slow apply never overlaps the next timer fire.

Exit codes: `0` no capacity yet · `3` won · `4` broken config.

`ignore_changes` on the instance means a later apply will not destroy a
hard-won instance just because the AD index has rotated on.

---

## Cost

Everything here stays inside Always Free, provided you keep `ocpus ≤ 2`,
`memory_in_gbs ≤ 12`, total storage ≤ 200 GB, and stay in your home region.
Exceeding any of those silently converts the instance to a paid one.

## Notes

- Sleep is disabled **on AC only**; on battery the Mac still sleeps and
  attempts pause until it wakes. Don't leave it running in a sealed bag — it
  won't throttle itself to stay cool.
- GitHub disables scheduled workflows after 60 days without repo activity.
- Free-tier Actions cron is best-effort and drifts under load.

Prior art: [hitrov/oci-arm-host-capacity](https://github.com/hitrov/oci-arm-host-capacity),
which solves the same problem in PHP.
