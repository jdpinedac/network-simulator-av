#!/bin/bash
# ============================================================
# demo-control.sh - Control interactivo de la demo en vivo
#
# Conferencia: "Hackeando la Señal: La Verdad Oculta de la
#              Infraestructura de Video sobre IP"
# AVIXA 2026 | Juan David Pineda-Cárdenas
# ============================================================

SENDER="av_sender"
RECEIVER="av_receiver"

# PID del proceso terminal que lanzó FFplay (desde el host)
RECEIVER_DISPLAY_PID=""

# Colores para terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Estado actual de los impairments
CURRENT_DELAY=0
CURRENT_JITTER=0
CURRENT_LOSS=0
CURRENT_CORRUPT=0
CURRENT_SCENARIO="Sin impairments (Red Ideal)"

# Fuente de video para el stream
VIDEO_SOURCE_PATH=""              # vacío = SMPTE bars por defecto
CURRENT_VIDEO_SOURCE="SMPTE HD Bars"
CURRENT_AUDIO_MODE="tone"                 # tone o sweep
CURRENT_AUDIO_DESC="Tono fijo 1kHz"

# ============================================================
# Funciones de utilidad
# ============================================================

check_containers() {
    local sender_running receiver_running
    sender_running=$(docker inspect -f '{{.State.Running}}' "$SENDER" 2>/dev/null)
    receiver_running=$(docker inspect -f '{{.State.Running}}' "$RECEIVER" 2>/dev/null)

    if [ "$sender_running" != "true" ] || [ "$receiver_running" != "true" ]; then
        echo -e "${RED}ERROR: Los contenedores no están corriendo.${NC}"
        echo -e "Ejecuta primero: ${YELLOW}docker compose up -d${NC}"
        return 1
    fi
    return 0
}

apply_impairment() {
    local delay="$1"
    local jitter="$2"
    local loss="$3"
    local corrupt="$4"
    local scenario_name="$5"

    echo -e "\n${YELLOW}Aplicando: ${WHITE}$scenario_name${NC}"

    docker exec "$SENDER" /demo/apply-netem.sh apply "$delay" "$jitter" "$loss" "$corrupt" 2>&1

    # Si el nivel de pérdida/corrupción baja, reiniciar FFplay para vaciar
    # colas internas del decodificador (hasta 15MB / ~30s de datos corruptos).
    # Se hace DESPUÉS de aplicar netem para que FFplay reinicie con red limpia.
    if awk "BEGIN { exit !($CURRENT_LOSS > $loss || $CURRENT_CORRUPT > $corrupt) }"; then
        docker exec "$RECEIVER" pkill -f ffplay 2>/dev/null || true
        sleep 0.5
        echo -e "${CYAN}↻ Video reiniciado (vaciando buffer del nivel anterior)${NC}"
    fi

    CURRENT_DELAY=$delay
    CURRENT_JITTER=$jitter
    CURRENT_LOSS=$loss
    CURRENT_CORRUPT=$corrupt
    CURRENT_SCENARIO="$scenario_name"

    sleep 0.5
    echo -e "${GREEN}✓ Impairment aplicado. Observa el video...${NC}\n"
}

clear_impairments() {
    echo -e "\n${GREEN}Limpiando todos los impairments...${NC}"
    docker exec "$SENDER" /demo/apply-netem.sh clear 2>&1
    CURRENT_DELAY=0
    CURRENT_JITTER=0
    CURRENT_LOSS=0
    CURRENT_CORRUPT=0
    CURRENT_SCENARIO="Sin impairments (Red Ideal)"

    # Reiniciar FFplay para vaciar colas internas del decodificador.
    # FFplay acumula hasta 15MB (~30s) de datos corruptos en colas internas
    # que no se pueden limpiar externamente. Al matarlo, el loop en
    # receive.sh lo reinicia automáticamente con buffers limpios.
    docker exec "$RECEIVER" pkill -f ffplay 2>/dev/null || true

    echo -e "${GREEN}✓ Red limpia (video reiniciado)${NC}\n"
}

