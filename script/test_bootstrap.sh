#!/usr/bin/env bash
set -u

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$PROJECT_DIR/script/bootstrap.sh"
TEMPLATE="$PROJECT_DIR/release/manifest.template.json"
PLUTIL_BIN="${PLUTIL_BIN:-/usr/bin/plutil}"
SHASUM_BIN="${SHASUM_BIN:-/usr/bin/shasum}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mac-orchestrator-bootstrap.XXXXXX")"
ORIGINAL_PATH="$PATH"
TEST_PLUTIL_BIN="$PLUTIL_BIN"
FAILURES=0
BOOTSTRAP_OUTPUT=""
BOOTSTRAP_RC=0

cleanup() {
  /bin/rm -rf "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "FAIL: $*" >&2
  return 1
}

assert_file() {
  if [ ! -f "$1" ]; then
    fail "expected file: $1"
  fi
}

assert_dir() {
  if [ ! -d "$1" ]; then
    fail "expected directory: $1"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected output to contain '$2'" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected output not to contain '$2'" ;;
    *) ;;
  esac
}

assert_content() {
  actual="$(/bin/cat "$1")" || return 1
  if [ "$actual" != "$2" ]; then
    fail "unexpected content in $1: '$actual'"
  fi
}

sha256() {
  output="$($SHASUM_BIN -a 256 "$1")" || return 1
  echo "${output%% *}"
}

select_test_plutil() {
  if "$PLUTIL_BIN" -convert xml1 -o /dev/null "$TEMPLATE" >/dev/null 2>&1; then
    return 0
  fi

  PYTHON_BIN="$(command -v python3 || true)"
  [ -n "$PYTHON_BIN" ] || fail "host plutil cannot parse JSON and python3 is unavailable for the test shim" || return 1
  TEST_PLUTIL_BIN="$TEST_ROOT/plutil"
  printf '%s\n' \
    '#!/usr/bin/env python3' \
    'import json' \
    'import sys' \
    '' \
    'def load(path):' \
    '    with open(path, "r") as handle:' \
    '        return json.load(handle)' \
    '' \
    'def save(path, value):' \
    '    with open(path, "w") as handle:' \
    '        json.dump(value, handle, indent=2)' \
    '        handle.write("\n")' \
    '' \
    'def walk(value, keypath):' \
    '    for component in keypath.split("."):' \
    '        value = value[component]' \
    '    return value' \
    '' \
    'args = sys.argv[1:]' \
    'if args and args[0] == "-lint":' \
    '    load(args[1])' \
    '    print(args[1] + ": OK")' \
    '    raise SystemExit(0)' \
    'if args and args[0] == "-convert":' \
    '    document = load(args[-1])' \
    '    if "-o" in args:' \
    '        save(args[args.index("-o") + 1], document)' \
    '    raise SystemExit(0)' \
    'if args and args[0] == "-create":' \
    '    save(args[-1], {})' \
    '    raise SystemExit(0)' \
    'if args and args[0] == "-insert":' \
    '    document = load(args[-1])' \
    '    key = args[1]' \
    '    kind = args[2]' \
    '    value = args[3]' \
    '    if kind == "-integer": value = int(value)' \
    '    elif kind == "-bool": value = value == "true"' \
    '    document[key] = value' \
    '    save(args[-1], document)' \
    '    raise SystemExit(0)' \
    'if args and args[0] == "-extract":' \
    '    value = walk(load(args[-1]), args[1])' \
    '    if isinstance(value, (dict, list)):' \
    '        print(json.dumps(value, separators=(",", ":")))' \
    '    elif isinstance(value, bool):' \
    '        print("true" if value else "false")' \
    '    else:' \
    '        print(value)' \
    '    raise SystemExit(0)' \
    'if args and args[0] == "-replace":' \
    '    document = load(args[-1])' \
    '    components = args[1].split(".")' \
    '    target = document' \
    '    for component in components[:-1]:' \
    '        target = target[component]' \
    '    target[components[-1]] = args[3]' \
    '    save(args[-1], document)' \
    '    raise SystemExit(0)' \
    'raise SystemExit("unsupported test plutil invocation: " + repr(args))' > "$TEST_PLUTIL_BIN"
  /bin/chmod 755 "$TEST_PLUTIL_BIN"
}

replace_string() {
  keypath="$1"
  value="$2"
  manifest="$3"
  "$TEST_PLUTIL_BIN" -replace "$keypath" -string "$value" "$manifest"
}

make_case() {
  case_name="$1"
  CASE_DIR="$TEST_ROOT/$case_name"
  /bin/mkdir -p "$CASE_DIR/assets" "$CASE_DIR/bin" "$CASE_DIR/support" || return 1

  printf '%s\n' 'fixture-helper' > "$CASE_DIR/assets/helper.zip"
  printf '%s\n' 'fixture-uv' > "$CASE_DIR/assets/uv"
  printf '%s\n' 'fixture-core-payload' > "$CASE_DIR/assets/core.tar.gz"
  printf '%s\n' 'fixture-ngrok-archive' > "$CASE_DIR/assets/ngrok.zip"
  printf '%s\n' 'fixture-lock' > "$CASE_DIR/assets/uv.lock"

  printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "arm64"' > "$CASE_DIR/bin/uname"
  printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "13.6.1"' > "$CASE_DIR/bin/sw_vers"
  /bin/chmod 755 "$CASE_DIR/bin/uname" "$CASE_DIR/bin/sw_vers"

  MANIFEST="$CASE_DIR/manifest.json"
  /bin/cp "$TEMPLATE" "$MANIFEST" || return 1

  helper_path="$CASE_DIR/assets/helper.zip"
  uv_path="$CASE_DIR/assets/uv"
  core_path="$CASE_DIR/assets/core.tar.gz"
  ngrok_path="$CASE_DIR/assets/ngrok.zip"
  lock_path="$CASE_DIR/assets/uv.lock"

  replace_string product.version "0.3.0-fixture" "$MANIFEST" || return 1
  replace_string bootstrap.version "1.0.0-fixture" "$MANIFEST" || return 1
  replace_string bootstrap.url "file://$BOOTSTRAP" "$MANIFEST" || return 1
  replace_string bootstrap.sha256 "$(sha256 "$BOOTSTRAP")" "$MANIFEST" || return 1
  replace_string helper.url "file://$helper_path" "$MANIFEST" || return 1
  replace_string helper.sha256 "$(sha256 "$helper_path")" "$MANIFEST" || return 1
  replace_string helper.version "0.3.0-fixture" "$MANIFEST" || return 1
  replace_string runtime.uv.url "file://$uv_path" "$MANIFEST" || return 1
  replace_string runtime.uv.sha256 "$(sha256 "$uv_path")" "$MANIFEST" || return 1
  replace_string runtime.lockSha256 "$(sha256 "$lock_path")" "$MANIFEST" || return 1
  replace_string runtime.corePayload.url "file://$core_path" "$MANIFEST" || return 1
  replace_string runtime.corePayload.sha256 "$(sha256 "$core_path")" "$MANIFEST" || return 1
  replace_string ngrok.archiveUrl "file://$ngrok_path" "$MANIFEST" || return 1
  replace_string ngrok.archiveSha256 "$(sha256 "$ngrok_path")" "$MANIFEST" || return 1
  replace_string ngrok.developerIdAuthority "Developer ID Application: ngrok (TEAMFIX123)" "$MANIFEST" || return 1
  replace_string ngrok.developerIdTeam "TEAMFIX123" "$MANIFEST" || return 1
}

