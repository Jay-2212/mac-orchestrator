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
    '    load(args[-1])' \
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
  printf '%s\n' 'fixture-ngrok-archive' > "$CASE_DIR/assets/ngrok.tar.gz"
  printf '%s\n' 'fixture-lock' > "$CASE_DIR/assets/uv.lock"

  printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "arm64"' > "$CASE_DIR/bin/uname"
  printf '%s\n' '#!/bin/bash' 'printf "%s\\n" "13.6.1"' > "$CASE_DIR/bin/sw_vers"
  /bin/chmod 755 "$CASE_DIR/bin/uname" "$CASE_DIR/bin/sw_vers"

  MANIFEST="$CASE_DIR/manifest.json"
  /bin/cp "$TEMPLATE" "$MANIFEST" || return 1

  helper_path="$CASE_DIR/assets/helper.zip"
  uv_path="$CASE_DIR/assets/uv"
  core_path="$CASE_DIR/assets/core.tar.gz"
  ngrok_path="$CASE_DIR/assets/ngrok.tar.gz"
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
  BOOTSTRAP_OUTPUT="$(
    /usr/bin/env \
      MAC_ORCHESTRATOR_MANIFEST_PATH="$case_dir/manifest.json" \
      MAC_ORCHESTRATOR_SUPPORT_DIR="$case_dir/support" \
      MAC_ORCHESTRATOR_FIXTURE_MODE=1 \
      MAC_ORCHESTRATOR_FIXTURE_LOCK_PATH="$case_dir/assets/uv.lock" \
      MAC_ORCHESTRATOR_UNAME_BIN="$case_dir/bin/uname" \
      MAC_ORCHESTRATOR_SW_VERS_BIN="$case_dir/bin/sw_vers" \
      PLUTIL_BIN="$TEST_PLUTIL_BIN" \
      PATH="$ORIGINAL_PATH" \
      bash "$BOOTSTRAP" "$@" 2>&1
  )"
  BOOTSTRAP_RC=$?
}

capture_bootstrap_with_env() {
  case_dir="$1"
  env_name="$2"
  shift 2
  BOOTSTRAP_OUTPUT="$(
    /usr/bin/env \
      MAC_ORCHESTRATOR_MANIFEST_PATH="$case_dir/manifest.json" \
      MAC_ORCHESTRATOR_SUPPORT_DIR="$case_dir/support" \
      MAC_ORCHESTRATOR_FIXTURE_MODE=1 \
      MAC_ORCHESTRATOR_FIXTURE_LOCK_PATH="$case_dir/assets/uv.lock" \
      MAC_ORCHESTRATOR_UNAME_BIN="$case_dir/bin/uname" \
      MAC_ORCHESTRATOR_SW_VERS_BIN="$case_dir/bin/sw_vers" \
      PLUTIL_BIN="$TEST_PLUTIL_BIN" \
      "$env_name"=1 \
      PATH="$ORIGINAL_PATH" \
      bash "$BOOTSTRAP" "$@" 2>&1
  )"
  BOOTSTRAP_RC=$?
}

test_valid_manifest_acceptance() {
  make_case valid || return 1
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -eq 0 ] || { echo "$BOOTSTRAP_OUTPUT" >&2; return 1; }
  assert_contains "$BOOTSTRAP_OUTPUT" "manifest-validated" || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "platform-validated" || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "digests-verified" || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "promoted" || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "complete" || return 1
  assert_not_contains "$BOOTSTRAP_OUTPUT" "$CASE_DIR" || return 1
}

test_missing_digest_rejected() {
  make_case missing-digest || return 1
  replace_string helper.sha256 "REPLACE_WITH_SHA256" "$MANIFEST" || return 1
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "helper digest" || return 1
}

test_wrong_digest_rejected() {
  make_case wrong-digest || return 1
  replace_string helper.sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$MANIFEST" || return 1
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "digest mismatch" || return 1
}

test_mutable_release_url_rejected() {
  make_case mutable-url || return 1
  replace_string helper.url "https://downloads.example.com/releases/refs/heads/main/helper.zip" "$MANIFEST" || return 1
  capture_bootstrap "$CASE_DIR"
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_contains "$BOOTSTRAP_OUTPUT" "immutable" || return 1
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
  /bin/mkdir -p "$CASE_DIR/support/runtime" "$CASE_DIR/support/install"
  printf '%s\n' 'previous-runtime' > "$CASE_DIR/support/runtime/.release-marker"
  capture_bootstrap_with_env "$CASE_DIR" MAC_ORCHESTRATOR_TEST_FAIL_AFTER_PROMOTION
  [ "$BOOTSTRAP_RC" -ne 0 ] || return 1
  assert_content "$CASE_DIR/support/runtime/.release-marker" "previous-runtime" || return 1
  if [ -e "$CASE_DIR/support/install/promotion.marker" ]; then
    fail "promotion marker survived trapped recovery"
  fi
}

test_next_run_recovers_promotion_marker() {
  make_case next-run-recovery || return 1
  /bin/mkdir -p "$CASE_DIR/support/runtime" "$CASE_DIR/support/install/runtime.previous"
  printf '%s\n' 'interrupted-runtime' > "$CASE_DIR/support/runtime/.release-marker"
  printf '%s\n' 'previous-runtime' > "$CASE_DIR/support/install/runtime.previous/.release-marker"
  printf '%s\n' 'had_previous=1' > "$CASE_DIR/support/install/promotion.marker"
  capture_bootstrap_with_env "$CASE_DIR" MAC_ORCHESTRATOR_TEST_EXIT_AFTER_RECOVERY
  [ "$BOOTSTRAP_RC" -eq 0 ] || { echo "$BOOTSTRAP_OUTPUT" >&2; return 1; }
  assert_content "$CASE_DIR/support/runtime/.release-marker" "previous-runtime" || return 1
  if [ -e "$CASE_DIR/support/install/promotion.marker" ]; then
    fail "promotion marker was not cleared on next run"
  fi
}

test_artifact_builder_requires_release_inputs() {
  output="$(bash "$PROJECT_DIR/script/build_release_artifacts.sh" --output-dir "$TEST_ROOT/builder-output" 2>&1)"
  rc=$?
  [ "$rc" -ne 0 ] || return 1
  assert_contains "$output" "required" || return 1
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
run_test "wrong digest rejection" test_wrong_digest_rejected
run_test "mutable release URL rejection" test_mutable_release_url_rejected
run_test "unsupported architecture rejection" test_unsupported_architecture_rejected
run_test "minimum macOS rejection" test_old_macos_rejected
run_test "repeat promotion is idempotent" test_repeat_promotion_is_idempotent
run_test "failed download preserves previous state" test_failed_download_preserves_previous_state
run_test "interrupted promotion recovers previous runtime" test_interrupted_promotion_recovers_previous_runtime
run_test "next run recovers promotion marker" test_next_run_recovers_promotion_marker
run_test "artifact builder requires release inputs" test_artifact_builder_requires_release_inputs
run_test "package helper contract" test_package_app_helper_contract

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES bootstrap fixture test(s) failed" >&2
  exit 1
fi
echo "all bootstrap fixture tests passed"
