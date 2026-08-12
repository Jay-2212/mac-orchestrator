#!/usr/bin/env bash
set -euo pipefail
UNZIP_BIN="/usr/bin/unzip"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_PATH="$PROJECT_DIR/release/manifest.template.json"
PLUTIL_BIN="${PLUTIL_BIN:-/usr/bin/plutil}"
SHASUM_BIN="${SHASUM_BIN:-/usr/bin/shasum}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
DITTO_BIN="${DITTO_BIN:-/usr/bin/ditto}"
TAR_BIN="${TAR_BIN:-/usr/bin/tar}"
FILE_BIN="${FILE_BIN:-/usr/bin/file}"
CODESIGN_BIN="${CODESIGN_BIN:-/usr/bin/codesign}"

OUTPUT_DIR="${MAC_ORCHESTRATOR_RELEASE_OUTPUT:-$PROJECT_DIR/dist/release}"
PRODUCT_VERSION=""
BOOTSTRAP_VERSION=""
BOOTSTRAP_PATH="$PROJECT_DIR/script/bootstrap.sh"
BOOTSTRAP_URL=""
BOOTSTRAP_SHA256=""
HELPER_APP=""
HELPER_ARCHIVE=""
HELPER_URL=""
HELPER_SHA256=""
UV_PATH=""
UV_VERSION="0.12.3"
UV_URL=""
UV_SHA256=""
CORE_PAYLOAD_PATH=""
CORE_URL=""
CORE_SHA256=""
LOCK_PATH=""
LOCK_SHA256=""
NGROK_ARCHIVE_PATH=""
NGROK_VERSION=""
NGROK_URL=""
NGROK_SHA256=""
NGROK_AUTHORITY=""
NGROK_TEAM=""
MANIFEST_URL=""
WORK_DIR=""

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  echo "Usage: build_release_artifacts.sh --product-version VERSION --bootstrap-version VERSION --bootstrap-url URL --bootstrap-sha256 DIGEST --manifest-url URL --helper-url URL --helper-sha256 DIGEST --uv PATH --uv-url URL --uv-sha256 DIGEST --core-payload PATH --core-url URL --core-sha256 DIGEST --lock PATH --lock-sha256 DIGEST --ngrok-archive PATH --ngrok-version VERSION --ngrok-url URL --ngrok-sha256 DIGEST --ngrok-authority AUTHORITY --ngrok-team TEAM [--helper-app PATH|--helper-archive PATH] [--output-dir DIR]" >&2
}