capture_bootstrap() {
  case_dir="$1"
  shift
  capture_bootstrap_pinned "$case_dir" "$(sha256 "$BOOTSTRAP")" "$(sha256 "$case_dir/manifest.json")" "0.3.0-fixture" "$BOOTSTRAP" "$@"
}

capture_bootstrap_pinned() {
  case_dir="$1"
  bootstrap_digest="$2"
  manifest_digest="$3"
  release_version="$4"
  bootstrap_path="$5"
  shift 5
  BOOTSTRAP_OUTPUT="$(
    /usr/bin/env \
      MAC_ORCHESTRATOR_MANIFEST_PATH="$case_dir/manifest.json" \
      MAC_ORCHESTRATOR_BOOTSTRAP_SHA256="$bootstrap_digest" \
      MAC_ORCHESTRATOR_MANIFEST_SHA256="$manifest_digest" \
      MAC_ORCHESTRATOR_RELEASE_VERSION="$release_version" \
      MAC_ORCHESTRATOR_SUPPORT_DIR="$case_dir/support" \
      MAC_ORCHESTRATOR_FIXTURE_MODE=1 \
      MAC_ORCHESTRATOR_FIXTURE_LOCK_PATH="$case_dir/assets/uv.lock" \
      MAC_ORCHESTRATOR_UNAME_BIN="$case_dir/bin/uname" \
      MAC_ORCHESTRATOR_SW_VERS_BIN="$case_dir/bin/sw_vers" \
      PLUTIL_BIN="$TEST_PLUTIL_BIN" \
      PATH="$ORIGINAL_PATH" \
      bash "$bootstrap_path" "$@" 2>&1
  )"
  BOOTSTRAP_RC=$?
}

capture_bootstrap_with_env() {
  case_dir="$1"
  env_name="$2"
  shift 2
  capture_bootstrap_with_env_pinned "$case_dir" "$env_name" "$(sha256 "$BOOTSTRAP")" "$(sha256 "$case_dir/manifest.json")" "0.3.0-fixture" "$BOOTSTRAP" "$@"
}

capture_bootstrap_with_env_pinned() {
  case_dir="$1"
  env_name="$2"
  bootstrap_digest="$3"
  manifest_digest="$4"
  release_version="$5"
  bootstrap_path="$6"
  shift 6
  BOOTSTRAP_OUTPUT="$(
    /usr/bin/env \
      MAC_ORCHESTRATOR_MANIFEST_PATH="$case_dir/manifest.json" \
      MAC_ORCHESTRATOR_BOOTSTRAP_SHA256="$bootstrap_digest" \
      MAC_ORCHESTRATOR_MANIFEST_SHA256="$manifest_digest" \
      MAC_ORCHESTRATOR_RELEASE_VERSION="$release_version" \
      MAC_ORCHESTRATOR_SUPPORT_DIR="$case_dir/support" \
      MAC_ORCHESTRATOR_FIXTURE_MODE=1 \
      MAC_ORCHESTRATOR_FIXTURE_LOCK_PATH="$case_dir/assets/uv.lock" \
      MAC_ORCHESTRATOR_UNAME_BIN="$case_dir/bin/uname" \
      MAC_ORCHESTRATOR_SW_VERS_BIN="$case_dir/bin/sw_vers" \
      PLUTIL_BIN="$TEST_PLUTIL_BIN" \
      "$env_name"=1 \
      PATH="$ORIGINAL_PATH" \
      bash "$bootstrap_path" "$@" 2>&1
  )"
  BOOTSTRAP_RC=$?
}

test_valid_manifest_acceptance() {
  make_case valid || return 1
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -eq 0 ] || { echo "$BOOTSTRAP_OUTPUT" >&2; return 1; }
  assert_contains "$BOOTSTRAP_OUTPUT" "Verified release metadata." || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "This Mac meets the release requirements." || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "Verified release payloads." || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "Installed Mac Orchestrator." || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "Mac Orchestrator is ready." || return 1
  assert_not_contains "$BOOTSTRAP_OUTPUT" "$CASE_DIR" || return 1
}

test_missing_digest_rejected() {
  make_case missing-digest || return 1
  replace_string helper.sha256 "REPLACE_WITH_SHA256" "$MANIFEST" || return 1
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "helper digest" || return 1
}

test_sentinel_digest_rejected() {
  make_case sentinel-digest || return 1
  replace_string helper.sha256 "0000000000000000000000000000000000000000000000000000000000000000" "$MANIFEST" || return 1
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "must not be all zeroes" || return 1
}

test_wrong_digest_rejected() {
  make_case wrong-digest || return 1
  replace_string helper.sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$MANIFEST" || return 1
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "digest mismatch" || return 1
}

test_manifest_digest_rejected_before_manifest_use() {
  make_case manifest-digest || return 1
  expected_manifest_digest="$(sha256 "$MANIFEST")"
  replace_string product.version "0.3.1-fixture" "$MANIFEST" || return 1
  capture_bootstrap_pinned "$CASE_DIR" "$(sha256 "$BOOTSTRAP")" "$expected_manifest_digest" "0.3.0-fixture" "$BOOTSTRAP"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "manifest digest" || return 1
}

test_bootstrap_digest_rejected_before_execution() {
  make_case bootstrap-digest || return 1
  modified_bootstrap="$CASE_DIR/bin/bootstrap-modified"
  /bin/cp "$BOOTSTRAP" "$modified_bootstrap" || return 1
  printf '\n' >> "$modified_bootstrap"
  replace_string bootstrap.sha256 "$(sha256 "$modified_bootstrap")" "$MANIFEST" || return 1
  capture_bootstrap_pinned "$CASE_DIR" "$(sha256 "$BOOTSTRAP")" "$(sha256 "$MANIFEST")" "0.3.0-fixture" "$modified_bootstrap"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "bootstrap digest" || return 1
}

test_modified_core_payload_rejected() {
  make_case core-digest || return 1
  printf '%s\n' 'modified-core-payload' >> "$CASE_DIR/assets/core.tar.gz"
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "core payload digest mismatch" || return 1
}

test_ngrok_zip_format_required() {
  make_case ngrok-format || return 1
  replace_string ngrok.archiveFormat "tar.gz" "$MANIFEST" || return 1
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "ngrok archive must be a zip" || return 1
}

