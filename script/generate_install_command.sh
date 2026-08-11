#!/usr/bin/env bash
set -euo pipefail

PRODUCT_VERSION=""
BOOTSTRAP_URL=""
BOOTSTRAP_SHA256=""
MANIFEST_URL=""
MANIFEST_SHA256=""
OUTPUT_PATH=""

usage() {
  cat <<'EOF'
Usage: generate_install_command.sh --product-version VERSION --bootstrap-url URL \
  --bootstrap-sha256 SHA256 --manifest-url URL --manifest-sha256 SHA256 --output PATH
EOF
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

require_hex_digest() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9a-fA-F]{64}$ ]] || die "$label must be a 64-character SHA-256 digest"
  [[ ! "$value" =~ ^0{64}$ ]] || die "$label must not be all zeroes"
}

require_release_url() {
  local label="$1"
  local value="$2"
  local suffix="$3"
  [[ "$value" == "https://github.com/Jay-2212/mac-orchestrator/releases/download/v${PRODUCT_VERSION}/${suffix}" ]] || \
    die "$label must be the immutable GitHub release asset URL for v${PRODUCT_VERSION}"
}

while (($# > 0)); do
  case "$1" in
    --product-version)
      (($# >= 2)) || die "--product-version requires a value"
      PRODUCT_VERSION="$2"
      shift 2
      ;;
    --bootstrap-url)
      (($# >= 2)) || die "--bootstrap-url requires a value"
      BOOTSTRAP_URL="$2"
      shift 2
      ;;
    --bootstrap-sha256)
      (($# >= 2)) || die "--bootstrap-sha256 requires a value"
      BOOTSTRAP_SHA256="$2"
      shift 2
      ;;
    --manifest-url)
      (($# >= 2)) || die "--manifest-url requires a value"
      MANIFEST_URL="$2"
      shift 2
      ;;
    --manifest-sha256)
      (($# >= 2)) || die "--manifest-sha256 requires a value"
      MANIFEST_SHA256="$2"
      shift 2
      ;;
    --output)
      (($# >= 2)) || die "--output requires a value"
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "$PRODUCT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "invalid product version"
[[ -n "$OUTPUT_PATH" ]] || die "--output is required"
require_hex_digest "bootstrap SHA-256" "$BOOTSTRAP_SHA256"
require_hex_digest "manifest SHA-256" "$MANIFEST_SHA256"
require_release_url "bootstrap URL" "$BOOTSTRAP_URL" "bootstrap.sh"
require_release_url "manifest URL" "$MANIFEST_URL" "manifest.json"

output_dir="$(dirname "$OUTPUT_PATH")"
mkdir -p "$output_dir"
tmp_path="$(mktemp "${OUTPUT_PATH}.tmp.XXXXXX")" || die "could not create a temporary install command"
trap 'rm -f "$tmp_path"' EXIT

cat > "$tmp_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

bootstrap_url='$BOOTSTRAP_URL'
bootstrap_sha256='$BOOTSTRAP_SHA256'
manifest_url='$MANIFEST_URL'
manifest_sha256='$MANIFEST_SHA256'
release_version='$PRODUCT_VERSION'

tmp_bootstrap="\$(mktemp -t mac-orchestrator-bootstrap.XXXXXX)"
trap 'rm -f "\$tmp_bootstrap"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error "\$bootstrap_url" -o "\$tmp_bootstrap"
printf '%s  %s\n' "\$bootstrap_sha256" "\$tmp_bootstrap" | shasum -a 256 -c - >/dev/null
chmod 700 "\$tmp_bootstrap"
bash "\$tmp_bootstrap" \\
  --manifest "\$manifest_url" \\
  --manifest-sha256 "\$manifest_sha256" \\
  --bootstrap-sha256 "\$bootstrap_sha256" \\
  --release-version "\$release_version" "\$@"
status=\$?
exit "\$status"
EOF
chmod 755 "$tmp_path"
mv "$tmp_path" "$OUTPUT_PATH"
trap - EXIT
printf '%s\n' "$OUTPUT_PATH"
