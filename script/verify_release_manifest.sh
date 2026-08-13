#!/usr/bin/env bash
set -euo pipefail

OPENSSL_BIN="${OPENSSL_BIN:-$(command -v openssl || true)}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
SWIFT_BIN="${SWIFT_BIN:-$(command -v swift || true)}"
MANIFEST_PATH=""
SIGNATURE_PATH=""
PUBLIC_KEY_PATH=""
KEY_ID=""

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --manifest) (($# >= 2)) || die "missing value for --manifest"; MANIFEST_PATH="$2"; shift 2 ;;
    --signature) (($# >= 2)) || die "missing value for --signature"; SIGNATURE_PATH="$2"; shift 2 ;;
    --public-key) (($# >= 2)) || die "missing value for --public-key"; PUBLIC_KEY_PATH="$2"; shift 2 ;;
    --key-id) (($# >= 2)) || die "missing value for --key-id"; KEY_ID="$2"; shift 2 ;;
    --help|-h)
      printf '%s\n' 'Usage: verify_release_manifest.sh --manifest PATH --signature PATH --public-key PATH --key-id ID'
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$OPENSSL_BIN" ] || die "openssl is required to verify release manifests"
[ -n "$PYTHON_BIN" ] || die "python3 is required to decode the signature envelope"
[ -n "$SWIFT_BIN" ] || die "swift is required when the system OpenSSL cannot verify Ed25519"
[ -f "$MANIFEST_PATH" ] || die "manifest is not a file"
[ -f "$SIGNATURE_PATH" ] || die "signature is not a file"
[ -f "$PUBLIC_KEY_PATH" ] || die "public key is not a file"
[ -n "$KEY_ID" ] || die "a manifest signing key ID is required"

temporary_dir="$(mktemp -d -t mac-orchestrator-verify)"
trap 'rm -f "$temporary_dir/signature.bin" "$temporary_dir/public.der"' EXIT

"$PYTHON_BIN" - "$SIGNATURE_PATH" "$KEY_ID" "$temporary_dir/signature.bin" <<'PY'
import base64
import json
import pathlib
import sys

signature_path, expected_key_id, output_path = sys.argv[1:]
envelope = json.loads(pathlib.Path(signature_path).read_text(encoding="utf-8"))
if set(envelope) != {"algorithm", "keyID", "schemaVersion", "signature"}:
    raise SystemExit("invalid signature envelope fields")
if envelope["algorithm"] != "ed25519" or envelope["schemaVersion"] != 1:
    raise SystemExit("invalid signature envelope metadata")
if envelope["keyID"] != expected_key_id:
    raise SystemExit("unexpected signature key ID")
pathlib.Path(output_path).write_bytes(base64.b64decode(envelope["signature"], validate=True))
PY

"$PYTHON_BIN" - "$PUBLIC_KEY_PATH" "$temporary_dir/public.der" <<'PY' ||
import base64
import pathlib
import sys

source, destination = sys.argv[1:]
text = pathlib.Path(source).read_text(encoding="utf-8")
begin = "-----BEGIN PUBLIC KEY-----"
end = "-----END PUBLIC KEY-----"
if begin not in text or end not in text:
    raise SystemExit("unsupported public key PEM")
body = text.split(begin, 1)[1].split(end, 1)[0]
pathlib.Path(destination).write_bytes(base64.b64decode("".join(body.split()), validate=True))
PY
  die "Ed25519 public key conversion failed"

if "$OPENSSL_BIN" pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
  "$OPENSSL_BIN" pkeyutl -verify -rawin -pubin -inkey "$PUBLIC_KEY_PATH" \
    -in "$MANIFEST_PATH" -sigfile "$temporary_dir/signature.bin" >/dev/null \
    || die "Ed25519 signature verification failed"
else
  "$SWIFT_BIN" - "$MANIFEST_PATH" "$temporary_dir/public.der" "$temporary_dir/signature.bin" <<'SWIFT' ||
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else { exit(2) }
let manifest = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let der = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
let signature = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
let prefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
guard der.count == 44, der.prefix(prefix.count) == prefix else { exit(3) }
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(der.suffix(32)))
guard publicKey.isValidSignature(signature, for: manifest) else { exit(4) }
SWIFT
    die "Ed25519 signature verification failed"
fi
