#!/bin/bash
# Enable App Group entitlements once the paid Developer Team cert is available
# and `group.com.raiusage` is registered in the Developer Portal.
#
# Usage:
#   ./scripts/enable-app-groups.sh
#
# Idempotent - safe to re-run.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

APP_ENT="$ROOT/RaiUsageApp/RaiUsageApp.entitlements"

GROUP_ID="group.com.raiusage"

# Insert the App Group entitlement into the main app. Also strip the "added by
# script" placeholder comments for cleanliness.
if ! /usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$APP_ENT" &>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" "$APP_ENT"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string $GROUP_ID" "$APP_ENT"
    echo "Added App Group to $APP_ENT"
else
    echo "App Group already present in $APP_ENT"
fi

echo ""
echo "Done. Next steps:"
echo "  1. Register 'group.com.raiusage' App Group in Apple Developer Portal"
echo "  2. Add it to the App ID for com.raiusage.app"
echo "  3. Run: xcodegen generate"
echo "  4. Clean build + full local test (mega nuke + install)"