finish() {
  rc=$?
  set +e
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    /bin/rm -rf "$WORK_DIR"
  fi
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' HUP INT TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --product-version) [ "$#" -ge 2 ] || { usage; exit 2; }; PRODUCT_VERSION="$2"; shift 2 ;;
    --bootstrap-version) [ "$#" -ge 2 ] || { usage; exit 2; }; BOOTSTRAP_VERSION="$2"; shift 2 ;;
    --bootstrap) [ "$#" -ge 2 ] || { usage; exit 2; }; BOOTSTRAP_PATH="$2"; shift 2 ;;
    --bootstrap-url) [ "$#" -ge 2 ] || { usage; exit 2; }; BOOTSTRAP_URL="$2"; shift 2 ;;
    --bootstrap-sha256) [ "$#" -ge 2 ] || { usage; exit 2; }; BOOTSTRAP_SHA256="$2"; shift 2 ;;
    --manifest-url) [ "$#" -ge 2 ] || { usage; exit 2; }; MANIFEST_URL="$2"; shift 2 ;;
    --helper-app) [ "$#" -ge 2 ] || { usage; exit 2; }; HELPER_APP="$2"; shift 2 ;;
    --helper-archive) [ "$#" -ge 2 ] || { usage; exit 2; }; HELPER_ARCHIVE="$2"; shift 2 ;;
    --helper-url) [ "$#" -ge 2 ] || { usage; exit 2; }; HELPER_URL="$2"; shift 2 ;;
    --helper-sha256) [ "$#" -ge 2 ] || { usage; exit 2; }; HELPER_SHA256="$2"; shift 2 ;;
    --uv) [ "$#" -ge 2 ] || { usage; exit 2; }; UV_PATH="$2"; shift 2 ;;
    --uv-version) [ "$#" -ge 2 ] || { usage; exit 2; }; UV_VERSION="$2"; shift 2 ;;
    --uv-url) [ "$#" -ge 2 ] || { usage; exit 2; }; UV_URL="$2"; shift 2 ;;
    --uv-sha256) [ "$#" -ge 2 ] || { usage; exit 2; }; UV_SHA256="$2"; shift 2 ;;
    --core-payload) [ "$#" -ge 2 ] || { usage; exit 2; }; CORE_PAYLOAD_PATH="$2"; shift 2 ;;
    --core-url) [ "$#" -ge 2 ] || { usage; exit 2; }; CORE_URL="$2"; shift 2 ;;
    --core-sha256) [ "$#" -ge 2 ] || { usage; exit 2; }; CORE_SHA256="$2"; shift 2 ;;
    --lock) [ "$#" -ge 2 ] || { usage; exit 2; }; LOCK_PATH="$2"; shift 2 ;;
    --lock-sha256) [ "$#" -ge 2 ] || { usage; exit 2; }; LOCK_SHA256="$2"; shift 2 ;;
    --ngrok-archive) [ "$#" -ge 2 ] || { usage; exit 2; }; NGROK_ARCHIVE_PATH="$2"; shift 2 ;;
    --ngrok-version) [ "$#" -ge 2 ] || { usage; exit 2; }; NGROK_VERSION="$2"; shift 2 ;;
    --ngrok-url) [ "$#" -ge 2 ] || { usage; exit 2; }; NGROK_URL="$2"; shift 2 ;;
    --ngrok-sha256) [ "$#" -ge 2 ] || { usage; exit 2; }; NGROK_SHA256="$2"; shift 2 ;;
    --ngrok-authority) [ "$#" -ge 2 ] || { usage; exit 2; }; NGROK_AUTHORITY="$2"; shift 2 ;;
    --ngrok-team) [ "$#" -ge 2 ] || { usage; exit 2; }; NGROK_TEAM="$2"; shift 2 ;;
    --output-dir) [ "$#" -ge 2 ] || { usage; exit 2; }; OUTPUT_DIR="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

require_input() {
  flag="$1"
  value="$2"
  [ -n "$value" ] || die "required release input missing: $flag"
}

require_file() {
  flag="$1"
  path="$2"
  [ -f "$path" ] || die "required release input is not a file: $flag"
}

require_sha256() {
  label="$1"
  value="$2"
  require_input "$label" "$value"
  [ "${#value}" -eq 64 ] || die "$label must be a 64-character SHA-256 digest"
  case "$value" in
    *[!0123456789abcdefABCDEF]*) die "$label must be hexadecimal" ;;
  esac
  [[ ! "$value" =~ ^0{64}$ ]] || die "$label must not be all zeroes"
}

