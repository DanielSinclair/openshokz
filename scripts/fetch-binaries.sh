#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${ROOT}/OpenShokz/Resources/Binaries"
mkdir -p "${DEST}"

echo "→ Fetching ffmpeg (Martin Riedl static builds, universal arm64 + x86_64)…"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

curl -fsSL \
  "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip" \
  -o "${TMP}/ffmpeg-arm64.zip"
curl -fsSL \
  "https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release/ffmpeg.zip" \
  -o "${TMP}/ffmpeg-amd64.zip"

unzip -qo "${TMP}/ffmpeg-arm64.zip" -d "${TMP}/arm64"
unzip -qo "${TMP}/ffmpeg-amd64.zip" -d "${TMP}/amd64"

lipo -create \
  -output "${DEST}/ffmpeg" \
  "${TMP}/arm64/ffmpeg" \
  "${TMP}/amd64/ffmpeg"
chmod +x "${DEST}/ffmpeg"

# Codesign rejects resource forks / quarantine xattrs on bundle resources
find "${DEST}" -type f -exec xattr -c {} \;
dot_clean -m "${DEST}" 2>/dev/null || true

# Adhoc-sign so nested tools aren't flagged as unsigned in the bundle
if command -v codesign >/dev/null; then
  codesign --force --sign - "${DEST}/ffmpeg" 2>/dev/null || true
fi

echo "→ Verifying…"
lipo -info "${DEST}/ffmpeg"
arch -arch arm64 "${DEST}/ffmpeg" -version | head -1
arch -arch x86_64 "${DEST}/ffmpeg" -version | head -1
echo "✓ Binaries ready in ${DEST}"
