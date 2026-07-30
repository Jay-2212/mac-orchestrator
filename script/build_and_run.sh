#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Mac Orchestrator"
BUNDLE_ID="com.jay.mac-orchestrator"
APP_BUNDLE="$PROJECT_DIR/dist/$APP_NAME.app"

"$PROJECT_DIR/script/package_app.sh" >/dev/null

/usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
  if ! /usr/bin/pgrep -f "$APP_BUNDLE/Contents/MacOS/MacOrchestrator" >/dev/null; then
    break
  fi
  /bin/sleep 1
done

case "$MODE" in
  run)
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_BUNDLE/Contents/MacOS/MacOrchestrator"
    ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "MacOrchestrator"'
    ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE"
    /bin/sleep 2
    /usr/bin/pgrep -f "$APP_BUNDLE/Contents/MacOS/MacOrchestrator" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