require_https_url() {
  label="$1"
  value="$2"
  require_input "$label" "$value"
  case "$value" in
    https://*) ;;
    *) die "$label must be an https release URL" ;;
  esac
  case "$value" in
    *REPLACE*|*example.invalid*|*refs/heads/main*|*/main/*|*@main*)
      die "$label must not use a mutable or placeholder URL"
      ;;
  esac
}

require_release_asset_url() {
  label="$1"
  value="$2"
  filename="$3"
  expected="https://github.com/Jay-2212/mac-orchestrator/releases/download/v${PRODUCT_VERSION}/${filename}"
  [ "$value" = "$expected" ] || die "$label must be the immutable release asset URL for v${PRODUCT_VERSION}"
}

require_ngrok_vendor_url() {
  value="$1"
  case "$value" in
    https://bin.equinox.io/*) ;;
    *) die "--ngrok-url must point directly to bin.equinox.io" ;;
  esac
}

sha256_file() {
  result="$($SHASUM_BIN -a 256 "$1")" || return 1
  echo "${result%% *}"
}

verify_digest() {
  label="$1"
  path="$2"
  expected="$3"
  actual="$(sha256_file "$path")" || die "could not hash $label"
  expected_lower="$(echo "$expected" | tr '[:upper:]' '[:lower:]')"
  [ "$actual" = "$expected_lower" ] || die "$label digest does not match supplied digest"
}

require_arm64() {
  label="$1"
  path="$2"
  description="$($FILE_BIN "$path" 2>/dev/null || true)"
  case "$description" in
    *arm64*) ;;
    *) die "$label is not arm64" ;;
  esac
}

validate_helper_app() {
  app_path="$1"
  [ -d "$app_path/Contents" ] || die "helper app bundle is incomplete"
  binary="$app_path/Contents/MacOS/MacOrchestrator"
  [ -f "$binary" ] || die "helper executable is missing"
  require_arm64 "helper" "$binary"
  "$CODESIGN_BIN" --verify --deep --strict "$app_path" >/dev/null 2>&1 || die "helper ad-hoc signature verification failed"
  details="$($CODESIGN_BIN -dv --verbose=4 "$app_path" 2>&1 || true)"
  case "$details" in
    *Signature=adhoc*) ;;
    *) die "helper is not ad-hoc signed" ;;
  esac
  [ ! -e "$app_path/Contents/Resources/ngrok" ] || die "helper must not contain ngrok"
  bundled_ngrok="$(find "$app_path" -name ngrok -print -quit 2>/dev/null || true)"
  [ -z "$bundled_ngrok" ] || die "helper must not contain ngrok"
  info_plist="$app_path/Contents/Info.plist"
  [ -f "$info_plist" ] || die "helper Info.plist is missing"
  helper_bundle_id="$($PLUTIL_BIN -extract CFBundleIdentifier raw -o - "$info_plist")" || die "helper bundle identifier is unreadable"
  [ "$helper_bundle_id" = "com.jay.mac-orchestrator" ] || die "helper bundle identifier mismatch"
  helper_version="$($PLUTIL_BIN -extract CFBundleShortVersionString raw -o - "$info_plist")" || die "helper version is unreadable"
  [ "$helper_version" = "$PRODUCT_VERSION" ] || die "helper version does not match product version"
}

validate_archive_paths() {
  archive="$1"
  archive_entries="$($TAR_BIN -tzf "$archive")" || die "could not inspect tar archive"
  while IFS= read -r entry; do
    case "$entry" in
      ""|/*|../*|*/../*|..) die "archive contains an unsafe path" ;;
    esac
  done <<<"$archive_entries"
  if printf '%s\n' "$archive_entries" | /usr/bin/grep -Eq '(^|/)\.\.?(/|$)'; then
    die "archive contains an unsafe path"
  fi
  archive_listing="$($TAR_BIN -tvzf "$archive")" || die "could not inspect tar archive"
  while IFS= read -r entry; do
    case "${entry:0:1}" in
      -|d) ;;
      *) die "archive contains a non-regular entry" ;;
    esac
  done <<<"$archive_listing"
}

validate_zip_paths() {
  archive="$1"
  "$PYTHON_BIN" - "$archive" <<'PY'
import posixpath
import stat
import sys
import zipfile

archive = sys.argv[1]
with zipfile.ZipFile(archive) as bundle:
    for info in bundle.infolist():
        name = info.filename
        if not name or "\\" in name or name.startswith("/"):
            raise SystemExit("archive contains an unsafe path")
        parts = name.split("/")
        if any(part in {".", ".."} for part in parts):
            raise SystemExit("archive contains an unsafe path")
        mode = (info.external_attr >> 16) & 0xFFFF
        if mode and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise SystemExit("archive contains a non-regular entry")
        if posixpath.normpath(name).startswith("../"):
            raise SystemExit("archive contains an unsafe path")
PY
}

prepare_helper() {
  helper_output="$OUTPUT_DIR/Mac-Orchestrator-arm64.zip"
  if [ -n "$HELPER_ARCHIVE" ]; then
    require_file "--helper-archive" "$HELPER_ARCHIVE"
    validate_zip_paths "$HELPER_ARCHIVE" || die "helper archive contains unsafe entries"
    /bin/cp "$HELPER_ARCHIVE" "$helper_output"
  else
    require_input "--helper-app or --helper-archive" "$HELPER_APP"
    validate_helper_app "$HELPER_APP"
    "$DITTO_BIN" -c -k --sequesterRsrc --keepParent "$HELPER_APP" "$helper_output"
  fi
  verify_digest "helper archive" "$helper_output" "$HELPER_SHA256"
  inspect_dir="$WORK_DIR/helper-inspect"
  /bin/mkdir -p "$inspect_dir"
  "$DITTO_BIN" -x -k "$helper_output" "$inspect_dir" || die "helper archive cannot be extracted"
  extracted_app="$inspect_dir/Mac Orchestrator.app"
  validate_helper_app "$extracted_app"
}

prepare_core_payload() {
  core_output="$OUTPUT_DIR/core-payload.tar.gz"
  if [ -d "$CORE_PAYLOAD_PATH" ]; then
    [ -f "$CORE_PAYLOAD_PATH/automac_mcp.py" ] || die "core payload directory is missing automac_mcp.py"
    [ -f "$CORE_PAYLOAD_PATH/pyproject.toml" ] || die "core payload directory is missing pyproject.toml"
    [ -f "$CORE_PAYLOAD_PATH/uv.lock" ] || die "core payload directory is missing uv.lock"
    [ ! -e "$CORE_PAYLOAD_PATH/indexer.py" ] || die "core payload must not contain indexer.py"
    "$TAR_BIN" -czf "$core_output" -C "$CORE_PAYLOAD_PATH" automac_mcp.py pyproject.toml uv.lock
  else
    require_file "--core-payload" "$CORE_PAYLOAD_PATH"
    /bin/cp "$CORE_PAYLOAD_PATH" "$core_output"
  fi
  verify_digest "core payload" "$core_output" "$CORE_SHA256"
  validate_archive_paths "$core_output"
  core_entries="$($TAR_BIN -tzf "$core_output")" || die "core payload cannot be listed"
  printf '%s\n' "$core_entries" | /usr/bin/grep -Fx 'automac_mcp.py' >/dev/null || die "core payload is missing automac_mcp.py"
  printf '%s\n' "$core_entries" | /usr/bin/grep -Fx 'pyproject.toml' >/dev/null || die "core payload is missing pyproject.toml"
  printf '%s\n' "$core_entries" | /usr/bin/grep -Fx 'uv.lock' >/dev/null || die "core payload is missing uv.lock"
  if printf '%s\n' "$core_entries" | /usr/bin/grep -Fx 'indexer.py' >/dev/null; then
    die "core payload must not contain indexer.py"
  fi
  core_entry_count="$(printf '%s\n' "$core_entries" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  [ "$core_entry_count" = "3" ] || die "core payload contains files outside the declared core boundary"
  core_lock="$WORK_DIR/core-uv.lock"
  "$TAR_BIN" -xOf "$core_output" uv.lock > "$core_lock" || die "core payload is missing uv.lock"
  verify_digest "core payload lock" "$core_lock" "$LOCK_SHA256"
}

validate_ngrok_archive() {
  ngrok_dir="$WORK_DIR/ngrok-inspect"
  /bin/mkdir -p "$ngrok_dir"
  validate_zip_paths "$NGROK_ARCHIVE_PATH"
  "$DITTO_BIN" -x -k "$NGROK_ARCHIVE_PATH" "$ngrok_dir" || die "ngrok archive cannot be extracted"
  ngrok_binary="$(find "$ngrok_dir" -type f -name ngrok -print | sed -n '1p')"
  [ -n "$ngrok_binary" ] || die "ngrok archive is missing ngrok"
  require_arm64 "ngrok" "$ngrok_binary"
  "$CODESIGN_BIN" --verify --deep --strict "$ngrok_binary" >/dev/null 2>&1 || die "ngrok signature verification failed"
  ngrok_details="$($CODESIGN_BIN -dv --verbose=4 "$ngrok_binary" 2>&1 || true)"
  case "$ngrok_details" in
    *"Authority=$NGROK_AUTHORITY"*) ;;
    *) die "ngrok Developer ID authority mismatch" ;;
  esac
  case "$ngrok_details" in
    *"TeamIdentifier=$NGROK_TEAM"*) ;;
    *) die "ngrok Developer ID team mismatch" ;;
  esac
}

prepare_binary_inputs() {
  require_file "--uv" "$UV_PATH"
  require_file "--ngrok-archive" "$NGROK_ARCHIVE_PATH"
  require_file "--lock" "$LOCK_PATH"
  require_arm64 "uv" "$UV_PATH"
  verify_digest "uv" "$UV_PATH" "$UV_SHA256"
  verify_digest "runtime lock" "$LOCK_PATH" "$LOCK_SHA256"
  verify_digest "ngrok archive" "$NGROK_ARCHIVE_PATH" "$NGROK_SHA256"
  validate_ngrok_archive
  /bin/cp "$UV_PATH" "$OUTPUT_DIR/uv-arm64"
}

write_manifest() {
  manifest_path="$OUTPUT_DIR/manifest.json"
  /bin/cp "$TEMPLATE_PATH" "$manifest_path"
  "$PLUTIL_BIN" -replace product.version -string "$PRODUCT_VERSION" "$manifest_path"
  "$PLUTIL_BIN" -replace bootstrap.version -string "$BOOTSTRAP_VERSION" "$manifest_path"
  "$PLUTIL_BIN" -replace bootstrap.url -string "$BOOTSTRAP_URL" "$manifest_path"
  "$PLUTIL_BIN" -replace bootstrap.sha256 -string "$BOOTSTRAP_SHA256" "$manifest_path"
  "$PLUTIL_BIN" -replace helper.url -string "$HELPER_URL" "$manifest_path"
  "$PLUTIL_BIN" -replace helper.sha256 -string "$HELPER_SHA256" "$manifest_path"
  "$PLUTIL_BIN" -replace helper.version -string "$PRODUCT_VERSION" "$manifest_path"
  "$PLUTIL_BIN" -replace runtime.uv.version -string "$UV_VERSION" "$manifest_path"
  "$PLUTIL_BIN" -replace runtime.uv.url -string "$UV_URL" "$manifest_path"
  "$PLUTIL_BIN" -replace runtime.uv.sha256 -string "$UV_SHA256" "$manifest_path"
  "$PLUTIL_BIN" -replace runtime.lockSha256 -string "$LOCK_SHA256" "$manifest_path"
  "$PLUTIL_BIN" -replace runtime.corePayload.url -string "$CORE_URL" "$manifest_path"
  "$PLUTIL_BIN" -replace runtime.corePayload.sha256 -string "$CORE_SHA256" "$manifest_path"
  "$PLUTIL_BIN" -replace ngrok.version -string "$NGROK_VERSION" "$manifest_path"
  "$PLUTIL_BIN" -replace ngrok.archiveUrl -string "$NGROK_URL" "$manifest_path"
  "$PLUTIL_BIN" -replace ngrok.archiveSha256 -string "$NGROK_SHA256" "$manifest_path"
  "$PLUTIL_BIN" -replace ngrok.developerIdAuthority -string "$NGROK_AUTHORITY" "$manifest_path"
  "$PLUTIL_BIN" -replace ngrok.developerIdTeam -string "$NGROK_TEAM" "$manifest_path"
  "$PLUTIL_BIN" -convert xml1 -o /dev/null "$manifest_path" >/dev/null 2>&1 || die "generated manifest is invalid"
  if /usr/bin/grep -q 'REPLACE_WITH' "$manifest_path" || /usr/bin/grep -q 'example\\.invalid' "$manifest_path"; then
    die "generated manifest still contains a template value"
  fi
  validate_concrete_manifest "$manifest_path"
}

validate_concrete_manifest() {
  manifest_path="$1"
  "$PYTHON_BIN" - "$manifest_path" "$PRODUCT_VERSION" "$BOOTSTRAP_URL" "$HELPER_URL" "$UV_URL" "$CORE_URL" "$NGROK_URL" <<'PY'
import json
import re
import sys

path, product_version, bootstrap_url, helper_url, uv_url, core_url, ngrok_url = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)

assert manifest["schemaVersion"] == 1
assert manifest["product"] == {"name": "Mac Orchestrator", "version": product_version}
assert manifest["platform"]["architecture"] == "arm64"
assert manifest["helper"]["architecture"] == "arm64"
assert manifest["helper"]["bundleIdentifier"] == "com.jay.mac-orchestrator"
assert manifest["helper"]["version"] == product_version
assert manifest["helper"]["signing"]["mode"] == "adhoc"
assert manifest["runtime"]["schemaVersion"] == 1
assert manifest["runtime"]["python"]["managedVersion"] == "3.13.14"
assert manifest["runtime"]["uv"]["version"] == "0.12.3"
assert manifest["runtime"]["corePayload"]["format"] == "tar.gz"
assert manifest["runtime"]["corePayload"]["files"] == [
    "automac_mcp.py",
    "pyproject.toml",
    "uv.lock",
]
assert manifest["ngrok"]["archiveFormat"] == "zip"
assert manifest["ngrok"]["executableName"] == "ngrok"
assert manifest["ngrok"]["agentApiVersion"] == "v3"
assert manifest["bootstrap"]["url"] == bootstrap_url
assert manifest["helper"]["url"] == helper_url
assert manifest["runtime"]["uv"]["url"] == uv_url
assert manifest["runtime"]["corePayload"]["url"] == core_url
assert manifest["ngrok"]["archiveUrl"] == ngrok_url

digest_fields = (
    manifest["bootstrap"]["sha256"],
    manifest["helper"]["sha256"],
    manifest["runtime"]["uv"]["sha256"],
    manifest["runtime"]["lockSha256"],
    manifest["runtime"]["corePayload"]["sha256"],
    manifest["ngrok"]["archiveSha256"],
)
assert all(re.fullmatch(r"[0-9a-fA-F]{64}", value) and set(value) != {"0"} for value in digest_fields)
assert manifest["compatibility"]["runtimeSchema"] == {"minimum": 1, "maximum": 1}
assert manifest["compatibility"]["configurationSchema"] == {"minimum": 1, "maximum": 1}
PY
}
write_checksums() {
  checksums_path="$OUTPUT_DIR/SHA256SUMS"
  (
    cd "$OUTPUT_DIR"
    for asset in bootstrap.sh manifest.json Mac-Orchestrator-arm64.zip uv-arm64 core-payload.tar.gz install-command.sh; do
      [ -f "$asset" ] || die "release asset is missing before checksum generation: $asset"
      "$SHASUM_BIN" -a 256 "$asset"
    done
  ) > "$checksums_path"
  /bin/chmod 644 "$checksums_path"
}

validate_inputs() {
  require_input "--product-version" "$PRODUCT_VERSION"
  require_input "--bootstrap-version" "$BOOTSTRAP_VERSION"
  require_file "--bootstrap" "$BOOTSTRAP_PATH"
  require_https_url "--bootstrap-url" "$BOOTSTRAP_URL"
  require_release_asset_url "--bootstrap-url" "$BOOTSTRAP_URL" "bootstrap.sh"
  require_sha256 "--bootstrap-sha256" "$BOOTSTRAP_SHA256"
  require_https_url "--manifest-url" "$MANIFEST_URL"
  require_release_asset_url "--manifest-url" "$MANIFEST_URL" "manifest.json"
  require_input "--helper-app or --helper-archive" "$HELPER_APP$HELPER_ARCHIVE"
  [ -z "$HELPER_APP" ] || [ -z "$HELPER_ARCHIVE" ] || die "choose only one helper input"
  require_https_url "--helper-url" "$HELPER_URL"
  require_release_asset_url "--helper-url" "$HELPER_URL" "Mac-Orchestrator-arm64.zip"
  require_sha256 "--helper-sha256" "$HELPER_SHA256"
  require_input "--uv" "$UV_PATH"
  require_https_url "--uv-url" "$UV_URL"
  require_release_asset_url "--uv-url" "$UV_URL" "uv-arm64"
  require_sha256 "--uv-sha256" "$UV_SHA256"
  require_input "--core-payload" "$CORE_PAYLOAD_PATH"
  require_https_url "--core-url" "$CORE_URL"
  require_release_asset_url "--core-url" "$CORE_URL" "core-payload.tar.gz"
  require_sha256 "--core-sha256" "$CORE_SHA256"
  require_input "--lock" "$LOCK_PATH"
  require_sha256 "--lock-sha256" "$LOCK_SHA256"
  require_input "--ngrok-archive" "$NGROK_ARCHIVE_PATH"
  require_input "--ngrok-version" "$NGROK_VERSION"
  require_https_url "--ngrok-url" "$NGROK_URL"
  require_ngrok_vendor_url "$NGROK_URL"
  require_sha256 "--ngrok-sha256" "$NGROK_SHA256"
  require_input "--ngrok-authority" "$NGROK_AUTHORITY"
  require_input "--ngrok-team" "$NGROK_TEAM"
  [ "${#NGROK_TEAM}" -eq 10 ] || die "--ngrok-team must be ten uppercase characters"
  case "$NGROK_TEAM" in
    *[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ]*) die "--ngrok-team must be ten uppercase characters" ;;
  esac
}

main() {
  validate_inputs
  /bin/mkdir -p "$OUTPUT_DIR"
  WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.work-XXXXXX")"
  verify_digest "bootstrap" "$BOOTSTRAP_PATH" "$BOOTSTRAP_SHA256"
  prepare_helper
  prepare_core_payload
  prepare_binary_inputs
  /bin/cp "$BOOTSTRAP_PATH" "$OUTPUT_DIR/bootstrap.sh"
  /bin/chmod 755 "$OUTPUT_DIR/bootstrap.sh"
  write_manifest
  manifest_sha256="$(sha256_file "$OUTPUT_DIR/manifest.json")" || die "could not hash generated manifest"
  bash "$PROJECT_DIR/script/generate_install_command.sh" \
    --product-version "$PRODUCT_VERSION" \
    --bootstrap-url "$BOOTSTRAP_URL" \
    --bootstrap-sha256 "$BOOTSTRAP_SHA256" \
    --manifest-url "$MANIFEST_URL" \
    --manifest-sha256 "$manifest_sha256" \
    --output "$OUTPUT_DIR/install-command.sh" \
    --release-body "$OUTPUT_DIR/release-body.md" >/dev/null
  write_checksums
  echo "$OUTPUT_DIR/manifest.json"
}

main "$@"
