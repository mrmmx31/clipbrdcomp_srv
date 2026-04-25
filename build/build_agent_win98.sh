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

# Determine which FPC to use: prefer native cross-compiler, else try wine + fpc.exe
FPC_EXEC=()
if fpc -Pi386 -Twin32 -v0 2>&1 | grep -qi "free pascal"; then
  FPC_EXEC=(fpc)
else
  if command -v wine >/dev/null 2>&1; then
    # Allow the user to override the wine FPC path via env var
    if [ -n "${WINE_FPC_PATH:-}" ]; then
      FPC_EXE="$WINE_FPC_PATH"
    else
      # Try to find a fpc.exe under the default wine prefix
      FPC_EXE="$(find "$HOME/.wine/drive_c" -type f -iname 'fpc.exe' -path '*bin*' 2>/dev/null | head -n 1 || true)"
      if [ -z "$FPC_EXE" ]; then
        FPC_EXE="$(find "$HOME/.wine/drive_c" -type f -iname 'fpc.exe' 2>/dev/null | head -n 1 || true)"
      fi
    fi

    if [ -n "$FPC_EXE" ]; then
      echo "INFO: Using wine FPC at: $FPC_EXE"
      FPC_EXEC=(wine "$FPC_EXE")
    else
      echo "ERROR: native FPC cross-compiler not found and no wine FPC discovered."
      echo "Set WINE_FPC_PATH to the path to fpc.exe inside your wine prefix (e.g. $HOME/.wine/drive_c/fpc/<ver>/bin/i386-win32/fpc.exe)"
      exit 1
    fi
  else
    echo "ERROR: FPC i386-win32 cross-compiler not available and 'wine' not installed."
    echo "On Debian/Ubuntu, install native cross compiler:"
    echo "  sudo apt install fpc-i386    # or fpc-cross"
    exit 1
  fi
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

# If using wine's fpc, try converting paths with winepath when available
if [ "${FPC_EXEC[0]:-}" = "wine" ]; then
  if command -v winepath >/dev/null 2>&1; then
    CONVERTED_FLAGS=()
    for arg in "${FPC_FLAGS[@]}"; do
      case "$arg" in
        -Fu*|-FE*|-FU*)
          prefix="${arg:0:3}"
          pathpart="${arg:3}"
          winpath="$(winepath -w "$pathpart" 2>/dev/null || echo "$pathpart")"
          CONVERTED_FLAGS+=("${prefix}${winpath}")
          ;;
        *)
          CONVERTED_FLAGS+=("$arg")
          ;;
      esac
    done
    # Add FPC units directories (i386-win32) to search path so windows units (e.g., IniFiles) are found
    if [ -n "${FPC_EXE:-}" ]; then
      # FPC_EXE may be .../bin/i386-win32/fpc.exe — step up 3 levels to reach fpc root
      FPC_ROOT_DIR="$(dirname "$(dirname "$(dirname "$FPC_EXE")")")"
      UNITS_DIR="$FPC_ROOT_DIR/units/i386-win32"
      if [ -d "$UNITS_DIR" ]; then
        UNIT_FLAGS=()
        for sub in "$UNITS_DIR"/*; do
          if [ -d "$sub" ]; then
            winsub="$(winepath -w "$sub" 2>/dev/null || echo "$sub")"
            UNIT_FLAGS+=("-Fu${winsub}")
          fi
        done
        # Prepend unit search paths so system units are found before project paths
        CONVERTED_FLAGS=("${UNIT_FLAGS[@]}" "${CONVERTED_FLAGS[@]}")
      fi
    fi
    WIN_OUT="$(winepath -w "$OUT_DIR/clipbrd_agent_w98.exe" 2>/dev/null || echo "$OUT_DIR/clipbrd_agent_w98.exe")"
    SRC_WIN="$(winepath -w "$(pwd)/clipbrd_agent_w98.lpr" 2>/dev/null || echo "$(pwd)/clipbrd_agent_w98.lpr")"
    # Some Windows FPC drivers expect the -o flag fused with the filename
    "${FPC_EXEC[@]}" "${CONVERTED_FLAGS[@]}" "$SRC_WIN" "-o$WIN_OUT"
  else
    echo "INFO: 'winepath' not found — passing Linux paths to wine fpc (may still work)."
    "${FPC_EXEC[@]}" "${FPC_FLAGS[@]}" clipbrd_agent_w98.lpr "-o$OUT_DIR/clipbrd_agent_w98.exe"
  fi
else
  # Native fpc
  "${FPC_EXEC[@]}" "${FPC_FLAGS[@]}" clipbrd_agent_w98.lpr -o "$OUT_DIR/clipbrd_agent_w98.exe"
fi

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
