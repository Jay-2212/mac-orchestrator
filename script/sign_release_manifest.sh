#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENSSL_BIN="${OPENSSL_BIN:-$(command -v openssl || true)}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
SWIFT_BIN="${SWIFT_BIN:-$(command -v swift || true)}"
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
[ -n "$SWIFT_BIN" ] || die "swift is required when the system OpenSSL cannot sign Ed25519"
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
trap 'rm -f "$temporary_dir/signature.bin" "$temporary_dir/envelope.json" "$temporary_dir/private.der"' EXIT

if "$OPENSSL_BIN" pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
  # OpenSSL 3 exposes -rawin; the flag makes the detached signature cover the
  # manifest bytes directly instead of a digest.
  "$OPENSSL_BIN" pkeyutl -sign -rawin -inkey "$PRIVATE_KEY_PATH" \
    -in "$MANIFEST_PATH" -out "$temporary_dir/signature.bin" ||
    die "Ed25519 signing failed"
else
  # macOS's system LibreSSL has no raw-input flag and may not implement
  # Ed25519 pkeyutl signing. Convert the external PKCS#8 key to DER, then use
  # CryptoKit for the detached signature over the exact manifest bytes.
  "$PYTHON_BIN" - "$PRIVATE_KEY_PATH" "$temporary_dir/private.der" <<'PY' ||
import base64
import pathlib
import sys

source, destination = sys.argv[1:]
text = pathlib.Path(source).read_text(encoding="utf-8")
begin = "-----BEGIN " + "PRIVATE KEY-----"
end = "-----END " + "PRIVATE KEY-----"
if begin not in text or end not in text:
    raise SystemExit("unsupported private key PEM")
body = text.split(begin, 1)[1].split(end, 1)[0]
pathlib.Path(destination).write_bytes(base64.b64decode("".join(body.split()), validate=True))
PY
    die "Ed25519 private key conversion failed"
  "$SWIFT_BIN" - "$MANIFEST_PATH" "$temporary_dir/private.der" "$temporary_dir/signature.bin" <<'SWIFT' ||
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else { exit(2) }
let manifest = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let der = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
let prefix = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20])
guard der.count == 48, der.prefix(prefix.count) == prefix else { exit(3) }
let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(der.suffix(32)))
try privateKey.signature(for: manifest).write(to: URL(fileURLWithPath: arguments[3]), options: [.atomic])
SWIFT
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
