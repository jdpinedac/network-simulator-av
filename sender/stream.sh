#!/bin/bash
# ============================================================
# stream.sh - Generador de stream de video y audio
# Conferencia: "Hackeando la Señal" - AVIXA 2026
#
# Genera un stream MPEG-TS sobre UDP con:
#   - Video: barras SMPTE + ruido + reloj + frame counter (modo defecto)
#          O video real desde archivo (si INPUT_VIDEO está definido)
#   - Audio: chirp sweep 300-1000Hz (modo defecto) — glitches muy audibles
#          O pista de audio del archivo (si INPUT_VIDEO tiene audio)
#
# NOTA TÉCNICA - ¿Por qué ruido y all-I-frames?
#   El contenido SMPTE estático es tan predecible que H.264 lo codifica
#   a ~500kbps (en vez de 4000k) con P-frames vacíos. Perder un P-frame
#   vacío no produce macroblocks visibles. El filtro noise= añade entropía
#   (data real en cada pixel), y -g 1 fuerza I-frames independientes.
#   Resultado: 4200kbps reales, 16 paquetes/frame, pérdida MUY visible.
# ============================================================

RECEIVER_IP="${RECEIVER_IP:-172.28.0.20}"
RECEIVER_PORT="${RECEIVER_PORT:-5004}"
RESOLUTION="${RESOLUTION:-1280x720}"
FRAMERATE="${FRAMERATE:-25}"
VIDEO_BITRATE="${VIDEO_BITRATE:-4000k}"
AUDIO_FREQ="${AUDIO_FREQ:-1000}"

# Modo de audio: "tone" (tono fijo 1kHz, defecto) o "sweep" (chirp 300-1000Hz)
# El sweep cambia frecuencia continuamente → cualquier corte produce un click audible.
# Con tono fijo los cortes son más sutiles pero es la señal de prueba estándar.
AUDIO_MODE="${AUDIO_MODE:-tone}"

# GOP para video real: keyframes cada N frames.
# Mayor valor = artefactos más prolongados con video real.
# SMPTE siempre usa -g 1 (all I-frames) para máxima visibilidad.
GOP="${GOP:-60}"

# Fuente de video alternativa (opcional):
# Si INPUT_VIDEO apunta a un archivo de video, se usa en lugar de SMPTE.
# Ejemplo: INPUT_VIDEO=/videos/mi_video.mp4
INPUT_VIDEO="${INPUT_VIDEO:-}"

FONT="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

# Separar resolución en ancho/alto para filtros de escala
SCALE_W="${RESOLUTION%x*}"   # "1280"
SCALE_H="${RESOLUTION#*x}"   # "720"

# ============================================================
# Audio: señal de prueba configurable
# ============================================================
#   "sweep" (defecto): chirp 300→1000Hz, ciclo 3 segundos.
#     La frecuencia cambia en cada muestra → un paquete perdido
#     produce un "click" audible por la discontinuidad de fase.
#   "tone": tono fijo (1kHz por defecto) — señal monótona,
#     los cortes son sutiles y difíciles de percibir.
case "$AUDIO_MODE" in
    tone)
        AUDIO_FILTER="sine=frequency=${AUDIO_FREQ}:sample_rate=48000"
        AUDIO_DESC="Tono fijo ${AUDIO_FREQ}Hz"
        ;;
    *)
        AUDIO_FILTER="aevalsrc=sin(2*PI*t*(300+350*(1+sin(2*PI*t/3)))):s=48000"
        AUDIO_DESC="Chirp sweep 300-1000Hz (3s)"
        ;;
esac

echo ""
echo "=============================================="
echo "  SIMULADOR AV - AVIXA 2026"
echo "  Hackeando la Señal"
echo "=============================================="
echo ""
echo "  Destino : udp://$RECEIVER_IP:$RECEIVER_PORT"
echo "  Video   : $RESOLUTION @ ${FRAMERATE}fps  $VIDEO_BITRATE"
if [ -n "$INPUT_VIDEO" ] && [ -f "$INPUT_VIDEO" ]; then
    # Detectar si el archivo tiene pista de audio
    HAS_FILE_AUDIO=$(ffprobe -loglevel quiet -select_streams a \
        -show_entries stream=codec_type -of csv=p=0 "$INPUT_VIDEO" 2>/dev/null | head -1)
    if [ "$HAS_FILE_AUDIO" = "audio" ]; then
        echo "  Audio   : pista del archivo (voz/música → degradación muy evidente)"
    else
        echo "  Audio   : $AUDIO_DESC (archivo sin audio)"
    fi
    echo "  Fuente  : ARCHIVO: $INPUT_VIDEO"
    echo "  GOP     : ${GOP} frames (I-frame cada $(echo "scale=1; ${GOP} / ${FRAMERATE}" | bc)s)"
else
    echo "  Audio   : $AUDIO_DESC"
    echo "  Fuente  : SMPTE HD Bars + noise (all I-frames)"
    echo "  GOP     : 1 (cada frame es I-frame independiente)"
fi
echo ""
echo "  Presiona Ctrl+C para detener"
echo "----------------------------------------------"
echo ""

