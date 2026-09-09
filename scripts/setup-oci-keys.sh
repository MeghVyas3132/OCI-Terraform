#!/usr/bin/env bash
#
# Generates an OCI API signing keypair and prints everything you need to paste
# into the Console and into terraform.tfvars.
#
set -euo pipefail

KEY_DIR="$HOME/.oci"
KEY="$KEY_DIR/oci_api_key.pem"
PUB="$KEY_DIR/oci_api_key_public.pem"

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

if [ -f "$KEY" ]; then
  echo "Reusing the existing key at $KEY"
else
  echo "==> Generating a 2048-bit API signing key"
  openssl genrsa -out "$KEY" 2048 2>/dev/null
  chmod 600 "$KEY"
fi

openssl rsa -pubout -in "$KEY" -out "$PUB" 2>/dev/null
FINGERPRINT="$(openssl rsa -pubout -outform DER -in "$KEY" 2>/dev/null \
               | openssl md5 -c | awk '{print $2}')"

cat <<INSTRUCTIONS

────────────────────────────────────────────────────────────────────────
STEP 1 — Upload the public key to OCI

  Console > Profile menu (top right) > My profile > API keys
  > Add API key > Paste a public key

Paste exactly this, including both header lines:

INSTRUCTIONS
cat "$PUB"
cat <<INSTRUCTIONS

────────────────────────────────────────────────────────────────────────
STEP 2 — Values for terraform/terraform.tfvars

  fingerprint      = "$FINGERPRINT"
  private_key_path = "$KEY"

Collect the rest from the Console:

  tenancy_ocid     Profile menu > Tenancy               (ocid1.tenancy...)
  user_ocid        Profile menu > My profile            (ocid1.user...)
  region           top-right region selector, e.g. ap-mumbai-1
                   -> must be your HOME region, shown under Tenancy
  compartment_ocid Identity > Compartments; the root compartment's OCID
                   is the same as tenancy_ocid, which is fine to use

  ssh_public_key   $(cat "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || echo "(no ~/.ssh/id_ed25519.pub found — run: ssh-keygen -t ed25519)")

────────────────────────────────────────────────────────────────────────
STEP 3 — For the GitHub Actions half, add these repo secrets
  (Settings > Secrets and variables > Actions)

  OCI_TENANCY_OCID      same as tenancy_ocid
  OCI_USER_OCID         same as user_ocid
  OCI_FINGERPRINT       $FINGERPRINT
  OCI_REGION            your home region
  OCI_COMPARTMENT_OCID  same as compartment_ocid
  OCI_PRIVATE_KEY       the full contents of $KEY
  SSH_PUBLIC_KEY        your SSH public key

Never commit $KEY — .gitignore already blocks *.pem.
────────────────────────────────────────────────────────────────────────

INSTRUCTIONS