test_mutable_release_url_rejected() {
  make_case mutable-url || return 1
  replace_string helper.url "https://downloads.example.com/releases/refs/heads/main/helper.zip" "$MANIFEST" || return 1
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "immutable" || return 1
}

test_non_vendor_ngrok_url_rejected() {
  make_case non-vendor-ngrok || return 1
  replace_string ngrok.archiveUrl "https://downloads.example.com/ngrok-arm64.zip" "$MANIFEST" || return 1
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "bin.equinox.io" || return 1
}

test_unsupported_architecture_rejected() {
  make_case wrong-architecture || return 1
  printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "x86_64"' > "$CASE_DIR/bin/uname"
  /bin/chmod 755 "$CASE_DIR/bin/uname"
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "arm64" || return 1
}

test_old_macos_rejected() {
  make_case old-macos || return 1
  printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "12.6.9"' > "$CASE_DIR/bin/sw_vers"
  /bin/chmod 755 "$CASE_DIR/bin/sw_vers"
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "macOS" || return 1
}

test_repeat_promotion_is_idempotent() {
  make_case repeat || return 1
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -eq 0 ] || { echo "$BOOTSTRAP_OUTPUT" >&2; return 1; }
  printf '%s\n' 'keep-me' > "$CASE_DIR/support/config.json"
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -eq 0 ] || { echo "$BOOTSTRAP_OUTPUT" >&2; return 1; }
  assert_dir "$CASE_DIR/support/runtime" || return 1
  assert_file "$CASE_DIR/support/runtime/.release-marker" || return 1
  assert_dir "$CASE_DIR/support/install/runtime.previous" || return 1
  assert_content "$CASE_DIR/support/config.json" "keep-me" || return 1
  staging_count="$(find "$CASE_DIR/support/install" -maxdepth 1 -name 'staging-*' -print | wc -l | tr -d ' ')"
  [ "$staging_count" -eq 0 ] || fail "staging directories remain after repeat promotion"
}

test_failed_download_preserves_previous_state() {
  make_case failed-download || return 1
  /bin/mkdir -p "$CASE_DIR/support/runtime" "$CASE_DIR/support/install"
  printf '%s\n' 'previous-runtime' > "$CASE_DIR/support/runtime/.release-marker"
  printf '%s\n' 'keep-config' > "$CASE_DIR/support/config.json"
  replace_string helper.url "file://$CASE_DIR/assets/missing-helper.zip" "$MANIFEST" || return 1
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_content "$CASE_DIR/support/runtime/.release-marker" "previous-runtime" || return 1
  assert_content "$CASE_DIR/support/config.json" "keep-config" || return 1
  staging_count="$(find "$CASE_DIR/support/install" -maxdepth 1 -name 'staging-*' -print | wc -l | tr -d ' ')"
  [ "$staging_count" -eq 0 ] || fail "staging directories remain after failed download"
}

test_interrupted_promotion_recovers_previous_runtime() {
  make_case interrupted || return 1
  /bin/mkdir -p "$CASE_DIR/support/runtime" "$CASE_DIR/support/app" "$CASE_DIR/support/remote/ngrok" "$CASE_DIR/support/install"
  printf '%s\n' 'previous-runtime' > "$CASE_DIR/support/runtime/.release-marker"
  printf '%s\n' 'previous-helper' > "$CASE_DIR/support/app/helper-artifact"
  printf '%s\n' 'previous-ngrok' > "$CASE_DIR/support/remote/ngrok/ngrok"
  capture_bootstrap_with_env "$CASE_DIR" MAC_ORCHESTRATOR_TEST_FAIL_AFTER_PROMOTION
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_content "$CASE_DIR/support/runtime/.release-marker" "previous-runtime" || return 1
  assert_content "$CASE_DIR/support/app/helper-artifact" "previous-helper" || return 1
  assert_content "$CASE_DIR/support/remote/ngrok/ngrok" "previous-ngrok" || return 1
  if [ -e "$CASE_DIR/support/install/promotion.marker" ]; then
    fail "promotion marker survived trapped recovery"
  fi
}

test_pre_commit_failure_recovers_previous_installation() {
  make_case post-promotion || return 1
  /bin/mkdir -p "$CASE_DIR/support/runtime" "$CASE_DIR/support/app" "$CASE_DIR/support/remote/ngrok" "$CASE_DIR/support/install"
  printf '%s\n' 'previous-runtime' > "$CASE_DIR/support/runtime/.release-marker"
  printf '%s\n' 'previous-helper' > "$CASE_DIR/support/app/helper-artifact"
  printf '%s\n' 'previous-ngrok' > "$CASE_DIR/support/remote/ngrok/ngrok"
  capture_bootstrap_with_env "$CASE_DIR" MAC_ORCHESTRATOR_TEST_FAIL_AFTER_POST_PROMOTION
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_content "$CASE_DIR/support/runtime/.release-marker" "previous-runtime" || return 1
  assert_content "$CASE_DIR/support/app/helper-artifact" "previous-helper" || return 1
  assert_content "$CASE_DIR/support/remote/ngrok/ngrok" "previous-ngrok" || return 1
  [ ! -e "$CASE_DIR/support/install/promotion.marker" ] || return 1
}

test_structural_failure_after_promotion_recovers_previous_installation() {
  make_case structural-failure || return 1
  /bin/mkdir -p "$CASE_DIR/support/runtime" "$CASE_DIR/support/app" "$CASE_DIR/support/remote/ngrok" "$CASE_DIR/support/install"
  printf '%s\n' 'previous-runtime' > "$CASE_DIR/support/runtime/.release-marker"
  printf '%s\n' 'previous-helper' > "$CASE_DIR/support/app/helper-artifact"
  printf '%s\n' 'previous-ngrok' > "$CASE_DIR/support/remote/ngrok/ngrok"
  capture_bootstrap_with_env "$CASE_DIR" MAC_ORCHESTRATOR_TEST_BREAK_PROMOTED_INSTALLATION
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_content "$CASE_DIR/support/runtime/.release-marker" "previous-runtime" || return 1
  assert_content "$CASE_DIR/support/app/helper-artifact" "previous-helper" || return 1
  assert_content "$CASE_DIR/support/remote/ngrok/ngrok" "previous-ngrok" || return 1
  [ ! -e "$CASE_DIR/support/install/promotion.marker" ] || return 1
}

