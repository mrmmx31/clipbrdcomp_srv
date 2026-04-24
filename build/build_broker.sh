#!/usr/bin/env bash
# build_broker.sh — Compila o broker ClipBrdComp no Linux
# Requer: fpc 3.2.x, libsqlite3-dev
#
# Uso: ./build/build_broker.sh [debug|release]
#
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BROKER_DIR="$ROOT/broker"
PROTOCOL_DIR="$ROOT/protocol"
COMPAT_DIR="$ROOT/compat"
OUT_DIR="$ROOT/bin"

MODE="${1:-release}"
mkdir -p "$OUT_DIR"

echo "=== Building broker (mode=$MODE) ==="
echo "  Root:     $ROOT"
echo "  Protocol: $PROTOCOL_DIR"
echo "  Compat:   $COMPAT_DIR"
echo ""

# Verifica dependências
if ! command -v fpc &>/dev/null; then
  echo "ERROR: fpc not found. Install: sudo apt install fpc"
  exit 1
fi

MISSING_SQLITE=1
if command -v ldconfig &>/dev/null; then
  if ldconfig -p 2>/dev/null | grep -q libsqlite3; then
    MISSING_SQLITE=0
  fi
else
  # fallback: check pkg-config or common include/lib paths
  if command -v pkg-config &>/dev/null && pkg-config --exists sqlite3 2>/dev/null; then
    MISSING_SQLITE=0
  elif [ -f /usr/include/sqlite3.h ] || [ -f /usr/include/sqlite3/sqlite3.h ] || [ -f /usr/lib/x86_64-linux-gnu/libsqlite3.so ] || [ -f /usr/lib/libsqlite3.so ]; then
    MISSING_SQLITE=0
  fi
fi

if [ "$MISSING_SQLITE" -ne 0 ]; then
  echo "ERROR: libsqlite3 not found. Install: sudo apt install libsqlite3-dev"
  exit 1
fi

FPC_FLAGS=(
  -Fu"$PROTOCOL_DIR"
  -Fu"$COMPAT_DIR"
  -Fu"$BROKER_DIR"
  -FE"$OUT_DIR"
  -FU"$BROKER_DIR/lib"
)

if [ "$MODE" = "debug" ]; then
  FPC_FLAGS+=(-g -gl -gh -dDEBUG)
else
  FPC_FLAGS+=(-O2 -Xs -XX)
fi

# SQLite: linka dinamicamente com libsqlite3 do sistema
# (broker_db.pas já inclui {$LinkLib sqlite3})

cd "$BROKER_DIR"
# Note: fpc expects -o<file> without space, so use -o"$OUT_DIR/clipbrd_broker"
fpc "${FPC_FLAGS[@]}" clipbrd_broker.lpr -o"$OUT_DIR/clipbrd_broker"

echo ""
echo "=== Build OK ==="
echo "  Binary: $OUT_DIR/clipbrd_broker"
echo ""
echo "Run with:"
echo "  $OUT_DIR/clipbrd_broker --config /etc/clipbrdcomp/broker.ini"
echo ""
echo "Generate default config:"
echo "  $OUT_DIR/clipbrd_broker --gen-config broker.ini"