# ============================================================
# Filtros de texto superpuesto (comunes a ambos modos de video)
# ============================================================
#   - Reloj en tiempo real (visible el paso del tiempo)
#   - Contador de frames (confirma que el stream está vivo)
#   - Banner inferior con IPs origen/destino
OVERLAY_FILTERS="
  drawtext=fontfile=${FONT}:text='%{localtime\\:%H\\:%M\\:%S}':fontsize=64:fontcolor=white:x=(w-text_w)/2:y=30:box=1:boxcolor=black@0.6:boxborderw=8,
  drawtext=fontfile=${FONT}:text='FRAME %{n}':fontsize=36:fontcolor=yellow:x=20:y=110:box=1:boxcolor=black@0.6:boxborderw=6,
  drawtext=fontfile=${FONT}:text='SRC 172.28.0.10  >>  DST 172.28.0.20':fontsize=28:fontcolor=cyan:x=(w-text_w)/2:y=h-60:box=1:boxcolor=black@0.7:boxborderw=6"

# Destino UDP
UDP_OUT="udp://${RECEIVER_IP}:${RECEIVER_PORT}?pkt_size=1316&buffer_size=65536"

# ============================================================
# Modo A: Video real desde archivo
# ============================================================
if [ -n "$INPUT_VIDEO" ] && [ -f "$INPUT_VIDEO" ]; then

    # Escalar respetando aspect ratio, rellenar con negro, superponer texto.
    FILE_VIDEO_FILTER="scale=${SCALE_W}:${SCALE_H}:force_original_aspect_ratio=decrease,\
pad=${SCALE_W}:${SCALE_H}:(ow-iw)/2:(oh-ih)/2,setsar=1,${OVERLAY_FILTERS}"

    # Si el archivo tiene audio, usarlo directamente (voz/música = degradación
    # muy evidente). Si no, usar la señal de audio generada (sweep/tone).
    if [ "$HAS_FILE_AUDIO" = "audio" ]; then
        exec ffmpeg -hide_banner \
          -re -stream_loop -1 -i "$INPUT_VIDEO" \
          -filter_complex "[0:v]${FILE_VIDEO_FILTER}[vout]" \
          -map "[vout]" \
          -map "0:a" \
          -c:v libx264 \
            -preset ultrafast \
            -tune zerolatency \
            -g "${GOP}" \
            -keyint_min "${GOP}" \
            -sc_threshold 0 \
            -b:v "${VIDEO_BITRATE}" \
            -maxrate "${VIDEO_BITRATE}" \
            -bufsize 2000k \
            -pix_fmt yuv420p \
          -c:a aac \
            -b:a 128k \
            -ar 48000 \
          -f mpegts \
          -mpegts_flags resend_headers \
          "${UDP_OUT}"
    else
        exec ffmpeg -hide_banner \
          -re -stream_loop -1 -i "$INPUT_VIDEO" \
          -f lavfi -i "${AUDIO_FILTER}" \
          -filter_complex "[0:v]${FILE_VIDEO_FILTER}[vout]" \
          -map "[vout]" \
          -map "1:a" \
          -c:v libx264 \
            -preset ultrafast \
            -tune zerolatency \
            -g "${GOP}" \
            -keyint_min "${GOP}" \
            -sc_threshold 0 \
            -b:v "${VIDEO_BITRATE}" \
            -maxrate "${VIDEO_BITRATE}" \
            -bufsize 2000k \
            -pix_fmt yuv420p \
          -c:a aac \
            -b:a 128k \
            -ar 48000 \
          -f mpegts \
          -mpegts_flags resend_headers \
          "${UDP_OUT}"
    fi

# ============================================================
# Modo B: SMPTE HD Bars + noise (modo por defecto)
#
#   noise=alls=20:allf=t+u  → añade ruido temporal a cada pixel
#                              cada frame es distinto → P-frames
#                              llevarían data real (pero usamos -g 1)
#   -g 1                    → ALL I-FRAMES: cada frame es independiente.
#                              Perder cualquier paquete = macroblock visible.
#   -maxrate -bufsize       → VBV CBR forzado: mantiene 4000kbps
#                              (sin esto, H.264 ABR generaba solo 500kbps)
# ============================================================
else

    # El ruido se aplica ANTES de los drawtext para que el texto sea legible
    VIDEO_FILTER="
      smptehdbars=size=${RESOLUTION}:rate=${FRAMERATE},
      noise=alls=20:allf=t+u,
      ${OVERLAY_FILTERS}"

    # -re: rate-limit a velocidad real (25fps). Sin esto, lavfi genera
    #      a máxima velocidad (~21x) → 94 Mbps en vez de 4 Mbps en red.
    exec ffmpeg -hide_banner \
      -re -f lavfi -i "${VIDEO_FILTER}" \
      -f lavfi -i "${AUDIO_FILTER}" \
      -c:v libx264 \
        -preset ultrafast \
        -tune zerolatency \
        -g 1 \
        -keyint_min 1 \
        -sc_threshold 0 \
        -b:v "${VIDEO_BITRATE}" \
        -maxrate "${VIDEO_BITRATE}" \
        -bufsize 2000k \
        -pix_fmt yuv420p \
      -c:a aac \
        -b:a 128k \
        -ar 48000 \
      -f mpegts \
      -mpegts_flags resend_headers \
      "${UDP_OUT}"

fi
