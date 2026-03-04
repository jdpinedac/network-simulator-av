# Simulador de Jitter y Latencia en Video sobre IP

**Conferencia:** "Hackeando la Señal: La Verdad Oculta de la Infraestructura de Video sobre IP"
**AVIXA 2026** | Juan David Pineda-Cárdenas

---

## Arquitectura

```mermaid
flowchart TD
    %% Definición de estilos
    classDef network fill:none,stroke:#0984e3,stroke-width:2px,stroke-dasharray: 6 6
    classDef container fill:#f8f9fa,stroke:#2d3436,stroke-width:2px,color:#2d3436
    classDef host fill:none,stroke:none,color:#2d3436,font-weight:bold

    %% Red Docker (Contenedor principal)
    subgraph DockerNetwork ["🐳 Red Docker (172.28.0.0/24)"]
        direction LR
        
        %% Nodo Emisor
        Sender["<div style='text-align: left;'><b>av_sender</b><br>172.28.0.10<br><br>FFmpeg<br>(genera video)<br><br>tc netem<br>(inyecta<br>impairments)</div>"]
        
        %% Nodo Receptor
        Receiver["<div style='text-align: left;'><b>av_receiver</b><br>172.28.0.20<br><br>FFplay<br>(muestra<br>degradación)</div>"]
        
        %% Conexión de red
        Sender -- "UDP/MPEG-TS" --> Receiver
    end

    %% Script de control en el Host
    Host["💻 demo-control.sh (host)<br>(menú interactivo)"]

    %% Conexión visual indicando el control desde el host
    DockerNetwork -.- Host

    %% Aplicación de clases
    class DockerNetwork network
    class Sender,Receiver container
    class Host host
```

## Componentes

| Componente | Descripción |
|---|---|
| `sender` | Genera barras SMPTE con reloj y frame counter vía FFmpeg. Tiene `tc netem` para inyectar latencia/jitter/pérdida |
| `receiver` | Recibe el stream UDP y lo muestra con FFplay (X11). Los artefactos son visibles en tiempo real |
| `demo-control.sh` | Script de control interactivo con escenarios predefinidos |

## Requisitos

- Docker 20+ con Docker Compose v2
- Linux con X11 (para mostrar video en ventana)
- Kernel con soporte `netem` (estándar en Ubuntu/Debian)
- Capacidad `NET_ADMIN` disponible para Docker

## Inicio Rápido

```bash
# 1. Setup inicial (solo la primera vez)
chmod +x setup.sh && ./setup.sh

# 2. Levantar contenedores
docker compose up -d

# 3. Control interactivo (incluye streaming + video + escenarios)
./demo-control.sh
```

## Guión de la Demo

### Paso 1: Red Ideal (baseline)
- Seleccionar escenario **1** → 0ms latencia, 0ms jitter
- El video se ve perfectamente fluido
- El tono de audio es continuo

### Paso 2: Introducir Jitter Moderado
- Seleccionar escenario **3** → 50ms delay, 10ms jitter
- *Concepto: WAN geográfica normal*
- El video puede mostrar pequeñas vacilaciones
- El audio tiene leves interrupciones

### Paso 3: Jitter Severo
- Seleccionar escenario **4** → 100ms delay, 50ms jitter
- *Concepto: Red congestionada*
- Congelamiento visible de frames
- Audio entrecortado claramente

### Paso 4: Pérdida de Paquetes
- Seleccionar escenario **6** → 5% loss
- *Concepto: Interferencia o saturación del enlace*
- Bloques pixelados (macroblocks) en el video
- Audio con "clicks" y silencios

### Paso 5: Escenario Catastrófico
- Seleccionar escenario **9** → 200ms/200ms jitter/30% loss
- *Concepto: Lo que pasa sin QoS ni VLAN segregada*
- Video prácticamente inutilizable
- Audio irreconocible

### Paso 6: Recuperación
- Seleccionar escenario **1** o presionar **p**
- *Concepto: El valor del QoS y la segregación de tráfico*
- El video vuelve a verse perfectamente

---

## Escenarios Disponibles