show_netem_status() {
    echo -e "\n${CYAN}=== Estado tc netem en sender (eth0) ===${NC}"
    docker exec "$SENDER" tc qdisc show dev eth0 2>&1
    echo ""
}

ping_test() {
    echo -e "\n${CYAN}=== Ping desde sender a receiver ===${NC}"
    echo -ne "  Cantidad de pings [10]: "
    read -r ping_count
    ping_count="${ping_count:-10}"
    echo ""
    docker exec "$SENDER" ping -c "$ping_count" 172.28.0.20 2>&1
    echo ""
}

iperf3_test() {
    echo -e "\n${CYAN}=== iperf3: Ancho de banda y calidad de red ===${NC}"

    # El default (4M) coincide con VIDEO_BITRATE del stream FFmpeg.
    # El usuario puede cambiarlo para simular otros escenarios de tráfico.
    echo -e "  ${WHITE}Ancho de banda del stream actual: 4 Mbps (VIDEO_BITRATE)${NC}"
    echo -ne "  Ancho de banda a simular en Mbps [4]: "
    read -r bw_input
    bw_input="${bw_input:-4}"

    echo -ne "  Duración en segundos [10]: "
    read -r duration
    duration="${duration:-10}"

    echo -e "\n${YELLOW}Ejecutando prueba UDP a ${bw_input} Mbps durante ${duration} segundos...${NC}\n"

    # iperf3 usa TCP para su canal de control. Con impairments severos
    # (>20% loss), el TCP puede fallar. Se reintenta hasta 3 veces.
    local attempt
    for attempt in 1 2 3; do
        docker exec "$RECEIVER" pkill -f iperf3 2>/dev/null || true
        docker exec "$SENDER" pkill -f iperf3 2>/dev/null || true
        sleep 1
        docker exec -d "$RECEIVER" iperf3 -s -1
        sleep 2

        if docker exec "$SENDER" iperf3 -c 172.28.0.20 -u -b "${bw_input}M" -t "$duration" --forceflush 2>&1; then
            echo ""
            return 0
        fi

        if [ "$attempt" -lt 3 ]; then
            echo -e "${YELLOW}  Reintentando (${attempt}/3)... el canal TCP de control fue afectado por los impairments${NC}"
        fi
    done

    echo -e "\n${RED}  La red está demasiado degradada para establecer el canal de control TCP de iperf3.${NC}"
    echo -e "${RED}  Esto confirma que la pérdida de paquetes actual es severa.${NC}"
    docker exec "$RECEIVER" pkill -f iperf3 2>/dev/null || true
    echo ""
}

start_streaming() {
    echo -e "\n${YELLOW}Iniciando streaming desde sender...${NC}"

    # Detener stream anterior si estaba corriendo
    docker exec "$SENDER" pkill -f stream.sh 2>/dev/null || true
    docker exec "$SENDER" pkill -f ffmpeg    2>/dev/null || true
    sleep 1

    echo -e "${CYAN}Fuente: ${WHITE}${CURRENT_VIDEO_SOURCE}${NC}"
    echo -e "${CYAN}El proceso corre en background del contenedor.${NC}\n"

    # Iniciar stream en background; pasar INPUT_VIDEO y AUDIO_MODE
    if [ -n "$VIDEO_SOURCE_PATH" ]; then
        docker exec -d \
            -e INPUT_VIDEO="$VIDEO_SOURCE_PATH" \
            -e AUDIO_MODE="$CURRENT_AUDIO_MODE" \
            "$SENDER" /demo/stream.sh
    else
        docker exec -d \
            -e AUDIO_MODE="$CURRENT_AUDIO_MODE" \
            "$SENDER" /demo/stream.sh
    fi
    sleep 2

    echo -e "${GREEN}✓ Stream iniciado${NC}"
    echo -e "El receiver ya está escuchando en: ${WHITE}udp://172.28.0.20:5004${NC}"
    echo ""
}

