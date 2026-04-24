#!/usr/bin/env bash
# build_agent_win98.sh — Cross-compila o agente Win98 a partir do Linux
# Gera um .exe compatível com Windows 98 (i386-win32).
#
# Requer: FPC com suporte ao target i386-win32
#   sudo apt install fpc-cross  (Debian/Ubuntu)
#   ou instale manualmente a partir de https://freepascal.org
#
# Uso: ./build/build_agent_win98.sh [debug|release]
#
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_DIR="$ROOT/agent/win98"
PROTOCOL_DIR="$ROOT/protocol"
COMPAT_DIR="$ROOT/compat"
OUT_DIR="$ROOT/bin"

MODE="${1:-release}"
mkdir -p "$OUT_DIR"

echo "=== Building Win98 agent (cross-compile i386-win32, mode=$MODE) ==="

# Verifica se fpc suporta o target Win32
if ! fpc -Pi386 -Twin32 -v0 2>&1 | grep -qi "free pascal"; then
  echo "ERROR: FPC i386-win32 cross-compiler not available."
  echo ""
  echo "On Debian/Ubuntu, install with:"
  echo "  sudo apt install fpc-i386"
  echo "  or"
  echo "  sudo apt install fpc-cross"
  echo ""
  echo "Alternatively, compile natively on Windows with FPC."
  exit 1
fi

FPC_FLAGS=(
  -Pi386          # target CPU: Intel 386 (i386 = Win98 compatible)
  -Twin32         # target OS: Win32
  -WG             # GUI application (no console window — usar -WC para console)
  -Fu"$PROTOCOL_DIR"
  -Fu"$COMPAT_DIR"
  -Fu"$AGENT_DIR"
  -FE"$OUT_DIR"
  -FU"$AGENT_DIR/lib_w98"
)

if [ "$MODE" = "debug" ]; then
  FPC_FLAGS+=(-g -dDEBUG)
else
  FPC_FLAGS+=(-O2 -Xs -XX)
fi

mkdir -p "$AGENT_DIR/lib_w98"
cd "$AGENT_DIR"

fpc "${FPC_FLAGS[@]}" clipbrd_agent_w98.lpr -o "$OUT_DIR/clipbrd_agent_w98.exe"

echo ""
echo "=== Build OK ==="
echo "  Binary: $OUT_DIR/clipbrd_agent_w98.exe"
echo ""
echo "Deploy to Win98 machine:"
echo "  1. Copie clipbrd_agent_w98.exe para a máquina Win98"
echo "  2. Copie config/agent_win98.ini.example como agent_win98.ini no mesmo dir"
echo "  3. Edite agent_win98.ini com o IP do broker e o auth_token"
echo "  4. Execute clipbrd_agent_w98.exe"
echo ""
echo "NOTA: O agente Win98 requer:"
echo "  - TCP/IP instalado (Control Panel > Network)"
echo "  - Windows 98 SE recomendado (melhor suporte Winsock)"