test_launch_agent_failure_before_commit_recovers_previous_installation() {
  make_case launch-agent-failure || return 1
  /bin/mkdir -p "$CASE_DIR/support/runtime" "$CASE_DIR/support/app" "$CASE_DIR/support/remote/ngrok" "$CASE_DIR/support/install"
  printf '%s\n' 'previous-runtime' > "$CASE_DIR/support/runtime/.release-marker"
  printf '%s\n' 'previous-helper' > "$CASE_DIR/support/app/helper-artifact"
  printf '%s\n' 'previous-ngrok' > "$CASE_DIR/support/remote/ngrok/ngrok"
  capture_bootstrap_with_env "$CASE_DIR" MAC_ORCHESTRATOR_TEST_FAIL_LAUNCH_AGENT
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_content "$CASE_DIR/support/runtime/.release-marker" "previous-runtime" || return 1
  assert_content "$CASE_DIR/support/app/helper-artifact" "previous-helper" || return 1
  assert_content "$CASE_DIR/support/remote/ngrok/ngrok" "previous-ngrok" || return 1
  [ ! -e "$CASE_DIR/support/install/promotion.marker" ] || return 1
}

test_onboarding_failure_after_install_commit_preserves_new_installation() {
  make_case onboarding-failure || return 1
  /bin/mkdir -p "$CASE_DIR/support/runtime" "$CASE_DIR/support/app" "$CASE_DIR/support/remote/ngrok" "$CASE_DIR/support/install"
  printf '%s\n' 'previous-runtime' > "$CASE_DIR/support/runtime/.release-marker"
  printf '%s\n' 'previous-helper' > "$CASE_DIR/support/app/helper-artifact"
  printf '%s\n' 'previous-ngrok' > "$CASE_DIR/support/remote/ngrok/ngrok"
  capture_bootstrap_with_env "$CASE_DIR" MAC_ORCHESTRATOR_TEST_FAIL_AFTER_INSTALL_COMMIT
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_content "$CASE_DIR/support/runtime/.release-marker" "0.3.0-fixture" || return 1
  assert_content "$CASE_DIR/support/app/helper-artifact" "fixture-helper" || return 1
  assert_content "$CASE_DIR/support/remote/ngrok/archive.zip" "fixture-ngrok-archive" || return 1
  assert_content "$CASE_DIR/support/install/runtime.previous/.release-marker" "previous-runtime" || return 1
  assert_content "$CASE_DIR/support/install/app.previous/helper-artifact" "previous-helper" || return 1
  assert_content "$CASE_DIR/support/install/remote.previous/ngrok" "previous-ngrok" || return 1
  [ ! -e "$CASE_DIR/support/install/promotion.marker" ] || return 1
}

test_requested_remote_failure_after_install_commit_preserves_local_installation() {
  make_case remote-failure || return 1
  /bin/mkdir -p "$CASE_DIR/support/runtime" "$CASE_DIR/support/app" "$CASE_DIR/support/remote/ngrok" "$CASE_DIR/support/install"
  printf '%s\n' 'previous-runtime' > "$CASE_DIR/support/runtime/.release-marker"
  printf '%s\n' 'previous-helper' > "$CASE_DIR/support/app/helper-artifact"
  printf '%s\n' 'previous-ngrok' > "$CASE_DIR/support/remote/ngrok/ngrok"
  capture_bootstrap_with_env "$CASE_DIR" MAC_ORCHESTRATOR_TEST_FAIL_REMOTE_ONBOARDING --remote
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "remote" || return 1
  assert_content "$CASE_DIR/support/runtime/.release-marker" "0.3.0-fixture" || return 1
  assert_content "$CASE_DIR/support/app/helper-artifact" "fixture-helper" || return 1
  assert_content "$CASE_DIR/support/remote/ngrok/archive.zip" "fixture-ngrok-archive" || return 1
  assert_content "$CASE_DIR/support/install/runtime.previous/.release-marker" "previous-runtime" || return 1
  [ ! -e "$CASE_DIR/support/install/promotion.marker" ] || return 1
}

test_requested_remote_success_path_remains_available() {
  make_case remote-success || return 1
  capture_bootstrap "$CASE_DIR" --remote
  [ "$BOOTSTRAP_RC" -eq 0 ] || { echo "$BOOTSTRAP_OUTPUT" >&2; return 1; }
  assert_contains "$BOOTSTRAP_OUTPUT" "Remote access enabled; waiting for a live connector." || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "Mac Orchestrator is ready." || return 1
}

test_next_run_recovers_promotion_marker() {
  make_case next-run-recovery || return 1
  /bin/mkdir -p "$CASE_DIR/support/runtime" "$CASE_DIR/support/install/runtime.previous" "$CASE_DIR/support/install/app.previous" "$CASE_DIR/support/install/remote.previous"
  printf '%s\n' 'interrupted-runtime' > "$CASE_DIR/support/runtime/.release-marker"
  printf '%s\n' 'previous-runtime' > "$CASE_DIR/support/install/runtime.previous/.release-marker"
  printf '%s\n' 'previous-helper' > "$CASE_DIR/support/install/app.previous/helper-artifact"
  printf '%s\n' 'previous-ngrok' > "$CASE_DIR/support/install/remote.previous/ngrok"
  printf '%s\n' 'phase=promoting' 'had_runtime=1' 'had_app=1' 'had_remote=1' > "$CASE_DIR/support/install/promotion.marker"
  capture_bootstrap_with_env "$CASE_DIR" MAC_ORCHESTRATOR_TEST_EXIT_AFTER_RECOVERY
  [ "$BOOTSTRAP_RC" -eq 0 ] || { echo "$BOOTSTRAP_OUTPUT" >&2; return 1; }
  assert_content "$CASE_DIR/support/runtime/.release-marker" "previous-runtime" || return 1
  assert_content "$CASE_DIR/support/app/helper-artifact" "previous-helper" || return 1
  assert_content "$CASE_DIR/support/remote/ngrok/ngrok" "previous-ngrok" || return 1
  if [ -e "$CASE_DIR/support/install/promotion.marker" ]; then
    fail "promotion marker was not cleared on next run"
  fi
}

test_symlinked_support_root_rejected() {
  make_case symlinked-support || return 1
  outside="$CASE_DIR/outside"
  /bin/mkdir -p "$outside"
  /bin/rm -rf "$CASE_DIR/support"
  /bin/ln -s "$outside" "$CASE_DIR/support"
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "symlink" || return 1
  [ ! -e "$outside/runtime" ] || return 1
}

test_symlinked_support_parent_rejected() {
  make_case symlinked-support-parent || return 1
  outside="$CASE_DIR/outside"
  /bin/mkdir -p "$outside" "$CASE_DIR/support-parent"
  /bin/rm -rf "$CASE_DIR/support"
  /bin/ln -s "$outside" "$CASE_DIR/support-parent/link"
  BOOTSTRAP_OUTPUT="$({
    /usr/bin/env \
      MAC_ORCHESTRATOR_MANIFEST_PATH="$CASE_DIR/manifest.json" \
      MAC_ORCHESTRATOR_BOOTSTRAP_SHA256="$(sha256 "$BOOTSTRAP")" \
      MAC_ORCHESTRATOR_MANIFEST_SHA256="$(sha256 "$CASE_DIR/manifest.json")" \
      MAC_ORCHESTRATOR_RELEASE_VERSION="0.3.0-fixture" \
      MAC_ORCHESTRATOR_SUPPORT_DIR="$CASE_DIR/support-parent/link/child" \
      MAC_ORCHESTRATOR_FIXTURE_MODE=1 \
      MAC_ORCHESTRATOR_FIXTURE_LOCK_PATH="$CASE_DIR/assets/uv.lock" \
      MAC_ORCHESTRATOR_UNAME_BIN="$CASE_DIR/bin/uname" \
      MAC_ORCHESTRATOR_SW_VERS_BIN="$CASE_DIR/bin/sw_vers" \
      PLUTIL_BIN="$TEST_PLUTIL_BIN" \
      PATH="$ORIGINAL_PATH" \
      bash "$BOOTSTRAP" 2>&1
  })"
  BOOTSTRAP_RC=$?
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "symlinked parent" || return 1
  [ ! -e "$outside/child" ] || return 1
}

