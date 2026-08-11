#!/usr/bin/env bash
set -euo pipefail
UNZIP_BIN="/usr/bin/unzip"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PLUTIL_BIN="${PLUTIL_BIN:-/usr/bin/plutil}"
SHASUM_BIN="${SHASUM_BIN:-/usr/bin/shasum}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
DITTO_BIN="${DITTO_BIN:-/usr/bin/ditto}"
TAR_BIN="${TAR_BIN:-/usr/bin/tar}"
FILE_BIN="${FILE_BIN:-/usr/bin/file}"
CODESIGN_BIN="${CODESIGN_BIN:-/usr/bin/codesign}"
UNAME_BIN="${MAC_ORCHESTRATOR_UNAME_BIN:-uname}"
SW_VERS_BIN="${MAC_ORCHESTRATOR_SW_VERS_BIN:-sw_vers}"

MANIFEST_SOURCE="${MAC_ORCHESTRATOR_MANIFEST_PATH:-}"
SUPPORT_DIR="${MAC_ORCHESTRATOR_SUPPORT_DIR:-$HOME/Library/Application Support/Mac Orchestrator}"
INSTALL_DIR="$SUPPORT_DIR/install"
RUNTIME_DIR="$SUPPORT_DIR/runtime"
APP_DIR="$SUPPORT_DIR/app"
REMOTE_DIR="$SUPPORT_DIR/remote/ngrok"
BACKUP_DIR="$INSTALL_DIR/runtime.previous"
APP_BACKUP_DIR="$INSTALL_DIR/app.previous"
REMOTE_BACKUP_DIR="$INSTALL_DIR/remote.previous"
PROMOTION_MARKER="$INSTALL_DIR/promotion.marker"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_LABEL="com.jay.mac-orchestrator"
LAUNCH_AGENT_PATH="$LAUNCH_AGENTS_DIR/$LAUNCH_AGENT_LABEL.plist"
FIXTURE_MODE="${MAC_ORCHESTRATOR_FIXTURE_MODE:-0}"
FIXTURE_LOCK_PATH="${MAC_ORCHESTRATOR_FIXTURE_LOCK_PATH:-}"
TEST_FAIL_AFTER_PROMOTION="${MAC_ORCHESTRATOR_TEST_FAIL_AFTER_PROMOTION:-0}"
TEST_EXIT_AFTER_RECOVERY="${MAC_ORCHESTRATOR_TEST_EXIT_AFTER_RECOVERY:-0}"
VERBOSE="0"
PROFILE="guided"
REMOTE_REQUESTED="0"

MANIFEST_FILE=""
STAGING_DIR=""
PROMOTION_ACTIVE="0"
PRODUCT_VERSION=""
BOOTSTRAP_DIGEST=""
HELPER_DIGEST=""
UV_DIGEST=""
CORE_PAYLOAD_DIGEST=""
LOCK_DIGEST=""
NGROK_DIGEST=""

die() {
  echo "error: $*" >&2
  exit 1
}

stage() {
  echo "$1"
}

run_uv() {
  if [ "$VERBOSE" = "1" ]; then
    "$@"
  else
    "$@" >/dev/null
  fi
}

cleanup_path() {
  path="$1"
  case "$path" in
    ""|"/"|"$SUPPORT_DIR"|"$HOME"|"$INSTALL_DIR")
      return 1
      ;;
  esac
  if [ -e "$path" ]; then
    /bin/rm -rf "$path"
  fi
}

finish() {
  rc=$?
  set +e
  if [ "$rc" -ne 0 ] && [ "$PROMOTION_ACTIVE" -eq 1 ]; then
    recover_pending_promotion >/dev/null 2>&1 || true
  fi
  if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
    cleanup_path "$STAGING_DIR" || true
  fi
  if [ -n "$MANIFEST_FILE" ] && [ "$MANIFEST_FILE" != "$MANIFEST_SOURCE" ] && [ -f "$MANIFEST_FILE" ]; then
    /bin/rm -f "$MANIFEST_FILE"
  fi
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' HUP INT TERM

usage() {
  echo "Usage: bootstrap.sh [--manifest PATH|URL] [--full-control] [--remote] [--verbose]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      MANIFEST_SOURCE="$2"
      shift 2
      ;;
    --full-control)
      PROFILE="full"
      shift
      ;;
    --remote)
      REMOTE_REQUESTED="1"
      shift
      ;;
    --verbose)
      VERBOSE="1"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [ -z "$MANIFEST_SOURCE" ]; then
  if [ -f "$PROJECT_DIR/release/manifest.json" ]; then
    MANIFEST_SOURCE="$PROJECT_DIR/release/manifest.json"
  else
    die "a concrete release manifest is required; set MAC_ORCHESTRATOR_MANIFEST_PATH or pass --manifest"
  fi
