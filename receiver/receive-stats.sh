#!/bin/bash
# ============================================================
# receive-stats.sh - Receptor con estadísticas (sin display X11)
# Útil para ver métricas del stream cuando no hay display
# ============================================================

LISTEN_PORT="${LISTEN_PORT:-5004}"

echo ""
echo "  Modo estadísticas (sin video) en puerto $LISTEN_PORT"
echo "  Presiona Ctrl+C para salir"
echo ""

ffmpeg -hide_banner \
  -fflags nobuffer \
  -flags low_delay \
  -i "udp://0.0.0.0:${LISTEN_PORT}?fifo_size=1000000&overrun_nonfatal=1" \
  -vf "fps=1" \
  -an \
  -f null \
  - \
  2>&1 | grep -E "(fps|bitrate|frame|drop|time=)"
