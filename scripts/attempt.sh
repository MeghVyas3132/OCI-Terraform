#!/usr/bin/env bash
#
# One attempt at claiming an Always Free A1 instance.
#
# Designed to be fired repeatedly and blindly (launchd every 60s, GitHub
# Actions every 5m). Exits 0 on "no capacity yet" because that is the normal,
# expected outcome and a non-zero exit would just spam failure notifications.
#
# Exit codes:
#   0  attempt made, no capacity yet (or already won, or backing off)
#   3  we won  — instance exists
#   4  hard failure — bad credentials, quota exceeded, broken config
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
RUN_DIR="$REPO_ROOT/.run"
LOG="$RUN_DIR/attempts.log"
SUCCESS="$RUN_DIR/SUCCESS"
AD_INDEX_FILE="$RUN_DIR/ad_index"
BACKOFF_FILE="$RUN_DIR/backoff_until"
LOCK="$RUN_DIR/lock"

# Homebrew and pipx live outside launchd's default PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

mkdir -p "$RUN_DIR"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

notify() {
  # Best effort. Silent no-op on Linux / CI.
  [ "$(uname)" = "Darwin" ] || return 0
  osascript -e "display notification \"$2\" with title \"$1\" sound name \"Glass\"" 2>/dev/null || true
}

# --- Already won? Cheapest possible check, no API call. -------------------
if [ -f "$SUCCESS" ]; then
  log "SUCCESS sentinel present; nothing to do. Run scripts/uninstall-macos.sh to stop the timer."
  exit 3
fi

# --- Serialize. A slow apply must not overlap the next launchd fire. ------
if ! mkdir "$LOCK" 2>/dev/null; then
  # Clear a lock orphaned by a crash or a hard sleep (older than 30 min).
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    log "Clearing stale lock."
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rm -rf "$LOCK"' EXIT

# --- Respect a 429 backoff window. ----------------------------------------
if [ -f "$BACKOFF_FILE" ]; then
  until_ts="$(cat "$BACKOFF_FILE" 2>/dev/null || echo 0)"
  now_ts="$(date +%s)"
  if [ "$now_ts" -lt "$until_ts" ]; then
    log "Rate limited; backing off for $(( until_ts - now_ts ))s more."
    exit 0
  fi
  rm -f "$BACKOFF_FILE"
fi

# --- Config sanity --------------------------------------------------------
if [ ! -f "$TF_DIR/terraform.tfvars" ] && [ -z "${TF_VAR_tenancy_ocid:-}" ]; then
  log "FATAL: no terraform/terraform.tfvars and no TF_VAR_* env vars. Nothing to authenticate with."
  exit 4
fi

# Terraform proper or OpenTofu — both read the same config.
if command -v terraform >/dev/null; then
  TF=terraform
elif command -v tofu >/dev/null; then
  TF=tofu
else
  log "FATAL: neither terraform nor tofu is on PATH."
  exit 4
fi

# --- Authoritative win check via the API, not Terraform state. ------------
# Two runners share this repo's config but not its state file, so the API is
# the only source of truth about whether an instance already exists.
INSTANCE_NAME="$(grep -E '^\s*instance_name' "$TF_DIR/terraform.tfvars" 2>/dev/null | head -1 | sed 's/.*=\s*//; s/"//g; s/[[:space:]]*$//')"
INSTANCE_NAME="${INSTANCE_NAME:-${TF_VAR_instance_name:-arm-always-free}}"
COMPARTMENT="$(grep -E '^\s*compartment_ocid' "$TF_DIR/terraform.tfvars" 2>/dev/null | head -1 | sed 's/.*=\s*//; s/"//g; s/[[:space:]]*$//')"
COMPARTMENT="${COMPARTMENT:-${TF_VAR_compartment_ocid:-}}"

if command -v oci >/dev/null && [ -n "$COMPARTMENT" ]; then
  existing="$(oci compute instance list \
      --compartment-id "$COMPARTMENT" \
      --display-name "$INSTANCE_NAME" \
      --lifecycle-state RUNNING \
      --query 'length(data)' --raw-output 2>/dev/null || echo "0")"
  if [ "${existing:-0}" != "0" ]; then
    ip="$(oci compute instance list-vnics --instance-id \
          "$(oci compute instance list --compartment-id "$COMPARTMENT" --display-name "$INSTANCE_NAME" \
             --lifecycle-state RUNNING --query 'data[0].id' --raw-output 2>/dev/null)" \
          --query 'data[0]."public-ip"' --raw-output 2>/dev/null || echo "unknown")"
    log "WON — instance '$INSTANCE_NAME' is RUNNING at ${ip}."
    date '+%Y-%m-%d %H:%M:%S' > "$SUCCESS"
    echo "public_ip=$ip" >> "$SUCCESS"
    notify "OCI capacity acquired" "$INSTANCE_NAME is running at $ip"
    exit 3
  fi
fi

# --- Rotate availability domain. ------------------------------------------
AD_INDEX="$(cat "$AD_INDEX_FILE" 2>/dev/null || echo 0)"
echo $(( (AD_INDEX + 1) % 3 )) > "$AD_INDEX_FILE"

# --- Attempt --------------------------------------------------------------
cd "$TF_DIR" || exit 4
[ -d .terraform ] || "$TF" init -input=false -no-color >>"$LOG" 2>&1

out="$("$TF" apply -auto-approve -input=false -no-color -lock-timeout=60s \
        -var "ad_index=$AD_INDEX" 2>&1)"
rc=$?
lower="$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')"

if [ $rc -eq 0 ]; then
  ip="$("$TF" output -raw public_ip 2>/dev/null || echo unknown)"
  ad="$("$TF" output -raw availability_domain 2>/dev/null || echo unknown)"
  log "WON — instance created in $ad at $ip"
  { date '+%Y-%m-%d %H:%M:%S'; echo "public_ip=$ip"; echo "ad=$ad"; } > "$SUCCESS"
  notify "OCI capacity acquired" "Instance up at $ip"
  # Stop the launchd timer from a detached shell so we don't kill ourselves mid-write.
  if [ "$(uname)" = "Darwin" ]; then
    ( sleep 5; launchctl bootout "gui/$(id -u)/com.meghvyas.oci-capacity" 2>/dev/null ) >/dev/null 2>&1 &
  fi
  exit 3
fi

case "$lower" in
  *"out of host capacity"*|*outofhostcapacity*)
    log "AD[$AD_INDEX]: out of host capacity. Will retry."
    exit 0 ;;
  *toomanyrequests*|*"429"*|*"rate limit"*)
    echo $(( $(date +%s) + 900 )) > "$BACKOFF_FILE"
    log "AD[$AD_INDEX]: rate limited (429). Backing off 15 minutes."
    exit 0 ;;
  *limitexceeded*|*"quota"*)
    log "FATAL: limit/quota exceeded. You may already hold your 2 free OCPUs. Output:"
    printf '%s\n' "$out" | tail -20 | tee -a "$LOG"
    notify "OCI retry stopped" "Quota exceeded — check the log."
    exit 4 ;;
  *notauthenticated*|*notauthorized*|*"401"*|*"could not be found"*)
    log "FATAL: authentication or config problem. Output:"
    printf '%s\n' "$out" | tail -20 | tee -a "$LOG"
    notify "OCI retry stopped" "Auth error — check the log."
    exit 4 ;;
  *)
    log "AD[$AD_INDEX]: attempt failed (rc=$rc). Last lines:"
    printf '%s\n' "$out" | tail -12 | tee -a "$LOG"
    exit 0 ;;
esac
