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
#   -probesize 500000    : 500KB ≈ 1s de datos a 4Mbps. Suficiente para detectar
#                          tanto video (H.264) como audio (AAC a 128kbps).
#                          32KB era demasiado poco: solo ~62ms, no detectaba audio.
#   -analyzeduration 500000 : 0.5s de análisis — minimiza tiempo de reinicio
#
#   SIN -framedrop: FFplay con -framedrop descarta frames cuyo PTS es
#   "tardío" respecto al reloj de audio. Después de corrupción severa,
#   el PTS del video salta (discontinuidad) y TODOS los frames nuevos
#   parecen "tardíos" → el display se congela permanentemente aunque
#   el decodificador H.264 ya se recuperó (comprobado con conteo de
#   errores por segundo: 0 errores tras limpiar). Sin -framedrop,
#   FFplay muestra cada frame aunque llegue tarde → se ve la corrupción
#   durante el impairment Y la recuperación inmediata al limpiar.
#
#   SIN -sync ext: causaba el mismo problema de congelamiento.
#   Default audio sync: el audio gobierna el display y se recupera rápido.
#
#   fifo_size=2048       : buffer circular de ~5s (2048 paquetes / ~374 pkt/s).
#                          CRÍTICO: valores grandes (65536 = 175s) impiden la
#                          recuperación al limpiar impairments porque FFplay
#                          sigue leyendo datos corruptos del buffer viejo.
#
# LOOP DE REINICIO:
#   FFplay tiene colas internas de hasta 15MB (~30s de datos a 4Mbps) que
#   no se pueden controlar por línea de comandos. Después de corrupción
#   severa, estas colas se llenan de datos corruptos y FFplay los procesa
#   TODOS antes de llegar a datos limpios — causando errores persistentes
#   durante decenas de segundos incluso con la red limpia.
#
#   Solución: cuando demo-control.sh limpia impairments, mata FFplay
#   (pkill -f ffplay). Este loop detecta la terminación (código ≠ 0)
#   y reinicia FFplay con buffers y estado de decodificador limpios.
#   Cuando el usuario cierra FFplay con Q (código 0), el loop termina.
#
while true; do
    ffplay \
      -hide_banner \
      -loglevel warning \
      -nostats \
      -fflags nobuffer \
      -ec 0 \
      -flags low_delay \
      -probesize 500000 \
      -analyzeduration 500000 \
      -window_title "RECEPTOR: Video sobre IP | Demo Jitter/Latencia - AVIXA 2026" \
      -x 1280 -y 720 \
      "udp://0.0.0.0:${LISTEN_PORT}?buffer_size=65536&fifo_size=2048&overrun_nonfatal=1"

    EXIT_CODE=$?

    # Código 0 = usuario cerró FFplay (tecla Q). Terminar loop.
    if [ $EXIT_CODE -eq 0 ]; then
        echo "FFplay cerrado por el usuario."
        break
    fi

    # Código ≠ 0 = matado externamente (limpieza de impairments) o crash.
    # Reiniciar con buffers limpios. Pausa mínima para que el stream
    # UDP se estabilice antes de reconectar.
    echo "Reiniciando FFplay (código: $EXIT_CODE)..."
    sleep 0.3
done