test_symlinked_managed_python_directory_rejected() {
  make_case symlinked-python || return 1
  outside="$CASE_DIR/python-outside"
  /bin/mkdir -p "$outside"
  /bin/ln -s "$outside" "$CASE_DIR/support/python"
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "managed Python directory" || return 1
  [ ! -e "$outside/cpython-3.13.14" ] || return 1
}

test_malformed_promotion_marker_fails_closed() {
  make_case malformed-marker || return 1
  /bin/mkdir -p "$CASE_DIR/support/install" "$CASE_DIR/support/runtime"
  printf '%s\n' 'phase=unknown' 'had_runtime=1' 'had_app=0' 'had_remote=0' > "$CASE_DIR/support/install/promotion.marker"
  printf '%s\n' 'previous-runtime' > "$CASE_DIR/support/runtime/.release-marker"
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "recover" || return 1
  assert_file "$CASE_DIR/support/install/promotion.marker" || return 1
  assert_content "$CASE_DIR/support/runtime/.release-marker" "previous-runtime" || return 1
}

test_missing_recovery_backup_fails_closed() {
  make_case missing-backup || return 1
  /bin/mkdir -p "$CASE_DIR/support/install" "$CASE_DIR/support/runtime"
  printf '%s\n' 'phase=promoting' 'had_runtime=1' 'had_app=0' 'had_remote=0' > "$CASE_DIR/support/install/promotion.marker"
  printf '%s\n' 'interrupted-runtime' > "$CASE_DIR/support/runtime/.release-marker"
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "recover" || return 1
  assert_file "$CASE_DIR/support/install/promotion.marker" || return 1
  assert_content "$CASE_DIR/support/runtime/.release-marker" "interrupted-runtime" || return 1
}

test_backups_marker_with_unmoved_previous_paths_recovers() {
  make_case backups-marker || return 1
  /bin/mkdir -p "$CASE_DIR/support/install" "$CASE_DIR/support/runtime"
  printf '%s\n' 'phase=backups' 'had_runtime=1' 'had_app=0' 'had_remote=0' > "$CASE_DIR/support/install/promotion.marker"
  printf '%s\n' 'previous-runtime' > "$CASE_DIR/support/runtime/.release-marker"
  capture_bootstrap_with_env "$CASE_DIR" MAC_ORCHESTRATOR_TEST_EXIT_AFTER_RECOVERY
  [ "$BOOTSTRAP_RC" -eq 0 ] || { echo "$BOOTSTRAP_OUTPUT" >&2; return 1; }
  assert_content "$CASE_DIR/support/runtime/.release-marker" "previous-runtime" || return 1
  [ ! -e "$CASE_DIR/support/install/promotion.marker" ] || return 1
}

test_promotion_marker_symlink_rejected() {
  make_case marker-symlink || return 1
  /bin/mkdir -p "$CASE_DIR/support/install" "$CASE_DIR/outside"
  printf '%s\n' 'outside-marker' > "$CASE_DIR/outside/marker"
  /bin/ln -s "$CASE_DIR/outside/marker" "$CASE_DIR/support/install/promotion.marker"
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "recover" || return 1
  assert_content "$CASE_DIR/outside/marker" "outside-marker" || return 1
}

test_artifact_builder_requires_release_inputs() {
  output="$(bash "$PROJECT_DIR/script/build_release_artifacts.sh" --output-dir "$TEST_ROOT/builder-output" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || return 1
  assert_contains "$output" "required" || return 1
}

test_artifact_builder_rejects_non_vendor_ngrok_url() {
  digest="$(sha256 "$BOOTSTRAP")"
  output="$(bash "$PROJECT_DIR/script/build_release_artifacts.sh" \
    --product-version "0.3.0" \
    --bootstrap-version "1.0.0-fixture" \
    --bootstrap "$BOOTSTRAP" \
    --bootstrap-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/bootstrap.sh" \
    --bootstrap-sha256 "$digest" \
    --manifest-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/manifest.json" \
    --helper-archive "$BOOTSTRAP" \
    --helper-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/Mac-Orchestrator-arm64.zip" \
    --helper-sha256 "$digest" \
    --uv "$BOOTSTRAP" \
    --uv-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/uv-arm64" \
    --uv-sha256 "$digest" \
    --core-payload "$BOOTSTRAP" \
    --core-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/core-payload.tar.gz" \
    --core-sha256 "$digest" \
    --lock "$BOOTSTRAP" \
    --lock-sha256 "$digest" \
    --ngrok-archive "$BOOTSTRAP" \
    --ngrok-version "3.39.10" \
    --ngrok-url "https://downloads.example.com/ngrok-arm64.zip" \
    --ngrok-sha256 "$digest" \
    --ngrok-authority "Developer ID Application: ngrok, Inc. (TEAMFIX123)" \
    --ngrok-team "TEAMFIX123" \
    --output-dir "$TEST_ROOT/builder-vendor-output" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || return 1
  assert_contains "$output" "bin.equinox.io" || return 1
}

test_artifact_builder_rejects_linked_helper_archive() {
  malicious_archive="$TEST_ROOT/malicious-helper.zip"
  python3 - "$malicious_archive" <<'PY'
import stat
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    info = zipfile.ZipInfo("link")
    info.create_system = 3
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive.writestr(info, "/outside")
PY
  digest="$(sha256 "$BOOTSTRAP")"
  output="$(bash "$PROJECT_DIR/script/build_release_artifacts.sh" \
    --product-version "0.3.0" \
    --bootstrap-version "1.0.0-fixture" \
    --bootstrap "$BOOTSTRAP" \
    --bootstrap-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/bootstrap.sh" \
    --bootstrap-sha256 "$digest" \
    --manifest-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/manifest.json" \
    --helper-archive "$malicious_archive" \
    --helper-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/Mac-Orchestrator-arm64.zip" \
    --helper-sha256 "$(sha256 "$malicious_archive")" \
    --uv "$BOOTSTRAP" \
    --uv-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/uv-arm64" \
    --uv-sha256 "$digest" \
    --core-payload "$BOOTSTRAP" \
    --core-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/core-payload.tar.gz" \
    --core-sha256 "$digest" \
    --lock "$BOOTSTRAP" \
    --lock-sha256 "$digest" \
    --ngrok-archive "$BOOTSTRAP" \
    --ngrok-version "3.39.10" \
    --ngrok-url "https://bin.equinox.io/a/b/ngrok.zip" \
    --ngrok-sha256 "$digest" \
    --ngrok-authority "Developer ID Application: ngrok, Inc. (TEAMFIX123)" \
    --ngrok-team "TEAMFIX123" \
    --output-dir "$TEST_ROOT/builder-linked-helper" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || return 1
  assert_contains "$output" "non-regular" || return 1
}

