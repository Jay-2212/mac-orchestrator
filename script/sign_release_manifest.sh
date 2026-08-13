#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENSSL_BIN="${OPENSSL_BIN:-$(command -v openssl || true)}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
MANIFEST_PATH=""
PRIVATE_KEY_PATH=""
KEY_ID=""
OUTPUT_PATH=""

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf '%s\n' 'Usage: sign_release_manifest.sh --manifest PATH --private-key PATH --key-id ID --output PATH' >&2
}

while (($# > 0)); do
  case "$1" in
    --manifest) (($# >= 2)) || { usage; exit 2; }; MANIFEST_PATH="$2"; shift 2 ;;
    --private-key) (($# >= 2)) || { usage; exit 2; }; PRIVATE_KEY_PATH="$2"; shift 2 ;;
    --key-id) (($# >= 2)) || { usage; exit 2; }; KEY_ID="$2"; shift 2 ;;
    --output) (($# >= 2)) || { usage; exit 2; }; OUTPUT_PATH="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[ -n "$OPENSSL_BIN" ] || die "openssl is required to sign release manifests"
[ -n "$PYTHON_BIN" ] || die "python3 is required to encode the signature envelope"
[ -f "$MANIFEST_PATH" ] || die "manifest is not a file"
[ -f "$PRIVATE_KEY_PATH" ] || die "external signing key is not a file"
[ -n "$KEY_ID" ] || die "a manifest signing key ID is required"
[ -n "$OUTPUT_PATH" ] || die "signature output path is required"
case "$PRIVATE_KEY_PATH" in
  "$PROJECT_DIR"/*) die "production signing private keys must be outside the repository" ;;
esac
key_directory="$(cd "$(dirname "$PRIVATE_KEY_PATH")" && pwd -P)"
key_absolute="$key_directory/$(basename "$PRIVATE_KEY_PATH")"
case "$key_absolute" in
  "$PROJECT_DIR"/*) die "production signing private keys must be outside the repository" ;;
esac
key_realpath="$($PYTHON_BIN -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$PRIVATE_KEY_PATH")"
case "$key_realpath" in
  "$PROJECT_DIR"/*) die "production signing private keys must be outside the repository" ;;
esac
case "$KEY_ID" in
  *[!A-Za-z0-9._-]*) die "manifest signing key ID contains unsafe characters" ;;
esac

output_dir="$(dirname "$OUTPUT_PATH")"
mkdir -p "$output_dir"
temporary_dir="$(mktemp -d -t mac-orchestrator-sign)"
trap 'rm -f "$temporary_dir/signature.bin" "$temporary_dir/envelope.json"' EXIT

if "$OPENSSL_BIN" pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
  # OpenSSL 3 exposes -rawin; the flag makes the detached signature cover the
  # manifest bytes directly instead of a digest.
  "$OPENSSL_BIN" pkeyutl -sign -rawin -inkey "$PRIVATE_KEY_PATH" \
    -in "$MANIFEST_PATH" -out "$temporary_dir/signature.bin" ||
    die "Ed25519 signing failed"
else
  # macOS's system LibreSSL performs Ed25519 pkeyutl operations on raw input
  # by default and does not recognize OpenSSL 3's -rawin option.
  "$OPENSSL_BIN" pkeyutl -sign -inkey "$PRIVATE_KEY_PATH" \
    -in "$MANIFEST_PATH" -out "$temporary_dir/signature.bin" ||
    die "Ed25519 signing failed"
fi

SIGNATURE_B64="$($PYTHON_BIN - "$temporary_dir/signature.bin" <<'PY'
import base64
import pathlib
import sys

print(base64.b64encode(pathlib.Path(sys.argv[1]).read_bytes()).decode("ascii"))
PY
)"

"$PYTHON_BIN" - "$KEY_ID" "$SIGNATURE_B64" "$temporary_dir/envelope.json" <<'PY'
import json
import pathlib
import sys

key_id, signature, output = sys.argv[1:]
envelope = {
    "algorithm": "ed25519",
    "keyID": key_id,
    "schemaVersion": 1,
    "signature": signature,
}
pathlib.Path(output).write_text(json.dumps(envelope, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY

chmod 600 "$temporary_dir/envelope.json"
mv "$temporary_dir/envelope.json" "$OUTPUT_PATH"
chmod 644 "$OUTPUT_PATH"
printf '%s\n' "$OUTPUT_PATH"