select_video_source() {
    echo ""
    echo -e "${CYAN}=== Selección de Fuente de Video ===${NC}"
    echo ""
    echo -e "${WHITE}  0.${NC} SMPTE HD Bars ${CYAN}(por defecto — barras de color estándar)${NC}"
    echo ""

    # Listar archivos de video disponibles en /videos/ dentro del contenedor
    local videos
    videos=$(docker exec "$SENDER" sh -c \
        'ls /videos/ 2>/dev/null | grep -iE "\.(mp4|mkv|mov|avi|ts|mpg|mpeg)$"' || true)

    if [ -z "$videos" ]; then
        echo -e "${YELLOW}  (No hay archivos de video en ./videos/ del host)${NC}"
        echo -e "  Copia archivos .mp4/.mkv/etc. al directorio ${WHITE}./videos/${NC} y reinicia los contenedores."
    else
        local i=1
        while IFS= read -r video; do
            echo -e "${WHITE}  ${i}.${NC} $video"
            i=$((i + 1))
        done <<< "$videos"
    fi

    echo ""
    echo -ne "Selecciona [0]: "
    read -r video_choice
    video_choice="${video_choice:-0}"

    # Descripción de audio según modo actual
    local audio_mode_desc
    if [ "$CURRENT_AUDIO_MODE" = "sweep" ]; then
        audio_mode_desc="Chirp sweep 300-1000Hz"
    else
        audio_mode_desc="Tono fijo 1kHz"
    fi

    if [ "$video_choice" = "0" ]; then
        VIDEO_SOURCE_PATH=""
        CURRENT_VIDEO_SOURCE="SMPTE HD Bars"
        CURRENT_AUDIO_DESC="$audio_mode_desc"
        echo -e "${GREEN}✓ Fuente seleccionada: SMPTE HD Bars${NC}"
    else
        local selected_file
        selected_file=$(echo "$videos" | sed -n "${video_choice}p")
        if [ -n "$selected_file" ]; then
            VIDEO_SOURCE_PATH="/videos/$selected_file"
            CURRENT_VIDEO_SOURCE="VIDEO: $selected_file"
            # Detectar si el archivo tiene audio
            local has_audio
            has_audio=$(docker exec "$SENDER" ffprobe -loglevel quiet -select_streams a \
                -show_entries stream=codec_type -of csv=p=0 "/videos/$selected_file" 2>/dev/null | head -1)
            if [ "$has_audio" = "audio" ]; then
                CURRENT_AUDIO_DESC="Audio del archivo (voz/música)"
            else
                CURRENT_AUDIO_DESC="$audio_mode_desc (archivo sin audio)"
            fi
            echo -e "${GREEN}✓ Fuente seleccionada: $selected_file${NC}"
            echo -e "${CYAN}  Audio: ${CURRENT_AUDIO_DESC}${NC}"
        else
            echo -e "${RED}Opción no válida. Se mantiene la fuente actual.${NC}"
        fi
    fi

    echo -e "\n${YELLOW}Usa la opción 's' para reiniciar el stream con la nueva fuente.${NC}"
    echo -ne "${YELLOW}Presiona Enter para continuar...${NC}"
    read -r
}