make_minimal_signed_helper_archive() {
  helper_root="$TEST_ROOT/minimal-helper"
  helper_app="$helper_root/Mac Orchestrator.app"
  helper_archive="$TEST_ROOT/minimal-helper.zip"
  /bin/mkdir -p "$helper_app/Contents/MacOS" || return 1
  /bin/cp /usr/bin/true "$helper_app/Contents/MacOS/MacOrchestrator" || return 1
  printf '%s\n' '{"CFBundleIdentifier":"com.jay.mac-orchestrator","CFBundleShortVersionString":"0.3.0","CFBundleExecutable":"MacOrchestrator"}' \
    > "$helper_app/Contents/Info.plist" || return 1
  /usr/bin/plutil -convert xml1 "$helper_app/Contents/Info.plist" || return 1
  /usr/bin/codesign --force --deep --sign - "$helper_app" >/dev/null 2>&1 || return 1
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$helper_app" "$helper_archive" >/dev/null 2>&1 || return 1
}

run_builder_with_core_archive() {
  core_archive="$1"
  output_dir="$2"
  helper_archive="$3"
  digest="$(sha256 "$BOOTSTRAP")" || return 1
  BUILDER_OUTPUT="$(bash "$PROJECT_DIR/script/build_release_artifacts.sh" \
    --product-version "0.3.0" \
    --bootstrap-version "1.0.0-fixture" \
    --bootstrap "$BOOTSTRAP" \
    --bootstrap-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/bootstrap.sh" \
    --bootstrap-sha256 "$digest" \
    --manifest-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/manifest.json" \
    --helper-archive "$helper_archive" \
    --helper-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/Mac-Orchestrator-arm64.zip" \
    --helper-sha256 "$(sha256 "$helper_archive")" \
    --uv "$BOOTSTRAP" \
    --uv-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/uv-arm64" \
    --uv-sha256 "$digest" \
    --core-payload "$core_archive" \
    --core-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/core-payload.tar.gz" \
    --core-sha256 "$(sha256 "$core_archive")" \
    --lock "$BOOTSTRAP" \
    --lock-sha256 "$digest" \
    --ngrok-archive "$BOOTSTRAP" \
    --ngrok-version "3.39.10" \
    --ngrok-url "https://bin.equinox.io/a/b/ngrok.zip" \
    --ngrok-sha256 "$digest" \
    --ngrok-authority "Developer ID Application: ngrok, Inc. (TEAMFIX123)" \
    --ngrok-team "TEAMFIX123" \
    --output-dir "$output_dir" 2>&1)"
  BUILDER_RC=$?
}

test_artifact_builder_rejects_core_boundary_extra() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  make_minimal_signed_helper_archive || return 1
  core_source="$TEST_ROOT/core-extra-source"
  core_archive="$TEST_ROOT/core-extra.tar.gz"
  /bin/mkdir -p "$core_source" || return 1
  printf '%s\n' 'core' > "$core_source/automac_mcp.py"
  printf '%s\n' 'core' > "$core_source/pyproject.toml"
  printf '%s\n' 'lock' > "$core_source/uv.lock"
  printf '%s\n' 'unexpected' > "$core_source/extra.txt"
  /usr/bin/tar -czf "$core_archive" -C "$core_source" automac_mcp.py pyproject.toml uv.lock extra.txt || return 1
  run_builder_with_core_archive "$core_archive" "$TEST_ROOT/builder-core-extra" "$TEST_ROOT/minimal-helper.zip" || return 1
  [ "$BUILDER_RC" -ne 0 ] || return 1
  assert_contains "$BUILDER_OUTPUT" "core payload contains files outside the declared core boundary" || return 1
}

test_artifact_builder_rejects_core_special_entry() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  make_minimal_signed_helper_archive || return 1
  core_source="$TEST_ROOT/core-special-source"
  core_archive="$TEST_ROOT/core-special.tar.gz"
  /bin/mkdir -p "$core_source" || return 1
  printf '%s\n' 'core' > "$core_source/automac_mcp.py"
  printf '%s\n' 'core' > "$core_source/pyproject.toml"
  printf '%s\n' 'lock' > "$core_source/uv.lock"
  /usr/bin/mkfifo "$core_source/unsafe-fifo" || return 1
  /usr/bin/tar -czf "$core_archive" -C "$core_source" automac_mcp.py pyproject.toml uv.lock unsafe-fifo 2>/dev/null || return 1
  run_builder_with_core_archive "$core_archive" "$TEST_ROOT/builder-core-special" "$TEST_ROOT/minimal-helper.zip" || return 1
  [ "$BUILDER_RC" -ne 0 ] || return 1
  assert_contains "$BUILDER_OUTPUT" "archive contains a non-regular entry" || return 1
}

test_generated_install_command_contains_all_trust_anchors() {
  command_output="$TEST_ROOT/install-command.txt"
  output="$(bash "$PROJECT_DIR/script/generate_install_command.sh" \
    --product-version "0.3.0" \
    --bootstrap-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/bootstrap.sh" \
    --bootstrap-sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    --manifest-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/manifest.json" \
    --manifest-sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    --output "$command_output" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || { echo "$output" >&2; return 1; }
  assert_file "$command_output" || return 1
  command_text="$(/bin/cat "$command_output")" || return 1
  assert_contains "$command_text" "v0.3.0" || return 1
  assert_contains "$command_text" "releases/download/v0.3.0/bootstrap.sh" || return 1
  assert_contains "$command_text" "releases/download/v0.3.0/manifest.json" || return 1
  assert_contains "$command_text" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" || return 1
  assert_contains "$command_text" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" || return 1
  assert_contains "$command_text" "manifest-sha256" || return 1
  assert_not_contains "$command_text" "REPLACE_WITH" || return 1
  assert_not_contains "$command_text" "refs/heads/main" || return 1
}

