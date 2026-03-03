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
    echo -e "${GREEN}✓ Red limpia${NC}\n"
}

show_netem_status() {
    echo -e "\n${CYAN}=== Estado tc netem en sender (eth0) ===${NC}"
    docker exec "$SENDER" tc qdisc show dev eth0 2>&1
    echo ""
}

ping_test() {
    echo -e "\n${CYAN}=== Ping desde sender a receiver ===${NC}"
    docker exec "$SENDER" ping -c 5 172.28.0.20 2>&1
    echo ""
}

start_streaming() {
    echo -e "\n${YELLOW}Iniciando streaming desde sender...${NC}"
    echo -e "${CYAN}El proceso corre en background del contenedor.${NC}\n"

    # Iniciar stream en background dentro del contenedor
    docker exec -d "$SENDER" /demo/stream.sh
    sleep 2

    echo -e "${GREEN}✓ Stream iniciado${NC}"
    echo -e "El receiver ya está escuchando en: ${WHITE}udp://172.28.0.20:5004${NC}"
    echo -e "\nPara ver el video, abre una nueva terminal y ejecuta:"
    echo -e "  ${YELLOW}./demo-control.sh receiver-play${NC}"
    echo ""
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
    # Matar ffplay dentro del contenedor (método más fiable)
    docker exec "$RECEIVER" pkill -f ffplay 2>/dev/null || true
    echo -e "${GREEN}✓ Video detenido${NC}"
}

show_status_bar() {
    local color
    if [ "$CURRENT_DELAY" -eq 0 ] && [ "$CURRENT_LOSS" -eq 0 ] && [ "$CURRENT_CORRUPT" -eq 0 ]; then
        color="${GREEN}"
    elif [ "$CURRENT_LOSS" -ge 20 ] || [ "$CURRENT_DELAY" -ge 200 ]; then
        color="${RED}"
    else
        color="${YELLOW}"
    fi

    echo -e "${color}  Escenario actual: $CURRENT_SCENARIO${NC}"
    echo -e "  Latencia: ${WHITE}${CURRENT_DELAY}ms${NC}  |  Jitter: ${WHITE}${CURRENT_JITTER}ms${NC}  |  Pérdida: ${WHITE}${CURRENT_LOSS}%${NC}  |  Corrupción: ${WHITE}${CURRENT_CORRUPT}%${NC}"
}

# ============================================================
# Menú principal
# ============================================================

show_menu() {
    clear
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${WHITE}${BOLD}   DEMO EN VIVO: Jitter y Latencia en Video sobre IP          ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}   Conferencia: 'Hackeando la Señal' | AVIXA 2026             ${BLUE}║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC}                                                              ${BLUE}║${NC}"
    show_status_bar | sed 's/^/  /'
    echo -e "${BLUE}║${NC}                                                              ${BLUE}║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${BOLD}${YELLOW}  ESCENARIOS DE RED (aplicar impairments):                    ${BLUE}${NC}║${NC}"
    echo -e "${BLUE}║${NC}                                                              ${BLUE}║${NC}"
    echo -e "${BLUE}║${GREEN}  1.${NC} Red ideal LAN         ${WHITE}(  0ms delay |   0ms jitter | 0% loss)${BLUE}║${NC}"
    echo -e "${BLUE}║${GREEN}  2.${NC} LAN con ruido         ${WHITE}(  5ms delay |   2ms jitter | 0% loss)${BLUE}║${NC}"
    echo -e "${BLUE}║${YELLOW}  3.${NC} WAN moderada          ${WHITE}( 50ms delay |  10ms jitter | 0% loss)${BLUE}║${NC}"
    echo -e "${BLUE}║${YELLOW}  4.${NC} WAN con problemas     ${WHITE}(100ms delay |  50ms jitter | 0% loss)${BLUE}║${NC}"
    echo -e "${BLUE}║${RED}  5.${NC} Enlace saturado        ${WHITE}(200ms delay | 100ms jitter | 0% loss)${BLUE}║${NC}"
    echo -e "${BLUE}║${RED}  6.${NC} Pérdida de paquetes 5% ${WHITE}( 50ms delay |  20ms jitter | 5% loss)${BLUE}║${NC}"
    echo -e "${BLUE}║${RED}  7.${NC} Pérdida crítica 20%    ${WHITE}(100ms delay |  50ms jitter |20% loss)${BLUE}║${NC}"
    echo -e "${BLUE}║${MAGENTA}  8.${NC} Enlace satelital       ${WHITE}(600ms delay | 200ms jitter | 2% loss)${BLUE}║${NC}"
    echo -e "${BLUE}║${MAGENTA}  9.${NC} Catastrófico           ${WHITE}(300ms delay | 300ms jitter |50% loss)${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}                                                              ${BLUE}║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${BOLD}${CYAN}  ACCIONES:                                                   ${BLUE}${NC}║${NC}"
    echo -e "${BLUE}║${NC}                                                              ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  s.${NC} Iniciar stream (sender)                                  ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  v.${NC} Abrir video en nueva ventana (FFplay)                    ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  x.${NC} Cerrar ventana de video                                  ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  p.${NC} Limpiar todos los impairments (red limpia)               ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  t.${NC} Ver estado tc netem actual                               ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  i.${NC} Ping: medir latencia real entre contenedores             ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  c.${NC} Ingresar impairment personalizado                        ${BLUE}║${NC}"
    echo -e "${BLUE}║${CYAN}  q.${NC} Salir                                                    ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}                                                              ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "${WHITE}Selecciona una opción: ${NC}"
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
    read -r choice

    case "$choice" in
        1)
            if check_containers; then
                apply_impairment 0 0 0 0 "Red Ideal LAN (0ms / 0ms jitter)"
            fi
            sleep 2
            ;;
        2)
            if check_containers; then
                apply_impairment 5 2 0 0 "LAN con ruido (5ms / 2ms jitter)"
            fi
            sleep 2
            ;;
        3)
            if check_containers; then
                apply_impairment 50 10 0 0 "WAN moderada (50ms / 10ms jitter)"
            fi
            sleep 2
            ;;
        4)
            if check_containers; then
                apply_impairment 100 50 0 0 "WAN con problemas (100ms / 50ms jitter)"
            fi
            sleep 2
            ;;
        5)
            if check_containers; then
                apply_impairment 200 100 0 0 "Enlace saturado (200ms / 100ms jitter)"
            fi
            sleep 2
            ;;
        6)
            if check_containers; then
                apply_impairment 50 20 5 0 "Pérdida de paquetes 5% (50ms / 20ms jitter / 5% loss)"
            fi
            sleep 2
            ;;
        7)
            if check_containers; then
                apply_impairment 100 50 20 0 "Pérdida crítica 20% (100ms / 50ms jitter / 20% loss)"
            fi
            sleep 2
            ;;
        8)
            if check_containers; then
                apply_impairment 600 200 2 0 "Enlace satelital (600ms / 200ms jitter / 2% loss)"
            fi
            sleep 2
            ;;
        9)
            if check_containers; then
                apply_impairment 300 300 50 10 "CATASTROFICO (300ms / 300ms jitter / 50% loss / 10% corrupt)"
            fi
            sleep 2
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
        c|C)
            if check_containers; then
                custom_impairment
            fi
            ;;
        q|Q)
            echo -e "\n${GREEN}Saliendo del control de demo.${NC}"
            echo -e "Para detener los contenedores: ${YELLOW}docker compose down${NC}\n"
            exit 0
            ;;
        *)
            echo -e "${RED}Opción no válida.${NC}"
            sleep 1
            ;;
    esac
done
