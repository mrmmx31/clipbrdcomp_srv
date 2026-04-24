#!/usr/bin/env bash
# build_agent_linux.sh — Compila o agente Linux via Lazarus (lazbuild)
# Requer: Lazarus IDE + lazbuild no PATH, FPC 3.2.x
#         libgtk2-dev (ou o widgetset escolhido)
#
# Uso: ./build/build_agent_linux.sh [debug|release]
#
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_DIR="$ROOT/agent/linux"
OUT_DIR="$ROOT/bin"

MODE="${1:-release}"
mkdir -p "$OUT_DIR"

echo "=== Building Linux agent (mode=$MODE) ==="

if ! command -v lazbuild &>/dev/null; then
  echo "ERROR: lazbuild not found."
  echo "Install Lazarus: sudo apt install lazarus"
  echo "Or set PATH to include lazbuild location."
  exit 1
fi

BUILD_FLAG="--build-mode=Debug"
if [ "$MODE" = "release" ]; then
  BUILD_FLAG="--build-mode=Release"
fi

cd "$AGENT_DIR"
lazbuild \
  $BUILD_FLAG \
  --bm="$MODE" \
  --no-write-project \
  clipbrd_agent_linux.lpi

# Copia o binário para bin/
if [ -f "$AGENT_DIR/clipbrd_agent_linux" ]; then
  cp "$AGENT_DIR/clipbrd_agent_linux" "$OUT_DIR/"
  echo ""
  echo "=== Build OK ==="
  echo "  Binary: $OUT_DIR/clipbrd_agent_linux"
elif [ -f "$AGENT_DIR/lib/x86_64-linux/clipbrd_agent_linux" ]; then
  cp "$AGENT_DIR/lib/x86_64-linux/clipbrd_agent_linux" "$OUT_DIR/"
  echo ""
  echo "=== Build OK ==="
  echo "  Binary: $OUT_DIR/clipbrd_agent_linux"
else
  echo "Binary not found in expected location, check build output above."
  exit 1
fi

echo ""
echo "Config: cp config/agent_linux.ini.example ~/.config/clipbrdcomp/agent_linux.ini"
echo "Run:    $OUT_DIR/clipbrd_agent_linux"