select_audio_mode() {
    echo ""
    echo -e "${CYAN}=== Selección de Modo de Audio ===${NC}"
    echo ""
    echo -e "${WHITE}  1.${NC} Chirp sweep 300-1000Hz ${CYAN}(recomendado — degradación muy evidente)${NC}"
    echo -e "     ${WHITE}Barrido de frecuencia continuo. Cualquier pérdida de paquetes${NC}"
    echo -e "     ${WHITE}produce clicks audibles por la discontinuidad de fase.${NC}"
    echo ""
    echo -e "${WHITE}  2.${NC} Tono fijo 1kHz ${CYAN}(original — degradación sutil)${NC}"
    echo -e "     ${WHITE}Señal monótona. Los cortes son casi imperceptibles.${NC}"
    echo ""
    echo -ne "Selecciona [1]: "
    read -r audio_choice
    audio_choice="${audio_choice:-1}"

    case "$audio_choice" in
        2)
            CURRENT_AUDIO_MODE="tone"
            CURRENT_AUDIO_DESC="Tono fijo 1kHz"
            echo -e "${GREEN}✓ Audio: Tono fijo 1kHz${NC}"
            ;;
        *)
            CURRENT_AUDIO_MODE="sweep"
            CURRENT_AUDIO_DESC="Chirp sweep 300-1000Hz"
            echo -e "${GREEN}✓ Audio: Chirp sweep 300-1000Hz${NC}"
            ;;
    esac

    echo -e "\n${YELLOW}Usa la opción 's' para reiniciar el stream con el nuevo audio.${NC}"
    echo -ne "${YELLOW}Presiona Enter para continuar...${NC}"
    read -r
}

start_receiver_display() {
    # Matar instancia anterior si existe
    if [ -n "$RECEIVER_DISPLAY_PID" ] && kill -0 "$RECEIVER_DISPLAY_PID" 2>/dev/null; then
        echo -e "${YELLOW}Cerrando video anterior (PID $RECEIVER_DISPLAY_PID)...${NC}"
        kill "$RECEIVER_DISPLAY_PID" 2>/dev/null
        sleep 1
    fi

    xhost +local:docker 2>/dev/null || true
    echo -e "\n${YELLOW}Abriendo ventana de video...${NC}"

    # Buscar terminal disponible para abrir el video en ventana separada
    # (así el menú de control queda limpio)
    if command -v xterm &>/dev/null; then
        xterm \
            -title "RECEPTOR AV - AVIXA 2026" \
            -geometry 80x5+0+0 \
            -bg black -fg green \
            -e "docker exec -e DISPLAY=$DISPLAY -it $RECEIVER /demo/receive.sh" \
            2>/dev/null &
        RECEIVER_DISPLAY_PID=$!
        echo -e "${GREEN}✓ Video abierto en xterm (PID $RECEIVER_DISPLAY_PID)${NC}"
    elif command -v gnome-terminal &>/dev/null; then
        gnome-terminal \
            --title="RECEPTOR AV - AVIXA 2026" \
            -- docker exec -e "DISPLAY=$DISPLAY" -it "$RECEIVER" /demo/receive.sh \
            2>/dev/null &
        RECEIVER_DISPLAY_PID=$!
        echo -e "${GREEN}✓ Video abierto en gnome-terminal (PID $RECEIVER_DISPLAY_PID)${NC}"
    elif command -v konsole &>/dev/null; then
        konsole -e "docker exec -e DISPLAY=$DISPLAY -it $RECEIVER /demo/receive.sh" \
            2>/dev/null &
        RECEIVER_DISPLAY_PID=$!
        echo -e "${GREEN}✓ Video abierto en konsole (PID $RECEIVER_DISPLAY_PID)${NC}"
    else
        # Fallback: background con output a log, no al terminal del menú
        docker exec -e DISPLAY="$DISPLAY" "$RECEIVER" /demo/receive.sh \
            >/tmp/av_receiver.log 2>&1 &
        RECEIVER_DISPLAY_PID=$!
        echo -e "${GREEN}✓ Video iniciado en background (PID $RECEIVER_DISPLAY_PID)${NC}"
        echo -e "  Log: ${WHITE}/tmp/av_receiver.log${NC}"
    fi
    echo ""
}