test_generated_release_body_contains_pinned_install_command() {
  body_output="$TEST_ROOT/release-body.md"
  output="$(bash "$PROJECT_DIR/script/generate_install_command.sh" \
    --product-version "0.3.0" \
    --bootstrap-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/bootstrap.sh" \
    --bootstrap-sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    --manifest-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/manifest.json" \
    --manifest-sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    --output "$TEST_ROOT/install-command-body.sh" \
    --release-body "$body_output" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || { echo "$output" >&2; return 1; }
  assert_file "$body_output" || return 1
  body_text="$(/bin/cat "$body_output")" || return 1
  assert_contains "$body_text" "releases/download/v0.3.0/bootstrap.sh" || return 1
  assert_contains "$body_text" "releases/download/v0.3.0/manifest.json" || return 1
  assert_contains "$body_text" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" || return 1
  assert_contains "$body_text" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" || return 1
  assert_contains "$body_text" "shasum -a 256 -c -" || return 1
  assert_contains "$body_text" 'bash "$tmp_bootstrap"' || return 1
  assert_contains "$body_text" $'bash "$tmp_bootstrap" \\\n    --manifest' || return 1
  verification_line="$(printf '%s\n' "$body_text" | /usr/bin/awk '/shasum -a 256 -c -/{print NR; exit}')"
  execution_line="$(printf '%s\n' "$body_text" | /usr/bin/awk '/bash "\$tmp_bootstrap"/{print NR; exit}')"
  [ -n "$verification_line" ] && [ -n "$execution_line" ] || return 1
  [ "$verification_line" -lt "$execution_line" ] || return 1
}

test_generated_release_body_changes_with_manifest_digest() {
  first_body="$TEST_ROOT/release-body-first.md"
  second_body="$TEST_ROOT/release-body-second.md"
  first_manifest="$TEST_ROOT/manifest-first.json"
  second_manifest="$TEST_ROOT/manifest-second.json"
  printf '%s\n' '{"product":{"version":"0.3.0"},"marker":"first"}' > "$first_manifest"
  printf '%s\n' '{"product":{"version":"0.3.0"},"marker":"second"}' > "$second_manifest"
  first_manifest_sha="$(sha256 "$first_manifest")" || return 1
  second_manifest_sha="$(sha256 "$second_manifest")" || return 1
  [ "$first_manifest_sha" != "$second_manifest_sha" ] || return 1
  common_args=(
    --product-version "0.3.0"
    --bootstrap-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/bootstrap.sh"
    --bootstrap-sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    --manifest-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/manifest.json"
    --output "$TEST_ROOT/install-command-first.sh"
  )
  bash "$PROJECT_DIR/script/generate_install_command.sh" "${common_args[@]}" \
    --manifest-sha256 "$first_manifest_sha" \
    --release-body "$first_body" >/dev/null || return 1
  common_args[9]="$TEST_ROOT/install-command-second.sh"
  bash "$PROJECT_DIR/script/generate_install_command.sh" "${common_args[@]}" \
    --manifest-sha256 "$second_manifest_sha" \
    --release-body "$second_body" >/dev/null || return 1
  first_text="$(/bin/cat "$first_body")" || return 1
  second_text="$(/bin/cat "$second_body")" || return 1
  [ "$first_text" != "$second_text" ] || return 1
  assert_contains "$first_text" "$first_manifest_sha" || return 1
  assert_contains "$second_text" "$second_manifest_sha" || return 1
}

test_release_body_rejects_untrusted_inputs() {
  mutable_branch="main"
  output="$(bash "$PROJECT_DIR/script/generate_install_command.sh" \
    --product-version "0.3.0" \
    --bootstrap-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/bootstrap.sh" \
    --bootstrap-sha256 "0000000000000000000000000000000000000000000000000000000000000000" \
    --manifest-url "https://github.com/Jay-2212/mac-orchestrator/releases/refs/heads/$mutable_branch/manifest.json" \
    --manifest-sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    --output "$TEST_ROOT/install-command-untrusted.sh" \
    --release-body "$TEST_ROOT/release-body-untrusted.md" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || return 1
  assert_contains "$output" "must not be all zeroes" || return 1

  output="$(bash "$PROJECT_DIR/script/generate_install_command.sh" \
    --product-version "0.3.0" \
    --bootstrap-url "https://github.com/Jay-2212/mac-orchestrator/releases/download/v0.3.0/bootstrap.sh" \
    --bootstrap-sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    --manifest-url "https://github.com/Jay-2212/mac-orchestrator/releases/refs/heads/$mutable_branch/manifest.json" \
    --manifest-sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    --output "$TEST_ROOT/install-command-mutable.sh" \
    --release-body "$TEST_ROOT/release-body-mutable.md" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || return 1
  assert_contains "$output" "immutable GitHub release asset URL" || return 1
}

test_release_publication_consumes_generated_body() {
  builder_contents="$(/bin/cat "$PROJECT_DIR/script/build_release_artifacts.sh")" || return 1
  release_contents="$(/bin/cat "$PROJECT_DIR/.github/workflows/release.yml")" || return 1
  assert_contains "$builder_contents" "--release-body" || return 1
  assert_contains "$builder_contents" "release-body.md" || return 1
  assert_contains "$release_contents" "release-body.md" || return 1
  assert_contains "$release_contents" '--notes "$release_notes"' || return 1
  assert_contains "$release_contents" "--generate-notes" || return 1
}

test_manifest_signature_uses_external_key_and_raw_bytes() {
  manifest="$TEST_ROOT/signature-manifest.json"
  key="$TEST_ROOT/fixture-signing-key.pem"
  signature="$TEST_ROOT/manifest.sig"
  printf '%s\n' '{"raw":"manifest"}' > "$manifest"
  openssl genpkey -algorithm ED25519 -out "$key" >/dev/null 2>&1 || return 1
  output="$(bash "$PROJECT_DIR/script/sign_release_manifest.sh" \
    --manifest "$manifest" \
    --private-key "$key" \
    --key-id fixture-v1 \
    --output "$signature" 2>&1)" || { echo "$output" >&2; return 1; }
  python3 - "$signature" "$TEST_ROOT/signature.bin" <<'PY'
import base64
import json
import pathlib
import sys

envelope = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert envelope["schemaVersion"] == 1
assert envelope["algorithm"] == "ed25519"
assert envelope["keyID"] == "fixture-v1"
pathlib.Path(sys.argv[2]).write_bytes(base64.b64decode(envelope["signature"], validate=True))
PY
  openssl pkey -in "$key" -pubout -out "$TEST_ROOT/fixture-signing-key.pub" >/dev/null 2>&1 || return 1
  if openssl pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
    openssl pkeyutl -verify -rawin -pubin -inkey "$TEST_ROOT/fixture-signing-key.pub" \
      -in "$manifest" -sigfile "$TEST_ROOT/signature.bin" >/dev/null 2>&1 || return 1
  else
    openssl pkeyutl -verify -pubin -inkey "$TEST_ROOT/fixture-signing-key.pub" \
      -in "$manifest" -sigfile "$TEST_ROOT/signature.bin" >/dev/null 2>&1 || return 1
  fi
  output="$(bash "$PROJECT_DIR/script/sign_release_manifest.sh" \
    --manifest "$manifest" \
    --private-key "$PROJECT_DIR/script/bootstrap.sh" \
    --key-id fixture-v1 \
    --output "$TEST_ROOT/rejected.sig" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || return 1
  assert_contains "$output" "outside the repository" || return 1
}

