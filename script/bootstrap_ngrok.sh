#!/usr/bin/env bash
set -euo pipefail

# One-time helper: downloads the ngrok binary into pyngrok's default location
# (~/Library/Application Support/ngrok/) so package_app.sh can bundle it into
# the app. This does NOT start a tunnel and does NOT expose anything — it
# only fetches the binary. Public ingress is wired up later, at runtime, by
# the Swift supervisor's managed mode (see SECURITY.md).

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UV_BIN="${UV_BIN:-$(command -v uv || true)}"

if [[ -z "$UV_BIN" ]]; then
  echo "uv is required to run this script." >&2
  exit 1
fi

cd "$PROJECT_DIR"
"$UV_BIN" run python -c "
from pyngrok import ngrok
ngrok.install_ngrok()
print('ngrok binary installed.')
"