stop_receiver_display() {
    # Intentar cerrar la ventana terminal (best-effort; gnome-terminal puede ignorarlo)
    if [ -n "$RECEIVER_DISPLAY_PID" ] && kill -0 "$RECEIVER_DISPLAY_PID" 2>/dev/null; then
        kill "$RECEIVER_DISPLAY_PID" 2>/dev/null
    fi
    RECEIVER_DISPLAY_PID=""
    # Matar ffplay Y el loop de receive.sh (para que no reinicie)
    docker exec "$RECEIVER" pkill -f ffplay 2>/dev/null || true
    docker exec "$RECEIVER" pkill -f receive.sh 2>/dev/null || true
    echo -e "${GREEN}✓ Video detenido${NC}"
}

show_status_bar() {
    local color
    # Comparaciones flotantes para soportar valores decimales (ej: 0.05% loss)
    if awk "BEGIN { exit !($CURRENT_DELAY == 0 && $CURRENT_LOSS == 0 && $CURRENT_CORRUPT == 0) }"; then
        color="${GREEN}"
    elif awk "BEGIN { exit !($CURRENT_LOSS >= 20 || $CURRENT_DELAY >= 200) }"; then
        color="${RED}"
    else
        color="${YELLOW}"
    fi

    echo -e "${color}  Escenario actual: $CURRENT_SCENARIO${NC}"
    echo -e "  Latencia: ${WHITE}${CURRENT_DELAY}ms${NC}  |  Jitter: ${WHITE}${CURRENT_JITTER}ms${NC}  |  Pérdida: ${WHITE}${CURRENT_LOSS}%${NC}  |  Corrupción: ${WHITE}${CURRENT_CORRUPT}%${NC}"
    echo -e "  Fuente  : ${WHITE}${CURRENT_VIDEO_SOURCE}${NC}"
    echo -e "  Audio   : ${WHITE}${CURRENT_AUDIO_DESC}${NC}"
}

# ============================================================
# Menú principal
# ============================================================

show_menu() {
    clear
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${WHITE}${BOLD}   DEMO EN VIVO: Jitter y Latencia en Video sobre IP                    ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}   Conferencia: 'Hackeando la Señal' | AVIXA 2026                       ${BLUE}║${NC}"
    echo -e "${BLUE}╠════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC}                                                                        ${BLUE}║${NC}"
    show_status_bar | sed 's/^/  /'
    echo -e "${BLUE}║${NC}                                                                        ${BLUE}║${NC}"
    echo -e "${BLUE}╠════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${BOLD}${YELLOW}  ESCENARIOS DE RED (degradación gradual):                              ${BLUE}${NC}║${NC}"
    echo -e "${BLUE}║${NC}                         ${WHITE}(delay  | jitter |  loss  | corr | calidad  )  ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}                                                                        ${BLUE}║${NC}"
    echo -e "${BLUE}║${GREEN}  1.${NC} Red ideal LAN       ${WHITE}(  0ms  |   0ms  | 0%    |  0%  | ~100% OK)    ${BLUE}║${NC}"
    echo -e "${BLUE}║${GREEN}  2.${NC} LAN micro-pérdidas  ${WHITE}(  2ms  |   1ms  | 0.05% |  0%  |  ~99% OK)    ${BLUE}║${NC}"
    echo -e "${BLUE}║${YELLOW}  3.${NC} WAN estable         ${WHITE}( 20ms  |   5ms  | 0.2%  |  0%  |  ~97% OK)    ${BLUE}║${NC}"
    echo -e "${BLUE}║${YELLOW}  4.${NC} WAN con congestión  ${WHITE}( 40ms  |  15ms  | 1.5%  |  0%  |  ~79% OK)    ${BLUE}║${NC}"
    echo -e "${BLUE}║${YELLOW}  5.${NC} Enlace degradado    ${WHITE}( 60ms  |  25ms  | 3%    |  0%  |  ~61% OK)    ${BLUE}║${NC}"
    echo -e "${BLUE}║${RED}  6.${NC} Pérdida severa      ${WHITE}( 80ms  |  30ms  | 5%    |  1%  |  ~44% OK)    ${BLUE}║${NC}"
    echo -e "${BLUE}║${RED}  7.${NC} Enlace crítico      ${WHITE}(100ms  |  40ms  | 10%   |  2%  |  ~18% OK)    ${BLUE}║${NC}"
    echo -e "${BLUE}║${MAGENTA}  8.${NC} Colapso de red      ${WHITE}(150ms  |  60ms  | 20%   |  3%  |   ~3% OK)    ${BLUE}║${NC}"
    echo -e "${BLUE}║${MAGENTA}  9.${NC} Catastrófico        ${WHITE}(200ms  | 100ms  | 40%   |  5%  |   ~0% OK)    ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}                                                                        ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}  ${CYAN}* Calidad (~XX% OK) = SMPTE bars con -g 1. Archivo (GOP>1): menor.${NC}    ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}                                                                        ${BLUE}║${NC}"
    echo -e "${BLUE}╠════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${BOLD}${CYAN}  ACCIONES:                                                             ${BLUE}${NC}║${NC}"
    echo -e "${BLUE}║${NC}                                                                        ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  s.${NC} Iniciar stream (sender)                                            ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  f.${NC} Seleccionar fuente de video (archivo/SMPTE)                        ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  a.${NC} Seleccionar modo de audio (sweep/tono)                             ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  v.${NC} Abrir video en nueva ventana (FFplay)                              ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  x.${NC} Cerrar ventana de video                                            ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  p.${NC} Limpiar todos los impairments (red limpia)                         ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  t.${NC} Ver estado tc netem actual                                         ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  i.${NC} Ping: medir latencia real entre contenedores                       ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  n.${NC} iperf3: medir ancho de banda y pérdida UDP real                    ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  c.${NC} Ingresar impairment personalizado                                  ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  q.${NC} Salir                                                              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}                                                                        ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

