#!/usr/bin/env bash
#
# Reverts everything install-macos.sh did.
#
set -uo pipefail

LABEL="com.meghvyas.oci-capacity"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Unloading agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "    unloaded" || echo "    was not loaded"
rm -f "$PLIST" && echo "    removed $PLIST"

echo "==> Restoring sleep behaviour"
sudo pmset -c disablesleep 0 2>/dev/null || sudo pmset -a disablesleep 0
sudo pmset -c sleep 10 disksleep 10 displaysleep 5
echo "    the Mac will sleep normally again"

echo
echo "Done. Terraform state and logs are untouched in .run/ and terraform/."
echo "Your instance, if you got one, is unaffected."
