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
PROTOCOL_DIR="$ROOT/protocol"
COMPAT_DIR="$ROOT/compat"

MODE="${1:-release}"
mkdir -p "$OUT_DIR"

echo "=== Building Linux agent (mode=$MODE) ==="

if ! command -v lazbuild &>/dev/null; then
  echo "ERROR: lazbuild not found."
  echo "Install Lazarus: sudo apt install lazarus"
  echo "Or set PATH to include lazbuild location."
  exit 1
fi

# Lazbuild: avoid passing an invalid build mode. Only pass --build-mode for debug.
LAZBUILD_OPTS=()
if [ "$MODE" = "debug" ]; then
  LAZBUILD_OPTS+=("--build-mode=Debug")
fi

cd "$AGENT_DIR"
if ! lazbuild "${LAZBUILD_OPTS[@]}" --no-write-project clipbrd_agent_linux.lpi; then
  echo "lazbuild failed — attempting direct fpc fallback build"
  FPC_FLAGS=( -MObjFPC -Scghi -Cg -Ci -O1 -gw3 -gl -l -vewnhibq -vm5024 )
  FPC_FLAGS+=( "-Fi$AGENT_DIR/lib/x86_64-linux" "-FU$AGENT_DIR/lib/x86_64-linux/" "-FE$AGENT_DIR/" "-Fu$AGENT_DIR" "-Fu$PROTOCOL_DIR" "-Fu$COMPAT_DIR" )
  for p in /usr/lib/lazarus/4.0/lcl/units/x86_64-linux/gtk2 /usr/lib/lazarus/4.0/lcl/units/x86_64-linux /usr/lib/lazarus/4.0/components/lazutils/lib/x86_64-linux /usr/lib/lazarus/4.0/packager/units/x86_64-linux /usr/lib/x86_64-linux-gnu/fpc/3.2.2/units/x86_64-linux/fcl-image; do
    if [ -d "$p" ]; then
      FPC_FLAGS+=( "-Fu$p" )
    fi
  done
  # Remove stale binary from agent dir so it doesn't shadow the fresh bin/ output below
  rm -f "$AGENT_DIR/clipbrd_agent_linux"
  # fpc expects -o attached (no space)
  fpc "${FPC_FLAGS[@]}" clipbrd_agent_linux.lpr -o"$OUT_DIR/clipbrd_agent_linux" || {
    echo "Fallback fpc build failed. Check that Lazarus/FPC and widgetset packages are installed.";
    exit 1;
  }
fi

# Copia o binário para bin/ (lazbuild coloca em $AGENT_DIR; fpc fallback coloca direto em $OUT_DIR)
if [ -f "$AGENT_DIR/clipbrd_agent_linux" ]; then
  cp "$AGENT_DIR/clipbrd_agent_linux" "$OUT_DIR/"
  rm -f "$AGENT_DIR/clipbrd_agent_linux"
fi

if [ -f "$OUT_DIR/clipbrd_agent_linux" ]; then
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