custom_impairment() {
    echo ""
    echo -e "${CYAN}=== Impairment Personalizado ===${NC}"
    echo -ne "  Latencia (ms) [0]: "
    read -r delay
    delay=${delay:-0}

    echo -ne "  Jitter (ms) [0]: "
    read -r jitter
    jitter=${jitter:-0}

    echo -ne "  Pérdida de paquetes (%) [0]: "
    read -r loss
    loss=${loss:-0}

    echo -ne "  Corrupción de paquetes (%) [0]: "
    read -r corrupt
    corrupt=${corrupt:-0}

    apply_impairment "$delay" "$jitter" "$loss" "$corrupt" \
        "Personalizado: ${delay}ms delay, ${jitter}ms jitter, ${loss}% loss, ${corrupt}% corrupt"

    echo -ne "${YELLOW}Presiona Enter para continuar...${NC}"
    read -r
}

# ============================================================
# Modos de ejecución directa (sin menú)
# ============================================================

case "${1:-menu}" in
    receiver-play)
        xhost +local:docker 2>/dev/null || true
        docker exec -e DISPLAY="$DISPLAY" -it "$RECEIVER" /demo/receive.sh
        exit 0
        ;;
    stream-start)
        docker exec -d "$SENDER" /demo/stream.sh
        echo "Stream iniciado en background."
        exit 0
        ;;
    stream-stop)
        docker exec "$SENDER" pkill -f "ffmpeg" 2>/dev/null || true
        echo "Stream detenido."
        exit 0
        ;;
    clear)
        clear_impairments
        exit 0
        ;;
    status)
        show_netem_status
        exit 0
        ;;
    ping)
        ping_test
        exit 0
        ;;
    menu)
        # Continuar al menú interactivo
        ;;
    *)
        echo "Uso: $0 [menu|receiver-play|stream-start|stream-stop|clear|status|ping]"
        exit 1
        ;;
esac

# ============================================================
# Loop principal del menú interactivo
# ============================================================

# Verificar que Docker esté disponible
if ! docker info &>/dev/null; then
    echo -e "${RED}ERROR: Docker no está disponible o no tienes permisos.${NC}"
    exit 1
