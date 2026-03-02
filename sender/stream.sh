#!/bin/bash
# ============================================================
# stream.sh - Generador de stream de video y audio
# Conferencia: "Hackeando la Señal" - AVIXA 2026
#
# Genera un stream MPEG-TS sobre UDP con:
#   - Video: barras SMPTE + reloj + contador de frames
#   - Audio: tono senoidal (facilita escuchar glitches)
# ============================================================

RECEIVER_IP="${RECEIVER_IP:-172.28.0.20}"
RECEIVER_PORT="${RECEIVER_PORT:-5004}"
RESOLUTION="${RESOLUTION:-1280x720}"
FRAMERATE="${FRAMERATE:-25}"
VIDEO_BITRATE="${VIDEO_BITRATE:-2000k}"
AUDIO_FREQ="${AUDIO_FREQ:-1000}"

FONT="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

echo ""
echo "=============================================="
echo "  SIMULADOR AV - AVIXA 2026"
echo "  Hackeando la Señal"
echo "=============================================="
echo ""
echo "  Destino : udp://$RECEIVER_IP:$RECEIVER_PORT"
echo "  Video   : $RESOLUTION @ ${FRAMERATE}fps  $VIDEO_BITRATE"
echo "  Audio   : tono $AUDIO_FREQ Hz"
echo ""
echo "  Presiona Ctrl+C para detener"
echo "----------------------------------------------"
echo ""

# Filtro de video compuesto:
#   - smptehdbars: barras de color SMPTE HD (fácil de ver degradación)
#   - drawtext 1: reloj del sistema (HH:MM:SS.mmm)
#   - drawtext 2: contador de frame
#   - drawtext 3: banner inferior (IP origen/destino)
VIDEO_FILTER="
  smptehdbars=size=${RESOLUTION}:rate=${FRAMERATE},
  drawtext=
    fontfile=${FONT}:
    text='%{localtime\\:%H\\:%M\\:%S}':
    fontsize=64:
    fontcolor=white:
    x=(w-text_w)/2:
    y=30:
    box=1:
    boxcolor=black@0.6:
    boxborderw=8,
  drawtext=
    fontfile=${FONT}:
    text='FRAME %{n}':
    fontsize=36:
    fontcolor=yellow:
    x=20:
    y=110:
    box=1:
    boxcolor=black@0.6:
    boxborderw=6,
  drawtext=
    fontfile=${FONT}:
    text='SRC 172.28.0.10  >>  DST 172.28.0.20':
    fontsize=28:
    fontcolor=cyan:
    x=(w-text_w)/2:
    y=h-60:
    box=1:
    boxcolor=black@0.7:
    boxborderw=6
"

# Audio: tono de 1kHz (los glitches se escuchan claramente)
AUDIO_FILTER="sine=frequency=${AUDIO_FREQ}:sample_rate=48000"

ffmpeg -hide_banner \
  -f lavfi -i "${VIDEO_FILTER}" \
  -f lavfi -i "${AUDIO_FILTER}" \
  -c:v libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -g ${FRAMERATE} \
    -keyint_min ${FRAMERATE} \
    -sc_threshold 0 \
    -b:v ${VIDEO_BITRATE} \
    -pix_fmt yuv420p \
  -c:a aac \
    -b:a 128k \
    -ar 48000 \
  -f mpegts \
  -mpegts_flags resend_headers \
  "udp://${RECEIVER_IP}:${RECEIVER_PORT}?pkt_size=1316&buffer_size=65536"
