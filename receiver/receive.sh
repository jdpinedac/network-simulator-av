#!/bin/bash
# ============================================================
# receive.sh - Receptor y visualizador del stream de video
# Conferencia: "Hackeando la Señal" - AVIXA 2026
#
# Muestra el stream UDP recibido usando FFplay.
# Los efectos de jitter y latencia son visibles:
#   - Congelamiento de frames (jitter alto)
#   - Bloques pixelados (pérdida de paquetes)
#   - Audio entrecortado (jitter en audio)
# ============================================================

LISTEN_PORT="${LISTEN_PORT:-5004}"

echo ""
echo "=============================================="
echo "  SIMULADOR AV - AVIXA 2026"
echo "  Hackeando la Señal - RECEPTOR"
echo "=============================================="
echo ""
echo "  Escuchando en: udp://0.0.0.0:$LISTEN_PORT"
echo "  Presiona Q en la ventana de video para salir"
echo "----------------------------------------------"
echo ""

# Verificar que DISPLAY esté configurado
if [ -z "$DISPLAY" ]; then
    echo "ERROR: Variable DISPLAY no configurada."
    echo "El host debe permitir conexiones X11:"
    echo "  xhost +local:docker"
    exit 1
fi

# FFplay con configuración de bajo buffer para mostrar
# los efectos del jitter en tiempo real:
#
#   -fflags nobuffer     : no buffer en el demuxer (SIN discardcorrupt para ver macroblocks)
#   -ec 0                : deshabilita error concealment → macroblocks visibles en pérdida
#   -flags low_delay     : bajo retardo en el decoder
#   -framedrop           : descarta frames tardíos (hace visible el jitter)
#   -sync ext            : no auto-sync (muestra desincronización real)
#   -probesize 1000000   : suficiente para detectar MPEG-TS (PAT/PMT)
#   -analyzeduration 1M  : análisis mínimo pero funcional
#
ffplay \
  -hide_banner \
  -loglevel warning \
  -nostats \
  -fflags nobuffer \
  -ec 0 \
  -flags low_delay \
  -framedrop \
  -probesize 1000000 \
  -analyzeduration 1000000 \
  -sync ext \
  -window_title "RECEPTOR: Video sobre IP | Demo Jitter/Latencia - AVIXA 2026" \
  -x 1280 -y 720 \
  "udp://0.0.0.0:${LISTEN_PORT}?buffer_size=65536&fifo_size=65536&overrun_nonfatal=1"