fi

read_manifest_value() {
  keypath="$1"
  if ! VALUE="$($PLUTIL_BIN -extract "$keypath" raw -o - "$MANIFEST_FILE" 2>/dev/null)"; then
    die "manifest field is missing: $keypath"
  fi
  if [ -z "$VALUE" ]; then
    die "manifest field is empty: $keypath"
  fi
}

require_sha256() {
  label="$1"
  value="$2"
  if [ "${#value}" -ne 64 ]; then
    die "$label digest must be a 64-character SHA-256 value"
  fi
  case "$value" in
    *[!0123456789abcdefABCDEF]*)
      die "$label digest must be hexadecimal"
      ;;
  esac
  case "$value" in
    *REPLACE*|*SENTINEL*|*example.invalid*)
      die "$label digest is still a template value"
      ;;
  esac
}

require_url() {
  label="$1"
  value="$2"
  case "$value" in
    file://*|https://*) ;;
    *) die "$label URL must use file:// or https://" ;;
  esac
  case "$value" in
    *REPLACE*|*example.invalid*|*refs/heads/main*|*/main/*|*@main*)
      die "$label URL must point to an immutable release asset"
      ;;
  esac
}

require_ngrok_url() {
  value="$1"
  if [ "$FIXTURE_MODE" = "1" ] && [[ "$value" == file://* ]]; then
    return 0
  fi
  case "$value" in
    https://bin.equinox.io/*) ;;
    *) die "ngrok URL must point directly to bin.equinox.io" ;;
  esac
}

version_at_least() {
  current="$1"
  required="$2"
  old_ifs="$IFS"
  IFS=.
  set -- $current
  current_major="${1:-0}"
  current_minor="${2:-0}"
  current_patch="${3:-0}"
  set -- $required
  required_major="${1:-0}"
  required_minor="${2:-0}"
  required_patch="${3:-0}"
  IFS="$old_ifs"

  if [ "$current_major" -gt "$required_major" ]; then return 0; fi
  if [ "$current_major" -lt "$required_major" ]; then return 1; fi
  if [ "$current_minor" -gt "$required_minor" ]; then return 0; fi
  if [ "$current_minor" -lt "$required_minor" ]; then return 1; fi
  [ "$current_patch" -ge "$required_patch" ]
}

require_schema_range() {
  label="$1"
  minimum="$2"
  maximum="$3"
  case "$minimum:$maximum" in
    *[!0123456789:]*|:*) die "$label schema range must contain positive integers" ;;
  esac
  [ "$minimum" -le "$maximum" ] || die "$label schema range is inverted"
}

sha256_file() {
  digest_output="$($SHASUM_BIN -a 256 "$1")" || return 1
  echo "${digest_output%% *}"
}

verify_digest() {
  label="$1"
  path="$2"
  expected="$3"
  [ -f "$path" ] || die "$label asset is missing"
  actual="$(sha256_file "$path")" || die "could not hash $label asset"
  expected_lower="$(echo "$expected" | tr '[:upper:]' '[:lower:]')"
  if [ "$actual" != "$expected_lower" ]; then
    die "$label digest mismatch"
  fi
}

runtime_smoke() {
  python_binary="$1"
  runtime_root="$2"
  smoke_port="$((49152 + ($$ % 1000)))"
  smoke_log="$runtime_root/.bootstrap-smoke.log"
  smoke_snapshot="$("$python_binary" -c 'import json; ids=("core.session","mac.ui","mac.screenOcr","mac.files.read","mac.files.write","mac.shell","mac.clipboard.write","telegram.send","meridian.search","meridian.telegram","remote.connector"); state={"desired":False,"configured":False,"ready":False,"health":"disabled","dependencies":[],"reason":"disabled in bootstrap smoke"}; state["desired"]=True; state["configured"]=True; state["ready"]=True; state["health"]="ready"; state["reason"]=None; capabilities={item:dict(state) for item in ids}; capabilities.update({item:{"desired":False,"configured":False,"ready":False,"health":"disabled","dependencies":[],"reason":"disabled in bootstrap smoke"} for item in ids[1:]}); print(json.dumps({"snapshotSchemaVersion":1,"configGeneration":0,"controlProfile":"guided","capabilities":capabilities,"policy":{"approvedFileRoots":[],"clipboardMutation":False}},separators=(",",":")))' )" ||
    die "could not create the managed runtime smoke snapshot"
  MAC_ORCHESTRATOR_MANAGED=1 \
    MAC_ORCHESTRATOR_PORT="$smoke_port" \
    MAC_ORCHESTRATOR_CONNECTOR_TOKEN="bootstrap-smoke-token-00000000000000000000000000000000" \
    MAC_ORCHESTRATOR_CAPABILITY_SNAPSHOT="$smoke_snapshot" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    "$python_binary" "$runtime_root/automac_mcp.py" --managed-owner bootstrap-smoke \
    >"$smoke_log" 2>&1 &
  smoke_pid=$!
  smoke_ok="0"
  attempt="0"
  while [ "$attempt" -lt 30 ]; do
    if ! kill -0 "$smoke_pid" 2>/dev/null; then
      break
    fi
    smoke_body="$("$CURL_BIN" -fsS --max-time 1 "http://127.0.0.1:$smoke_port/__mac_orchestrator_health" 2>/dev/null || true)"
    if [ "$smoke_body" = '{"status":"ok"}' ]; then
      smoke_ok="1"
      break
    fi
    attempt=$((attempt + 1))
    /bin/sleep 1
  done
  kill "$smoke_pid" 2>/dev/null || true
  wait "$smoke_pid" 2>/dev/null || true
  /bin/rm -f "$smoke_log"
  [ "$smoke_ok" = "1" ] || die "managed runtime health smoke test failed"
}

fetch_source() {
  source="$1"
  destination="$2"
  case "$source" in
    file://*)
      source_path="${source#file://}"
      [ -f "$source_path" ] || return 1
      /bin/cp "$source_path" "$destination"
      ;;
    https://*)
      "$CURL_BIN" -fL --retry 2 --output "$destination" "$source"
      ;;
    *)
      [ -f "$source" ] || return 1
      /bin/cp "$source" "$destination"
      ;;
  esac
}

download_and_verify() {
  label="$1"
  source="$2"
  expected="$3"
  destination="$4"
  if ! fetch_source "$source" "$destination"; then
    die "$label download failed"
  fi
  verify_digest "$label" "$destination" "$expected"
}

safe_archive_entries() {
  archive="$1"
  while IFS= read -r entry; do
    case "$entry" in
      ""|/*|../*|*/../*|..)
        die "archive contains an unsafe path"
        ;;
    esac
  done <<EOF
$($TAR_BIN -tzf "$archive")
EOF
}

safe_zip_entries() {
  archive="$1"
  while IFS= read -r entry; do
    case "$entry" in
      ""|/*|../*|*/../*|..)
        die "ngrok archive contains an unsafe path"
        ;;
    esac
  done <<EOF
$($UNZIP_BIN -Z1 "$archive")
EOF
}

read_manifest() {
  if ! "$PLUTIL_BIN" -convert xml1 -o /dev/null "$MANIFEST_FILE" >/dev/null 2>&1; then
    die "manifest is not valid property-list/JSON"
  fi

  read_manifest_value schemaVersion
  [ "$VALUE" = "1" ] || die "unsupported manifest schema version"
  read_manifest_value product.name
  [ "$VALUE" = "Mac Orchestrator" ] || die "manifest product name mismatch"
  read_manifest_value product.version
  PRODUCT_VERSION="$VALUE"
  read_manifest_value bootstrap.version
  read_manifest_value bootstrap.url
  BOOTSTRAP_URL="$VALUE"
  read_manifest_value bootstrap.sha256
  BOOTSTRAP_DIGEST="$VALUE"
  read_manifest_value platform.architecture
  [ "$VALUE" = "arm64" ] || die "manifest only supports arm64"
  read_manifest_value platform.minimumMacOS
  MINIMUM_MACOS="$VALUE"

  read_manifest_value helper.url
  HELPER_URL="$VALUE"
  read_manifest_value helper.sha256
  HELPER_DIGEST="$VALUE"
  read_manifest_value helper.architecture
  [ "$VALUE" = "arm64" ] || die "helper payload must be arm64"
  read_manifest_value helper.bundleIdentifier
  HELPER_BUNDLE_ID="$VALUE"
  read_manifest_value helper.version
  HELPER_VERSION="$VALUE"
  read_manifest_value helper.signing.mode
  [ "$VALUE" = "adhoc" ] || die "helper must declare ad-hoc signing"

  read_manifest_value runtime.schemaVersion
  RUNTIME_SCHEMA_VERSION="$VALUE"
  read_manifest_value runtime.uv.version
  UV_VERSION="$VALUE"
  read_manifest_value runtime.uv.url
  UV_URL="$VALUE"
  read_manifest_value runtime.uv.sha256
  UV_DIGEST="$VALUE"
  read_manifest_value runtime.python.managedVersion
  PYTHON_VERSION="$VALUE"
  read_manifest_value runtime.lockSha256
  LOCK_DIGEST="$VALUE"
  read_manifest_value runtime.corePayload.url
  CORE_PAYLOAD_URL="$VALUE"
  read_manifest_value runtime.corePayload.sha256
  CORE_PAYLOAD_DIGEST="$VALUE"
  read_manifest_value runtime.corePayload.format
  [ "$VALUE" = "tar.gz" ] || die "core payload must be tar.gz"

  read_manifest_value ngrok.version
  NGROK_VERSION="$VALUE"
  read_manifest_value ngrok.archiveUrl
  NGROK_URL="$VALUE"
  read_manifest_value ngrok.archiveSha256
  NGROK_DIGEST="$VALUE"
  read_manifest_value ngrok.archiveFormat
  [ "$VALUE" = "zip" ] || die "ngrok archive must be a zip"
  read_manifest_value ngrok.executableName
  NGROK_EXECUTABLE="$VALUE"
  read_manifest_value ngrok.developerIdAuthority
  NGROK_AUTHORITY="$VALUE"
  read_manifest_value ngrok.developerIdTeam
  NGROK_TEAM="$VALUE"
  read_manifest_value ngrok.agentApiVersion
  [ "$VALUE" = "v3" ] || die "ngrok Agent API must be v3"

  read_manifest_value compatibility.runtimeSchema.minimum
  RUNTIME_SCHEMA_MIN="$VALUE"
  read_manifest_value compatibility.runtimeSchema.maximum
  RUNTIME_SCHEMA_MAX="$VALUE"
  read_manifest_value compatibility.configurationSchema.minimum
  CONFIG_SCHEMA_MIN="$VALUE"
  read_manifest_value compatibility.configurationSchema.maximum
  CONFIG_SCHEMA_MAX="$VALUE"
}

validate_manifest() {
  stage "manifest-validated"
  require_sha256 "bootstrap" "$BOOTSTRAP_DIGEST"
  require_sha256 "helper" "$HELPER_DIGEST"
  require_sha256 "uv" "$UV_DIGEST"
  require_sha256 "core payload" "$CORE_PAYLOAD_DIGEST"
  require_sha256 "runtime lock" "$LOCK_DIGEST"
  require_sha256 "ngrok" "$NGROK_DIGEST"
  require_url "bootstrap" "$BOOTSTRAP_URL"
  require_url "helper" "$HELPER_URL"
  require_url "uv" "$UV_URL"
  require_url "core payload" "$CORE_PAYLOAD_URL"
  require_url "ngrok" "$NGROK_URL"
  require_ngrok_url "$NGROK_URL"
  require_schema_range "runtime" "$RUNTIME_SCHEMA_MIN" "$RUNTIME_SCHEMA_MAX"
  require_schema_range "configuration" "$CONFIG_SCHEMA_MIN" "$CONFIG_SCHEMA_MAX"
  [ "$RUNTIME_SCHEMA_VERSION" -ge "$RUNTIME_SCHEMA_MIN" ] || die "runtime schema is older than the compatible range"
  [ "$RUNTIME_SCHEMA_VERSION" -le "$RUNTIME_SCHEMA_MAX" ] || die "runtime schema is newer than the compatible range"
  case "$PYTHON_VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) die "managed Python version is invalid" ;;
  esac
  [ "$RUNTIME_SCHEMA_MIN" -ge 1 ] || die "runtime schema minimum must be positive"
  [ "$CONFIG_SCHEMA_MIN" -ge 1 ] || die "configuration schema minimum must be positive"
  [ "${#NGROK_TEAM}" -eq 10 ] || die "ngrok Developer ID team must be ten characters"
  case "$NGROK_TEAM" in
    *[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ]*) die "ngrok Developer ID team must be uppercase alphanumeric" ;;
  esac
  verify_digest "bootstrap" "$SCRIPT_PATH" "$BOOTSTRAP_DIGEST"
}

validate_platform() {
  host_arch="$($UNAME_BIN -m 2>/dev/null)" || die "could not determine machine architecture"
  [ "$host_arch" = "arm64" ] || die "this release requires arm64"
  macos_version="$($SW_VERS_BIN -productVersion 2>/dev/null)" || die "could not determine macOS version"
  version_at_least "$macos_version" "$MINIMUM_MACOS" || die "macOS $MINIMUM_MACOS or newer is required"
  stage "platform-validated"
}

recover_pending_promotion() {
  [ -f "$PROMOTION_MARKER" ] || return 0
  stage "promotion-recovery"

  marker_phase="$(/usr/bin/awk -F= '$1 == "phase" { print $2; exit }' "$PROMOTION_MARKER" 2>/dev/null || true)"
  if [ -z "$marker_phase" ]; then
    # Recover the pre-Phase 2 runtime-only marker emitted by an earlier build.
    marker_value="$(/bin/cat "$PROMOTION_MARKER" 2>/dev/null || true)"
    case "$marker_value" in
      had_previous=1*)
        [ -e "$BACKUP_DIR" ] || return 1
        cleanup_path "$RUNTIME_DIR" || return 1
        /bin/mv "$BACKUP_DIR" "$RUNTIME_DIR" || return 1
        ;;
      had_previous=0*)
        cleanup_path "$RUNTIME_DIR" || return 1
        ;;
      *)
        return 1
        ;;
    esac
  else
    case "$marker_phase" in
      backups|promoting) ;;
      *) return 1 ;;
    esac

    restore_path() {
      final_path="$1"
      backup_path="$2"
      had_previous="$3"
      if [ -e "$backup_path" ]; then
        cleanup_path "$final_path" || return 1
        /bin/mkdir -p "$(dirname "$final_path")"
        /bin/mv "$backup_path" "$final_path" || return 1
      elif [ "$marker_phase" = "promoting" ] && [ "$had_previous" = "0" ]; then
        cleanup_path "$final_path" || return 1
      fi
    }

    had_runtime="$(/usr/bin/awk -F= '$1 == "had_runtime" { print $2; exit }' "$PROMOTION_MARKER" 2>/dev/null || true)"
    had_app="$(/usr/bin/awk -F= '$1 == "had_app" { print $2; exit }' "$PROMOTION_MARKER" 2>/dev/null || true)"
    had_remote="$(/usr/bin/awk -F= '$1 == "had_remote" { print $2; exit }' "$PROMOTION_MARKER" 2>/dev/null || true)"
    [ "$had_runtime" = "0" ] || [ "$had_runtime" = "1" ] || return 1
    [ "$had_app" = "0" ] || [ "$had_app" = "1" ] || return 1
    [ "$had_remote" = "0" ] || [ "$had_remote" = "1" ] || return 1
    restore_path "$RUNTIME_DIR" "$BACKUP_DIR" "$had_runtime" || return 1
    restore_path "$APP_DIR" "$APP_BACKUP_DIR" "$had_app" || return 1
    restore_path "$REMOTE_DIR" "$REMOTE_BACKUP_DIR" "$had_remote" || return 1
  fi
  /bin/rm -f "$PROMOTION_MARKER"
  PROMOTION_ACTIVE="0"
  stage "promotion-recovered"
}

prepare_directories() {
  /bin/mkdir -p "$SUPPORT_DIR" "$INSTALL_DIR"
  /bin/chmod 700 "$SUPPORT_DIR" "$INSTALL_DIR"
  recover_pending_promotion || die "could not recover an interrupted promotion"
  if [ "$TEST_EXIT_AFTER_RECOVERY" = "1" ]; then
    exit 0
  fi
  STAGING_DIR="$(mktemp -d "$INSTALL_DIR/staging-XXXXXX")" || die "could not create staging directory"
  /bin/chmod 700 "$STAGING_DIR"
}

prepare_fixture_stage() {
  /bin/mkdir -p "$STAGING_DIR/app" "$STAGING_DIR/runtime" "$STAGING_DIR/remote/ngrok"
  /bin/cp "$STAGED_HELPER" "$STAGING_DIR/app/helper-artifact"
  /bin/cp "$STAGED_UV" "$STAGING_DIR/runtime/uv"
  /bin/cp "$STAGED_CORE" "$STAGING_DIR/runtime/core-payload.tar.gz"
  /bin/cp "$STAGED_NGROK" "$STAGING_DIR/remote/ngrok/archive.zip"
  if [ -n "$FIXTURE_LOCK_PATH" ]; then
    verify_digest "runtime lock" "$FIXTURE_LOCK_PATH" "$LOCK_DIGEST"
    /bin/cp "$FIXTURE_LOCK_PATH" "$STAGING_DIR/runtime/uv.lock"
  fi
  printf '%s\n' "$PRODUCT_VERSION" > "$STAGING_DIR/runtime/.release-marker"
  /bin/chmod 600 "$STAGING_DIR/runtime/.release-marker"
}

require_arm64_file() {
  label="$1"
  path="$2"
  file_description="$($FILE_BIN "$path" 2>/dev/null || true)"
  case "$file_description" in
    *arm64*) ;;
    *) die "$label is not arm64" ;;
  esac
}

validate_helper_bundle() {
  helper_app="$1"
  helper_binary="$helper_app/Contents/MacOS/MacOrchestrator"
  [ -d "$helper_app" ] || die "helper app is missing from the archive"
  [ -f "$helper_binary" ] || die "helper executable is missing"
  require_arm64_file "helper" "$helper_binary"
  "$CODESIGN_BIN" --verify --deep --strict "$helper_app" >/dev/null 2>&1 || die "helper signature verification failed"
  signature_details="$($CODESIGN_BIN -dv --verbose=4 "$helper_app" 2>&1 || true)"
  case "$signature_details" in
    *Signature=adhoc*) ;;
    *) die "helper is not ad-hoc signed" ;;
  esac
  info_plist="$helper_app/Contents/Info.plist"
  [ -f "$info_plist" ] || die "helper Info.plist is missing"
  bundle_id="$($PLUTIL_BIN -extract CFBundleIdentifier raw -o - "$info_plist")" || die "helper bundle identifier is unreadable"
  [ "$bundle_id" = "$HELPER_BUNDLE_ID" ] || die "helper bundle identifier mismatch"
  helper_version="$($PLUTIL_BIN -extract CFBundleShortVersionString raw -o - "$info_plist")" || die "helper version is unreadable"
  [ "$helper_version" = "$HELPER_VERSION" ] || die "helper version mismatch"
  bundled_ngrok="$(find "$helper_app" -name ngrok -print -quit 2>/dev/null || true)"
  [ -z "$bundled_ngrok" ] || die "helper must not bundle ngrok"
}

validate_ngrok_binary() {
  ngrok_binary="$1"
  require_arm64_file "ngrok" "$ngrok_binary"
  "$CODESIGN_BIN" --verify --deep --strict "$ngrok_binary" >/dev/null 2>&1 || die "ngrok signature verification failed"
  ngrok_signature="$($CODESIGN_BIN -dv --verbose=4 "$ngrok_binary" 2>&1 || true)"
  case "$ngrok_signature" in
    *"Authority=$NGROK_AUTHORITY"*) ;;
    *) die "ngrok Developer ID authority mismatch" ;;
  esac
  case "$ngrok_signature" in
    *"TeamIdentifier=$NGROK_TEAM"*) ;;
    *) die "ngrok Developer ID team mismatch" ;;
  esac
}

prepare_release_stage() {
  /bin/mkdir -p "$STAGING_DIR/app" "$STAGING_DIR/runtime/bin" "$STAGING_DIR/remote/ngrok"
  helper_archive="$STAGING_DIR/helper.zip"
  uv_binary="$STAGING_DIR/uv"
  core_archive="$STAGING_DIR/core-payload.tar.gz"
  ngrok_archive="$STAGING_DIR/ngrok.zip"

  download_and_verify "helper" "$HELPER_URL" "$HELPER_DIGEST" "$helper_archive"
  download_and_verify "uv" "$UV_URL" "$UV_DIGEST" "$uv_binary"
  download_and_verify "core payload" "$CORE_PAYLOAD_URL" "$CORE_PAYLOAD_DIGEST" "$core_archive"
  download_and_verify "ngrok" "$NGROK_URL" "$NGROK_DIGEST" "$ngrok_archive"
  stage "digests-verified"

  safe_archive_entries "$core_archive"
  "$DITTO_BIN" -x -k "$helper_archive" "$STAGING_DIR/app" || die "helper archive extraction failed"
  helper_app="$STAGING_DIR/app/Mac Orchestrator.app"
  validate_helper_bundle "$helper_app"

  /bin/chmod 755 "$uv_binary"
  require_arm64_file "uv" "$uv_binary"
  uv_version_output="$($uv_binary --version 2>/dev/null || true)"
  case "$uv_version_output" in
    *"$UV_VERSION"*) ;;
    *) die "uv version mismatch" ;;
  esac
  /bin/mv "$uv_binary" "$STAGING_DIR/runtime/bin/uv"

  "$TAR_BIN" -xzf "$core_archive" -C "$STAGING_DIR/runtime" || die "core payload extraction failed"
  [ -f "$STAGING_DIR/runtime/automac_mcp.py" ] || die "core payload is missing automac_mcp.py"
  [ -f "$STAGING_DIR/runtime/pyproject.toml" ] || die "core payload is missing pyproject.toml"
  [ -f "$STAGING_DIR/runtime/uv.lock" ] || die "core payload is missing uv.lock"
  [ ! -e "$STAGING_DIR/runtime/indexer.py" ] || die "core payload must not contain indexer.py"
  verify_digest "runtime lock" "$STAGING_DIR/runtime/uv.lock" "$LOCK_DIGEST"

  UV_PYTHON_INSTALL_DIR="$SUPPORT_DIR/python"
  export UV_PYTHON_INSTALL_DIR
  run_uv "$STAGING_DIR/runtime/bin/uv" python install "$PYTHON_VERSION" || die "managed Python installation failed"
  run_uv "$STAGING_DIR/runtime/bin/uv" venv --managed-python "$STAGING_DIR/runtime/.venv" ||
    die "managed virtualenv creation failed"
  run_uv "$STAGING_DIR/runtime/bin/uv" sync --project "$STAGING_DIR/runtime" --frozen --no-editable --no-install-project ||
    die "frozen core sync failed"
  python_binary="$STAGING_DIR/runtime/.venv/bin/python"
  [ -x "$python_binary" ] || die "managed Python executable is missing"
  require_arm64_file "managed Python" "$python_binary"
  python_version_output="$($python_binary --version 2>&1 || true)"
  case "$python_version_output" in
    *"$PYTHON_VERSION"*) ;;
    *) die "managed Python version mismatch" ;;
  esac
  for venv_script in "$STAGING_DIR/runtime/.venv/bin"/*; do
    if [ -f "$venv_script" ] && [ ! -L "$venv_script" ] &&
       /usr/bin/grep -F -l "$STAGING_DIR/runtime/.venv" "$venv_script" >/dev/null 2>&1; then
      LC_ALL=C /usr/bin/sed -i '' "s|$STAGING_DIR/runtime/.venv|$RUNTIME_DIR/.venv|g" "$venv_script"
    fi
  done
  if /usr/bin/grep -R -F -n "$STAGING_DIR" "$STAGING_DIR/runtime" >/dev/null 2>&1; then
    die "staging path leaked into runtime metadata"
  fi
  (cd "$STAGING_DIR/runtime" && PYTHONDONTWRITEBYTECODE=1 "$python_binary" -c 'import automac_mcp') ||
    die "core import smoke test failed"
  runtime_smoke "$python_binary" "$STAGING_DIR/runtime"

  ngrok_extract_dir="$STAGING_DIR/remote/ngrok/extracted"
  /bin/mkdir -p "$ngrok_extract_dir"
  safe_zip_entries "$ngrok_archive"
  "$DITTO_BIN" -x -k "$ngrok_archive" "$ngrok_extract_dir" || die "ngrok archive extraction failed"
  ngrok_source="$(find "$ngrok_extract_dir" -type f -name "$NGROK_EXECUTABLE" -print | sed -n '1p')"
  [ -n "$ngrok_source" ] || die "ngrok executable is missing from the archive"
  validate_ngrok_binary "$ngrok_source"
  /bin/cp "$ngrok_source" "$STAGING_DIR/remote/ngrok/$NGROK_EXECUTABLE"
  printf '%s\n' 'version: "3"' 'agent: {}' 'endpoints: []' > "$STAGING_DIR/remote/ngrok/ngrok.yml"
  /bin/chmod 600 "$STAGING_DIR/remote/ngrok/ngrok.yml"
  printf '%s\n' "$PRODUCT_VERSION" > "$STAGING_DIR/runtime/.release-marker"
  /bin/chmod 600 "$STAGING_DIR/runtime/.release-marker"
}

prepare_stage() {
  if [ "$FIXTURE_MODE" = "1" ]; then
    STAGED_HELPER="$STAGING_DIR/input-helper"
    STAGED_UV="$STAGING_DIR/input-uv"
    STAGED_CORE="$STAGING_DIR/input-core"
    STAGED_NGROK="$STAGING_DIR/input-ngrok"
    download_and_verify "helper" "$HELPER_URL" "$HELPER_DIGEST" "$STAGED_HELPER"
    download_and_verify "uv" "$UV_URL" "$UV_DIGEST" "$STAGED_UV"
    download_and_verify "core payload" "$CORE_PAYLOAD_URL" "$CORE_PAYLOAD_DIGEST" "$STAGED_CORE"
    download_and_verify "ngrok" "$NGROK_URL" "$NGROK_DIGEST" "$STAGED_NGROK"
    if [ -n "$FIXTURE_LOCK_PATH" ]; then
      verify_digest "runtime lock" "$FIXTURE_LOCK_PATH" "$LOCK_DIGEST"
    fi
    stage "digests-verified"
    prepare_fixture_stage
  else
    prepare_release_stage
  fi
  stage "staged"
}

promote() {
  had_runtime="0"
  had_app="0"
  had_remote="0"
  if [ -e "$RUNTIME_DIR" ]; then
    cleanup_path "$BACKUP_DIR" || die "could not clear the previous runtime backup"
    had_runtime="1"
  fi
  if [ -e "$APP_DIR" ]; then
    cleanup_path "$APP_BACKUP_DIR" || die "could not clear the previous helper backup"
    had_app="1"
  fi
  if [ -e "$REMOTE_DIR" ]; then
    cleanup_path "$REMOTE_BACKUP_DIR" || die "could not clear the previous remote backup"
    had_remote="1"
  fi
  printf 'phase=backups\nhad_runtime=%s\nhad_app=%s\nhad_remote=%s\n' \
    "$had_runtime" "$had_app" "$had_remote" > "$PROMOTION_MARKER"
  /bin/chmod 600 "$PROMOTION_MARKER"
  PROMOTION_ACTIVE="1"

  if [ "$had_runtime" = "1" ]; then
    /bin/mv "$RUNTIME_DIR" "$BACKUP_DIR" || die "could not preserve the previous runtime"
  fi
  if [ "$had_app" = "1" ]; then
    /bin/mv "$APP_DIR" "$APP_BACKUP_DIR" || die "could not preserve the previous helper app"
  fi
  if [ "$had_remote" = "1" ]; then
    /bin/mv "$REMOTE_DIR" "$REMOTE_BACKUP_DIR" || die "could not preserve the previous remote payload"
  fi
  printf 'phase=promoting\nhad_runtime=%s\nhad_app=%s\nhad_remote=%s\n' \
    "$had_runtime" "$had_app" "$had_remote" > "$PROMOTION_MARKER"
  /bin/mv "$STAGING_DIR/runtime" "$RUNTIME_DIR" || die "could not promote the staged runtime"

  if [ "$TEST_FAIL_AFTER_PROMOTION" = "1" ]; then
    die "simulated interruption after promotion"
  fi

  cleanup_path "$APP_DIR" || die "could not replace the helper app"
  /bin/mv "$STAGING_DIR/app" "$APP_DIR" || die "could not install the helper app"
  cleanup_path "$REMOTE_DIR" || die "could not replace the remote payload"
  /bin/mkdir -p "$(dirname "$REMOTE_DIR")"
  /bin/mv "$STAGING_DIR/remote/ngrok" "$REMOTE_DIR" || die "could not install the remote payload"
  /bin/chmod 700 "$RUNTIME_DIR" "$APP_DIR" "$REMOTE_DIR"
  if [ -f "$REMOTE_DIR/ngrok.yml" ]; then
    /bin/chmod 600 "$REMOTE_DIR/ngrok.yml"
  fi
  /bin/rm -f "$PROMOTION_MARKER"
  PROMOTION_ACTIVE="0"
  stage "promoted"
}

write_launch_agent() {
  [ "$FIXTURE_MODE" = "1" ] && return 0
  /bin/mkdir -p "$LAUNCH_AGENTS_DIR"
  /bin/chmod 700 "$LAUNCH_AGENTS_DIR"
  "$PLUTIL_BIN" -create xml1 "$LAUNCH_AGENT_PATH"
  "$PLUTIL_BIN" -insert Label -string "$LAUNCH_AGENT_LABEL" "$LAUNCH_AGENT_PATH"
  "$PLUTIL_BIN" -insert ProgramArguments -json "[\"$APP_DIR/Mac Orchestrator.app/Contents/MacOS/MacOrchestrator\"]" "$LAUNCH_AGENT_PATH"
  "$PLUTIL_BIN" -insert RunAtLoad -bool true "$LAUNCH_AGENT_PATH"
  "$PLUTIL_BIN" -insert KeepAlive -json '{"SuccessfulExit":false}' "$LAUNCH_AGENT_PATH"
  "$PLUTIL_BIN" -insert LimitLoadToSessionType -string Aqua "$LAUNCH_AGENT_PATH"
  /bin/chmod 600 "$LAUNCH_AGENT_PATH"
  /bin/launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
  /bin/launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PATH"
}

configure_installed_helper() {
  [ "$FIXTURE_MODE" = "1" ] && return 0
  helper_executable="$APP_DIR/Mac Orchestrator.app/Contents/MacOS/MacOrchestrator"
  [ -x "$helper_executable" ] || die "installed helper executable is missing"
  if [ "$PROFILE" = "full" ]; then
    "$helper_executable" --set-profile full --confirm-full-control ||
      die "could not persist the explicitly selected Full Control profile"
  fi
  if [ "$REMOTE_REQUESTED" = "1" ]; then
    stage "remote-authentication-required"
    "$helper_executable" --store-ngrok-token ||
      die "remote setup requires an ngrok authtoken entered through hidden input"
    "$helper_executable" --enable-remote ||
      die "could not enable the opted-in remote connector"
  fi
}

load_manifest_file() {
  case "$MANIFEST_SOURCE" in
    file://*)
      MANIFEST_FILE="${MANIFEST_SOURCE#file://}"
      ;;
    https://*)
      /bin/mkdir -p "$INSTALL_DIR"
      MANIFEST_FILE="$(mktemp "$INSTALL_DIR/manifest-XXXXXX.json")"
      if ! fetch_source "$MANIFEST_SOURCE" "$MANIFEST_FILE"; then
        die "manifest download failed"
      fi
      ;;
    *)
      MANIFEST_FILE="$MANIFEST_SOURCE"
      ;;
  esac
  [ -f "$MANIFEST_FILE" ] || die "manifest file is missing"
}

main() {
  load_manifest_file
  read_manifest
  validate_manifest
  validate_platform
  prepare_directories
  prepare_stage
  promote
  configure_installed_helper
  write_launch_agent
  if [ "$PROFILE" = "full" ]; then
    stage "profile-full-selected"
  else
    stage "profile-guided-default"
  fi
  if [ "$REMOTE_REQUESTED" = "1" ]; then
    stage "remote-opt-in-requested"
  else
    stage "remote-optional"
  fi
  stage "complete"
}

main "$@"
