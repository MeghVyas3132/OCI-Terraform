#!/usr/bin/env bash
#
# Installs the retry loop as a launchd agent and stops the Mac sleeping while
# it is plugged in. Everything here is reverted by scripts/uninstall-macos.sh.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.meghvyas.oci-capacity"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INTERVAL="${INTERVAL:-60}"

# launchd agents get no access to ~/Desktop, ~/Documents or ~/Downloads unless
# the executable has Full Disk Access, which /bin/bash does not. A repo under
# any of those fails at runtime with a bare "Operation not permitted" and an
# empty log, so refuse up front rather than let it fail silently every minute.
case "$REPO_ROOT" in
  "$HOME"/Desktop/*|"$HOME"/Documents/*|"$HOME"/Downloads/*)
    echo "ERROR: $REPO_ROOT sits under a macOS-protected folder."
    echo
    echo "  launchd cannot execute anything there without granting /bin/bash"
    echo "  Full Disk Access, which would apply to every script on the machine."
    echo
    echo "  Move the repo somewhere unprotected and re-run:"
    echo "      mv \"$REPO_ROOT\" ~/oci-capacity && cd ~/oci-capacity"
    exit 1
    ;;
esac

echo "==> Installing dependencies"
command -v brew >/dev/null || { echo "Homebrew required: https://brew.sh"; exit 1; }
# Terraform left homebrew-core when HashiCorp moved to the BSL licence, so it
# now needs HashiCorp's own tap. OpenTofu is an in-core drop-in if you prefer.
if ! command -v terraform >/dev/null && ! command -v tofu >/dev/null; then
  if [ "${USE_OPENTOFU:-0}" = "1" ]; then
    brew install opentofu
  else
    brew tap hashicorp/tap
    brew install hashicorp/tap/terraform
  fi
fi
command -v oci >/dev/null || brew install oci-cli

TF="$(command -v terraform || command -v tofu)"

echo "==> Checking configuration"
if [ ! -f "$REPO_ROOT/terraform/terraform.tfvars" ]; then
  echo "ERROR: terraform/terraform.tfvars is missing."
  echo "       cp terraform/terraform.tfvars.example terraform/terraform.tfvars"
  echo "       then fill it in (see README)."
  exit 1
fi

echo "==> $(basename "$TF") init"
"$TF" -chdir="$REPO_ROOT/terraform" init -input=false

echo "==> Writing launchd agent"
mkdir -p "$HOME/Library/LaunchAgents" "$REPO_ROOT/.run"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$REPO_ROOT/scripts/attempt.sh</string>
    </array>

    <!-- Fire immediately at login, then every INTERVAL seconds. If the Mac was
         asleep through several intervals, launchd fires once on wake. -->
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>$INTERVAL</integer>

    <key>StandardOutPath</key>
    <string>$REPO_ROOT/.run/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$REPO_ROOT/.run/launchd.err.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>

    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
</dict>
</plist>
PLIST_EOF

echo "==> Loading agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL"

echo "==> Keeping the Mac awake on AC power"
echo "    (needs sudo; reverted by scripts/uninstall-macos.sh)"
sudo pmset -c disablesleep 1 2>/dev/null || sudo pmset -a disablesleep 1
sudo pmset -c sleep 0 disksleep 0 displaysleep 5

cat <<SUMMARY

Installed.

  Agent      $LABEL  (every ${INTERVAL}s, and once at every login)
  Log        $REPO_ROOT/.run/attempts.log
  Sleep      disabled on AC power; battery behaviour unchanged

  Follow along:   tail -f "$REPO_ROOT/.run/attempts.log"
  Check status:   launchctl list | grep oci-capacity
  Stop it all:    scripts/uninstall-macos.sh

The lid can now be closed while plugged in and attempts will keep running.
Do not leave it in a sealed bag like this — it will not throttle itself to
stay cool. On battery it still sleeps, and attempts pause until you wake it.

SUMMARY
