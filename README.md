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

- `boot_volume_size_in_gbs` defaults to **50**, leaving 150 GB of the 200 GB
  allowance for a separate block volume. Put your database there rather than on
  the boot volume — it survives an instance rebuild and snapshots independently.
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

## Idle reclamation

Oracle may reclaim Always Free compute it deems idle, and losing an A1 instance
matters more than usual — getting another one means winning the capacity race
all over again.

The test is stricter than it is usually reported. **All three** must hold across
a rolling 7-day window:

| Metric | Threshold |
|---|---|
| CPU, 95th percentile | < 20% |
| Network | < 20% |
| Memory *(A1 shapes only)* | < 20% |

Any single metric staying above 20% keeps the instance. A genuinely deployed
application clears the memory bar without trying: 20% of 12 GB is 2.4 GB, and
Postgres plus an app server exceed that sitting idle at 3am. What gets reclaimed
is a *parked* instance running nothing — not a quiet one running something.

So low traffic alone is not the risk. Deploy the app and you are fine.

**Converting to Pay As You Go removes the question anyway.** The policy is
written against Always Free accounts, and PAYG usage that stays inside the
Always Free limits is still billed at zero. Oracle's own page does not spell the
exemption out, so treat it as strong convention rather than a guarantee — and
set a budget alert at your currency's minimum when you convert, so anything
that does become billable reaches you immediately.

Resist the CPU-burner tricks (`lookbusy`, "NeverIdle" and friends). They exist
to game a CPU-only reading of the rule, they waste one of your two cores, and
the memory condition already protects a real workload.

## Running applications on it

2 OCPU of Ampere and 12 GB carries several low-traffic apps at university
scale. Memory is the ceiling, not CPU, so [`deploy/`](deploy/) caps every
container:

| Service | Cap |
|---|---|
| Caddy — TLS + host routing | 256 MB |
| Postgres — one DB per app | 3 GB |
| Redis | 512 MB |
| Each application | 1.5 GB |

That is 6.8 GB committed with two apps running, leaving room for roughly three
more before the box is full. The caps are the point: with several apps sharing
12 GB, one runaway container must not be able to OOM the machine.

```bash
scp -r deploy ubuntu@<ip>:~/            # first time
ssh ubuntu@<ip>
cd deploy && cp .env.example .env && $EDITOR .env
docker compose up -d
```

Point your DNS A records at the instance *before* the first `up`, or Caddy will
fail certificate issuance and eat into Let's Encrypt's rate limit.

Adding an app is a service block in `docker-compose.yml` and three lines in the
`Caddyfile`.

### Four things that will actually bite you

**Never build on the box.** A Next.js build saturates both cores and takes every
other app down with it. Build in CI, push to a registry, pull the tag here —
which is why the compose file uses `image:` and not `build:`.

**State belongs on the block volume.** cloud-init mounts it at `/data` and
points Docker's `data-root` there before the daemon first starts. Docker images
across several apps reach 20-40 GB quickly, and the boot disk is only 50 GB.
Everything you care about — Postgres, uploads, certificates — sits on one
volume you can snapshot.

**Catalog images do not belong in Object Storage directly.** The binding limit
is 50,000 API requests per month, not the 20 GB of capacity. A few hundred
people browsing a large catalog exhausts that in days, and it gets worse as apps
are added. Put a CDN in front, or keep media on Cloudflare R2. OCI egress itself
is 10 TB/month, so bandwidth is not the constraint.

**Payments never touch the instance.** Use hosted checkout (Razorpay, Stripe) so
card data stays out of your infrastructure and out of PCI scope.

### Don't split the allowance

Always Free lets you carve 2 OCPU into two 1-OCPU/6 GB instances. Resist it. One
2-core/12 GB host pools memory instead of stranding it, runs one Postgres
instead of two, and — the real argument — means winning the capacity race
**once** instead of twice.

### The honest limits

One instance, one availability domain, no failover: every app goes down
together, and 2 OCPU is a hard ceiling with no headroom to scale up. Fine for
university projects. If one of these takes off, a second host behind the free
10 Mbps load balancer is the next step — and a EUR 4/month Hetzner ARM box is a
saner backstop than winning another OCI capacity race.

## Notes

- Sleep is disabled **on AC only**; on battery the Mac still sleeps and
  attempts pause until it wakes. Don't leave it running in a sealed bag — it
  won't throttle itself to stay cool.
- GitHub disables scheduled workflows after 60 days without repo activity.
- Free-tier Actions cron is best-effort and drifts under load.

Prior art: [hitrov/oci-arm-host-capacity](https://github.com/hitrov/oci-arm-host-capacity),
which solves the same problem in PHP.
