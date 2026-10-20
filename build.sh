#!/usr/bin/env bash
# Vercel build: download Godot (headless) + web export templates, export to ./build
set -euo pipefail

GODOT_VERSION="4.3"
GODOT_TAG="${GODOT_VERSION}-stable"
ROOT="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$ROOT/.tools"
BASE="https://github.com/godotengine/godot/releases/download/${GODOT_TAG}"
GODOT_BIN="$TOOLS/Godot_v${GODOT_TAG}_linux.x86_64"
export XDG_DATA_HOME="$TOOLS/data"
TEMPLATE_DIR="$XDG_DATA_HOME/godot/export_templates/${GODOT_VERSION}.stable"
FONT_URL="https://github.com/notofonts/noto-cjk/raw/main/Sans/SubsetOTF/KR/NotoSansKR-Bold.otf"

mkdir -p "$TOOLS" "$TEMPLATE_DIR" "$ROOT/fonts"
touch "$TOOLS/.gdignore"

# extract ZIP MEMBER DEST_DIR  (python3, falling back to unzip)
extract() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" "$2" "$3" <<'PY'
import os, shutil, sys, zipfile
zp, member, dest = sys.argv[1:4]
with zipfile.ZipFile(zp) as z, z.open(member) as src, open(os.path.join(dest, os.path.basename(member)), "wb") as out:
    shutil.copyfileobj(src, out)
PY
  elif command -v unzip >/dev/null 2>&1; then
    unzip -o -j -q "$1" "$2" -d "$3"
  else
    echo "Need python3 or unzip to extract $1" >&2
    exit 1
  fi
}

if [ ! -x "$GODOT_BIN" ]; then
  echo "==> Downloading Godot ${GODOT_TAG}"
  curl -fL --retry 3 -o "$TOOLS/godot.zip" "$BASE/Godot_v${GODOT_TAG}_linux.x86_64.zip"
  extract "$TOOLS/godot.zip" "Godot_v${GODOT_TAG}_linux.x86_64" "$TOOLS"
  chmod +x "$GODOT_BIN"
  rm -f "$TOOLS/godot.zip"
fi

if [ ! -f "$TEMPLATE_DIR/web_nothreads_release.zip" ]; then
  echo "==> Downloading export templates (~1GB)"
  curl -fL --retry 3 -o "$TOOLS/templates.tpz" "$BASE/Godot_v${GODOT_TAG}_export_templates.tpz"
  extract "$TOOLS/templates.tpz" "templates/web_nothreads_release.zip" "$TEMPLATE_DIR"
  extract "$TOOLS/templates.tpz" "templates/version.txt" "$TEMPLATE_DIR"
  rm -f "$TOOLS/templates.tpz"
fi

if [ ! -f "$ROOT/fonts/NotoSansKR-Bold.otf" ]; then
  echo "==> Downloading Korean font"
  curl -fL --retry 3 -o "$ROOT/fonts/NotoSansKR-Bold.otf" "$FONT_URL"
fi

rm -rf "$ROOT/build"
mkdir -p "$ROOT/build"
touch "$ROOT/build/.gdignore"

echo "==> Importing project"
"$GODOT_BIN" --headless --path "$ROOT" --import || true

echo "==> Exporting web build"
"$GODOT_BIN" --headless --path "$ROOT" --export-release "Web" "$ROOT/build/index.html"

rm -f "$ROOT/build/.gdignore"
if [ ! -f "$ROOT/build/index.wasm" ] || [ ! -f "$ROOT/build/index.pck" ]; then
  echo "Export failed: build/index.wasm or index.pck missing" >&2
  exit 1
fi
ls -la "$ROOT/build"
