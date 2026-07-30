#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Mac Orchestrator"
BUNDLE_ID="com.jay.mac-orchestrator"
LABEL="com.jay.mac-orchestrator"
BUILT_APP="$PROJECT_DIR/dist/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
SUPPORT_DIR="$HOME/Library/Application Support/Mac Orchestrator"
RUNTIME_DIR="$SUPPORT_DIR/runtime"
LOG_DIR="$HOME/Library/Logs/Mac Orchestrator"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$AGENTS_DIR/$LABEL.plist"
UV_BIN="${UV_BIN:-$(command -v uv || true)}"

if [[ -z "$UV_BIN" ]]; then
  echo "uv is required for this personal installation." >&2
  exit 1
fi

"$PROJECT_DIR/script/package_app.sh" >/dev/null

/usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8; do
  if ! /usr/bin/pgrep -f "$INSTALLED_APP/Contents/MacOS/MacOrchestrator" >/dev/null; then
    break
  fi
  /bin/sleep 1
done

/bin/launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true

/bin/mkdir -p "$RUNTIME_DIR" "$LOG_DIR" "$AGENTS_DIR"
/bin/chmod 700 "$SUPPORT_DIR" "$LOG_DIR"
LEGACY_CONFIG="$HOME/.config/mac-orchestrator/config.json"
NGROK_CONFIG="$HOME/Library/Application Support/ngrok/ngrok.yml"
[[ ! -f "$LEGACY_CONFIG" ]] || /bin/chmod 600 "$LEGACY_CONFIG"
[[ ! -f "$NGROK_CONFIG" ]] || /bin/chmod 600 "$NGROK_CONFIG"
/usr/bin/ditto "$PROJECT_DIR/automac_mcp.py" "$RUNTIME_DIR/automac_mcp.py"
/usr/bin/ditto "$PROJECT_DIR/indexer.py" "$RUNTIME_DIR/indexer.py"
/usr/bin/ditto "$PROJECT_DIR/pyproject.toml" "$RUNTIME_DIR/pyproject.toml"
/usr/bin/ditto "$PROJECT_DIR/uv.lock" "$RUNTIME_DIR/uv.lock"
"$UV_BIN" sync --project "$RUNTIME_DIR" --frozen

/usr/bin/ditto "$BUILT_APP" "$INSTALLED_APP"
/usr/bin/codesign --verify --strict "$INSTALLED_APP"

/usr/bin/plutil -create xml1 "$PLIST_PATH"
/usr/bin/plutil -insert Label -string "$LABEL" "$PLIST_PATH"
/usr/bin/plutil -insert ProgramArguments -json "[\"$INSTALLED_APP/Contents/MacOS/MacOrchestrator\"]" "$PLIST_PATH"
/usr/bin/plutil -insert RunAtLoad -bool true "$PLIST_PATH"
/usr/bin/plutil -insert KeepAlive -json '{"SuccessfulExit":false}' "$PLIST_PATH"
/usr/bin/plutil -insert ThrottleInterval -integer 5 "$PLIST_PATH"
/usr/bin/plutil -insert ProcessType -string Interactive "$PLIST_PATH"
/usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$PLIST_PATH"
/usr/bin/plutil -insert StandardOutPath -string "$LOG_DIR/launcher.log" "$PLIST_PATH"
/usr/bin/plutil -insert StandardErrorPath -string "$LOG_DIR/launcher.log" "$PLIST_PATH"
/bin/chmod 600 "$PLIST_PATH"

/bin/launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
/bin/launchctl enable "gui/$(id -u)/$LABEL"

echo "Installed and launched: $INSTALLED_APP"
echo "LaunchAgent: $PLIST_PATH"