test_package_app_helper_contract() {
  package_contents="$(/bin/cat "$PROJECT_DIR/script/package_app.sh")" || return 1
  assert_contains "$package_contents" "arm64" || return 1
  assert_contains "$package_contents" "codesign --verify --deep --strict" || return 1
  assert_contains "$package_contents" "Signature=adhoc" || return 1
  assert_not_contains "$package_contents" "NGROK_SOURCE" || return 1
  assert_not_contains "$package_contents" "Resources_DIR/ngrok" || return 1
  assert_not_contains "$package_contents" 'codesign --force --sign "$CODESIGN_IDENTITY"' || return 1
}

test_release_output_does_not_redistribute_ngrok() {
  builder_contents="$(/bin/cat "$PROJECT_DIR/script/build_release_artifacts.sh")" || return 1
  release_contents="$(/bin/cat "$PROJECT_DIR/.github/workflows/release.yml")" || return 1
  assert_not_contains "$builder_contents" 'OUTPUT_DIR/ngrok-arm64.zip' || return 1
  assert_not_contains "$release_contents" 'release-assets/ngrok-arm64.zip' || return 1
  assert_contains "$release_contents" 'bin.equinox.io' || return 1
}

test_bootstrap_completion_is_activation_gated() {
  bootstrap_contents="$(/bin/cat "$PROJECT_DIR/script/bootstrap.sh")" || return 1
  assert_contains "$bootstrap_contents" "--wait-for-local-activation" || return 1
  assert_contains "$bootstrap_contents" "local-activation-confirmed" || return 1
  assert_contains "$bootstrap_contents" "remote-activation-confirmed" || return 1
}

test_activation_timeout_guidance_refers_to_installed_helper() {
  terminal_contents="$(/bin/cat "$PROJECT_DIR/Sources/MacOrchestrator/TerminalCommand.swift")" || return 1
  assert_contains "$terminal_contents" "the installed helper remains in place" || return 1
  assert_not_contains "$terminal_contents" "the previous installation remains in place" || return 1
}

run_test() {
  test_name="$1"
  shift
  if "$@"; then
    echo "ok - $test_name"
  else
    echo "not ok - $test_name"
    FAILURES=$((FAILURES + 1))
  fi
}

if [ ! -f "$BOOTSTRAP" ]; then
  echo "not ok - bootstrap script exists"
  echo "missing: $BOOTSTRAP" >&2
  exit 1
fi
if [ ! -f "$TEMPLATE" ]; then
  echo "not ok - manifest template exists"
  echo "missing: $TEMPLATE" >&2
  exit 1
fi
select_test_plutil || exit 1

run_test "valid manifest acceptance" test_valid_manifest_acceptance
run_test "missing digest rejection" test_missing_digest_rejected
run_test "sentinel digest rejection" test_sentinel_digest_rejected
run_test "wrong digest rejection" test_wrong_digest_rejected
run_test "manifest digest rejection before use" test_manifest_digest_rejected_before_manifest_use
run_test "bootstrap digest rejection before execution" test_bootstrap_digest_rejected_before_execution
run_test "modified core payload rejection" test_modified_core_payload_rejected
run_test "ngrok zip format requirement" test_ngrok_zip_format_required
run_test "mutable release URL rejection" test_mutable_release_url_rejected
run_test "non-vendor ngrok URL rejection" test_non_vendor_ngrok_url_rejected
run_test "unsupported architecture rejection" test_unsupported_architecture_rejected
run_test "minimum macOS rejection" test_old_macos_rejected
run_test "repeat promotion is idempotent" test_repeat_promotion_is_idempotent
run_test "failed download preserves previous state" test_failed_download_preserves_previous_state
run_test "interrupted promotion recovers previous runtime" test_interrupted_promotion_recovers_previous_runtime
run_test "pre-commit failure recovers previous installation" test_pre_commit_failure_recovers_previous_installation
run_test "structural failure after promotion recovers previous installation" test_structural_failure_after_promotion_recovers_previous_installation
run_test "LaunchAgent failure before commit recovers previous installation" test_launch_agent_failure_before_commit_recovers_previous_installation
run_test "onboarding failure after install commit preserves new installation" test_onboarding_failure_after_install_commit_preserves_new_installation
run_test "requested remote failure preserves local installation" test_requested_remote_failure_after_install_commit_preserves_local_installation
run_test "requested remote success path remains available" test_requested_remote_success_path_remains_available
run_test "next run recovers promotion marker" test_next_run_recovers_promotion_marker
run_test "symlinked support root is rejected" test_symlinked_support_root_rejected
run_test "symlinked support parent is rejected" test_symlinked_support_parent_rejected
run_test "symlinked managed Python directory is rejected" test_symlinked_managed_python_directory_rejected
run_test "malformed promotion marker fails closed" test_malformed_promotion_marker_fails_closed
run_test "missing recovery backup fails closed" test_missing_recovery_backup_fails_closed
run_test "unmoved backups marker recovers" test_backups_marker_with_unmoved_previous_paths_recovers
run_test "promotion marker symlink is rejected" test_promotion_marker_symlink_rejected
run_test "artifact builder requires release inputs" test_artifact_builder_requires_release_inputs
run_test "artifact builder rejects non-vendor ngrok URL" test_artifact_builder_rejects_non_vendor_ngrok_url
run_test "artifact builder rejects linked helper archive" test_artifact_builder_rejects_linked_helper_archive
run_test "artifact builder rejects undeclared core file" test_artifact_builder_rejects_core_boundary_extra
run_test "artifact builder rejects core special entry" test_artifact_builder_rejects_core_special_entry
run_test "generated install command contains trust anchors" test_generated_install_command_contains_all_trust_anchors
run_test "generated release body contains pinned install command" test_generated_release_body_contains_pinned_install_command
run_test "generated release body changes with manifest digest" test_generated_release_body_changes_with_manifest_digest
run_test "release body rejects untrusted inputs" test_release_body_rejects_untrusted_inputs
run_test "release publication consumes generated body" test_release_publication_consumes_generated_body
run_test "manifest signature uses external key and raw bytes" test_manifest_signature_uses_external_key_and_raw_bytes
run_test "package helper contract" test_package_app_helper_contract
run_test "release output does not redistribute ngrok" test_release_output_does_not_redistribute_ngrok
run_test "bootstrap completion waits for activation" test_bootstrap_completion_is_activation_gated
run_test "activation timeout guidance names installed helper" test_activation_timeout_guidance_refers_to_installed_helper

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES bootstrap fixture test(s) failed" >&2
  exit 1
fi
echo "all bootstrap fixture tests passed"
