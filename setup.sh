#!/bin/bash
# ============================================================
# setup.sh - Configuración inicial del simulador
# Ejecutar una sola vez antes de la demo
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${CYAN}=============================================="
echo "  SETUP: Simulador AV - AVIXA 2026"
echo -e "==============================================${NC}"
echo ""

# 1. Verificar Docker
echo -e "${YELLOW}[1/5] Verificando Docker...${NC}"
if ! docker info &>/dev/null; then
    echo -e "${RED}ERROR: Docker no disponible o sin permisos.${NC}"
    echo "  Intenta: sudo usermod -aG docker \$USER && newgrp docker"
    exit 1
fi
echo -e "${GREEN}  ✓ Docker OK: $(docker --version)${NC}"

# 2. Verificar Docker Compose
echo -e "${YELLOW}[2/5] Verificando Docker Compose...${NC}"
if ! docker compose version &>/dev/null; then
    echo -e "${RED}ERROR: Docker Compose no disponible.${NC}"
    exit 1
fi
echo -e "${GREEN}  ✓ Docker Compose OK: $(docker compose version)${NC}"

# 3. Verificar X11 para display
echo -e "${YELLOW}[3/5] Verificando display X11...${NC}"
if [ -z "$DISPLAY" ]; then
    echo -e "${RED}  AVISO: Variable DISPLAY no configurada.${NC}"
    echo -e "  El video no podrá mostrarse en ventana gráfica."
    echo -e "  Configura: export DISPLAY=:0"
else
    echo -e "${GREEN}  ✓ DISPLAY=$DISPLAY${NC}"
fi

# Permitir conexiones X11 desde contenedores Docker
if command -v xhost &>/dev/null; then
    xhost +local:docker 2>/dev/null && \
        echo -e "${GREEN}  ✓ X11 habilitado para Docker${NC}" || \
        echo -e "${YELLOW}  ! No se pudo configurar xhost (continuar de todas formas)${NC}"
fi

# 3b. Verificar PulseAudio/PipeWire para audio
echo -e "${YELLOW}    Verificando audio (PulseAudio/PipeWire)...${NC}"
PULSE_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native"
if [ -S "$PULSE_SOCKET" ]; then
    echo -e "${GREEN}  ✓ PulseAudio socket: $PULSE_SOCKET${NC}"
else
    echo -e "${YELLOW}  ! Socket PulseAudio no encontrado en $PULSE_SOCKET${NC}"
    echo -e "    El video funcionará pero no habrá audio en el receiver."
    echo -e "    Verifica que PulseAudio o PipeWire estén corriendo."
fi

# 3c. Crear directorio de videos personalizados
mkdir -p videos
echo -e "${GREEN}  ✓ Directorio ./videos/ listo (copia archivos .mp4/.mkv aquí)${NC}"

# 4. Construir imágenes
echo -e "${YELLOW}[4/5] Construyendo imágenes Docker...${NC}"
echo -e "  (Esto puede tardar varios minutos en la primera ejecución)"
docker compose build
echo -e "${GREEN}  ✓ Imágenes construidas${NC}"

# 5. Verificar permisos de scripts
echo -e "${YELLOW}[5/5] Configurando permisos...${NC}"
chmod +x demo-control.sh
echo -e "${GREEN}  ✓ Permisos OK${NC}"

echo ""
echo -e "${GREEN}=============================================="
echo "  SETUP COMPLETADO"
echo -e "==============================================${NC}"
echo ""
echo -e "Para iniciar la demo:"
echo ""
echo -e "  ${YELLOW}# Terminal 1 - Levantar contenedores:${NC}"
echo -e "  docker compose up -d"
echo ""
echo -e "  ${YELLOW}# Terminal 2 - Control interactivo:${NC}"
echo -e "  ./demo-control.sh"
echo ""
echo -e "  ${YELLOW}# En el menú interactivo:${NC}"
echo -e "    s → Iniciar streaming"
echo -e "    v → Abrir ventana de video (con audio)"
echo -e "    f → Seleccionar fuente de video (SMPTE/archivo)"
echo -e "    a → Seleccionar modo de audio (sweep/tono)"
echo -e "    1-9 → Aplicar escenarios de red"
echo ""