fi

while true; do
    show_menu
    
    # Marcadores \001 y \002 le indican a readline que los colores no ocupan espacio
    PROMPT_WHITE=$'\001\033[1;37m\002'
    PROMPT_NC=$'\001\033[0m\002'
    read -e -p "${PROMPT_WHITE}Selecciona una opción: ${PROMPT_NC}" -r choice
    
    [[ -n "$choice" ]] && history -s "$choice"

    case "$choice" in
        1)
            if check_containers; then
                clear_impairments
            fi
            sleep 2
            ;;
        2)
            if check_containers; then
                apply_impairment 2 1 0.05 0 "LAN micro-pérdidas (2ms / 1ms jitter / 0.05% loss)"
            fi
            sleep 2
            ;;
        3)
            if check_containers; then
                apply_impairment 20 5 0.2 0 "WAN estable (20ms / 5ms jitter / 0.2% loss)"
            fi
            sleep 2
            ;;
        4)
            if check_containers; then
                apply_impairment 40 15 1.5 0 "WAN con congestión (40ms / 15ms jitter / 1.5% loss)"
            fi
            sleep 2
            ;;
        5)
            if check_containers; then
                apply_impairment 60 25 3 0 "Enlace degradado (60ms / 25ms jitter / 3% loss)"
            fi
            sleep 2
            ;;
        6)
            if check_containers; then
                apply_impairment 80 30 5 1 "Pérdida severa (80ms / 30ms jitter / 5% loss / 1% corrupt)"
            fi
            sleep 2
            ;;
        7)
            if check_containers; then
                apply_impairment 100 40 10 2 "Enlace crítico (100ms / 40ms jitter / 10% loss / 2% corrupt)"
            fi
            sleep 2
            ;;
        8)
            if check_containers; then
                apply_impairment 150 60 20 3 "Colapso de red (150ms / 60ms jitter / 20% loss / 3% corrupt)"
            fi
            sleep 2
            ;;
        9)
            if check_containers; then
                apply_impairment 200 100 40 5 "CATASTRÓFICO (200ms / 100ms jitter / 40% loss / 5% corrupt)"
            fi
            sleep 2
            ;;
        f|F)
            if check_containers; then
                select_video_source
            fi
            ;;
        a|A)
            select_audio_mode
            ;;
        s|S)
            if check_containers; then
                start_streaming
            fi
            sleep 3
            ;;
        v|V)
            if check_containers; then
                start_receiver_display
            fi
            sleep 1
            ;;
        x|X)
            stop_receiver_display
            sleep 1
            ;;
        p|P)
            if check_containers; then
                clear_impairments
            fi
            sleep 2
            ;;
        t|T)
            if check_containers; then
                show_netem_status
                echo -ne "${YELLOW}Presiona Enter para continuar...${NC}"
                read -r
            fi
            ;;
        i|I)
            if check_containers; then
                ping_test
                echo -ne "${YELLOW}Presiona Enter para continuar...${NC}"
                read -r
            fi
            ;;
        n|N)
            if check_containers; then
                iperf3_test
                echo -ne "${YELLOW}Presiona Enter para continuar...${NC}"
                read -r
            fi
            ;;
        c|C)
            if check_containers; then
                custom_impairment
            fi
            ;;
        q|Q)
            echo -e "\n${YELLOW}Cerrando ventanas de video y limpiando...${NC}"
            stop_receiver_display
            # Detener stream del sender
            docker exec "$SENDER" pkill -f stream.sh 2>/dev/null || true
            docker exec "$SENDER" pkill -f ffmpeg    2>/dev/null || true
            echo -e "${GREEN}Saliendo del control de demo.${NC}"
            echo -e "Para detener los contenedores: ${YELLOW}docker compose down${NC}\n"
            exit 0
            ;;
        *)
            echo -e "${RED}Opción no válida.${NC}"
            sleep 1
            ;;
    esac
done