| # | Nombre | Delay | Jitter | Loss | Caso real |
|---|---|---|---|---|---|
| 1 | Red ideal LAN | 0ms | 0ms | 0% | Switch gestionado con QoS |
| 2 | LAN con ruido | 5ms | 2ms | 0% | LAN sin gestión de QoS |
| 3 | WAN moderada | 50ms | 10ms | 0% | Enlace WAN continental |
| 4 | WAN con problemas | 100ms | 50ms | 0% | Red congestionada |
| 5 | Enlace saturado | 200ms | 100ms | 0% | Ancho de banda agotado |
| 6 | Pérdida 5% | 50ms | 20ms | 5% | WiFi con interferencia |
| 7 | Pérdida crítica 20% | 100ms | 50ms | 20% | WiFi en área densa |
| 8 | Enlace satelital | 600ms | 200ms | 2% | VSAT geoestacionario |
| 9 | Catastrófico | 200ms | 200ms | 30% | Sin QoS, red mixta |

---

## Conceptos Técnicos Demostrados

### Jitter
- **Definición:** Variación en el tiempo de llegada de paquetes
- **Efecto en video:** Frames llegan fuera de orden → congelamiento, saltos
- **Efecto en audio:** Muestras faltantes → clicks, silencios, distorsión
- **Solución:** Jitter buffer (QoS prioriza paquetes de tiempo real)

### Latencia
- **Definición:** Retardo total en la transmisión extremo a extremo
- **Efecto en AV:** Desincronización A/V, problemas en sistemas interactivos
- **Referencia:** ITU-T G.114 recomienda <150ms para voz interactiva

### Pérdida de Paquetes
- **Efecto en UDP (sin retransmisión):** Artefactos visuales permanentes
- **Efecto en TCP:** Retransmisión → mayor latencia y jitter (peor para tiempo real)
- **Por qué UDP para AV en vivo:** Más vale perder un frame que llegar tarde

### Por qué UDP sin TCP para broadcast en vivo
TCP garantiza entrega pero introduce latencia variable (retransmisiones).
Para video en tiempo real, UDP + FEC (Forward Error Correction) es preferible.
Protocolos como SRT añaden recuperación sin la penalidad de TCP.

---

## Estructura de Archivos

```
network-simulator-claude/
├── docker-compose.yml          # Orquestación de contenedores
├── demo-control.sh             # Control interactivo principal
├── setup.sh                    # Setup inicial
├── README.md                   # Este archivo
├── sender/
│   ├── Dockerfile              # Ubuntu 22.04 + FFmpeg + iproute2
│   ├── stream.sh               # Generador de stream (FFmpeg)
│   └── apply-netem.sh          # Aplicar/quitar impairments (tc netem)
└── receiver/
    ├── Dockerfile              # Ubuntu 22.04 + FFmpeg
    ├── receive.sh              # Display del stream (FFplay + X11)
    └── receive-stats.sh        # Modo estadísticas (sin display gráfico)
```

---

## Troubleshooting

**El video no aparece (error DISPLAY)**
```bash
xhost +local:docker
export DISPLAY=:0
```

**FFplay abre pero no muestra video (vq=0KB, "datagram lost")**

Esto ocurre si los parámetros de FFplay son demasiado agresivos. Verificar en `receive.sh`:
- `-probesize` debe ser >= `1000000` (1MB). Valores muy pequeños (ej: 32) impiden detectar el formato MPEG-TS (PAT/PMT tables).
- `-analyzeduration` debe ser >= `1000000`. Con `0` no se analiza el stream.
- **No usar** `-avioflags direct`: elimina el buffering de I/O y causa pérdida de datagramas UDP.
- La URL UDP debe incluir `buffer_size=65536` para un buffer suficiente.

```bash
# Verificar que FFplay está decodificando (vq debe ser > 0):
docker exec av_receiver pgrep -a ffplay
# Si vq=0KB → reconstruir receiver con los parámetros corregidos
docker compose build receiver && docker compose up -d
```

**Los impairments no se aplican**
```bash
# Verificar que el contenedor tiene NET_ADMIN
docker inspect av_sender | grep -i "CapAdd"
# Debe mostrar: "NET_ADMIN"
```

**El stream no llega al receiver**
```bash
# Verificar conectividad
docker exec av_sender ping -c 3 172.28.0.20

# Ver estadísticas de red
docker exec av_sender tc qdisc show dev eth0
```

**Reconstruir desde cero**
```bash
docker compose down --volumes --remove-orphans
docker compose build --no-cache
docker compose up -d
```
