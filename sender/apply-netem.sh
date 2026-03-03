#!/bin/bash
# ============================================================
# apply-netem.sh - Control de impairments de red con tc netem
# Se ejecuta DENTRO del contenedor sender con NET_ADMIN cap
# ============================================================

IFACE="${IFACE:-eth0}"
ACTION="${1:-status}"
DELAY="${2:-0}"      # milisegundos
JITTER="${3:-0}"     # milisegundos
LOSS="${4:-0}"       # porcentaje (0-100)
CORRUPTION="${5:-0}" # porcentaje (0-100)

apply_netem() {
    local delay_ms="$1"
    local jitter_ms="$2"
    local loss_pct="$3"
    local corrupt_pct="$4"

    # Eliminar regla existente (ignorar error si no existe)
    tc qdisc del dev "$IFACE" root 2>/dev/null || true

    # Calcular límite de cola: delay alto → más paquetes en tránsito
    # ~200 pkt/s × (delay_ms + jitter_ms) / 1000 × 3 (margen) + 2000 base
    local queue_limit=2000
    if [ "$delay_ms" -gt 100 ] 2>/dev/null; then
        queue_limit=$(( (delay_ms + jitter_ms) * 200 * 3 / 1000 + 2000 ))
    fi

    # Construir comando netem
    local CMD="tc qdisc add dev $IFACE root netem limit $queue_limit"

    if [ "$delay_ms" -gt 0 ] 2>/dev/null; then
        CMD="$CMD delay ${delay_ms}ms"
        if [ "$jitter_ms" -gt 0 ] 2>/dev/null; then
            CMD="$CMD ${jitter_ms}ms distribution normal"
        fi
    fi

    if [ "$loss_pct" -gt 0 ] 2>/dev/null; then
        CMD="$CMD loss ${loss_pct}%"
    fi

    if [ "$corrupt_pct" -gt 0 ] 2>/dev/null; then
        CMD="$CMD corrupt ${corrupt_pct}%"
    fi

    # Solo aplicar si hay algún impairment
    if [ "$delay_ms" -gt 0 ] 2>/dev/null || \
       [ "$loss_pct" -gt 0 ] 2>/dev/null || \
       [ "$corrupt_pct" -gt 0 ] 2>/dev/null; then
        eval "$CMD"
        echo "APPLIED: $CMD"
    else
        echo "CLEAR: Sin impairments (red limpia)"
    fi
}

show_status() {
    echo ""
    echo "=== Estado actual de la interfaz $IFACE ==="
    tc qdisc show dev "$IFACE"
    echo ""
}

case "$ACTION" in
    apply)
        apply_netem "$DELAY" "$JITTER" "$LOSS" "$CORRUPTION"
        show_status
        ;;
    clear)
        tc qdisc del dev "$IFACE" root 2>/dev/null || true
        echo "CLEAR: Todos los impairments eliminados"
        show_status
        ;;
    status)
        show_status
        ;;
    *)
        echo "Uso: $0 {apply|clear|status} [delay_ms] [jitter_ms] [loss_%] [corrupt_%]"
        echo "Ejemplos:"
        echo "  $0 clear"
        echo "  $0 apply 100 50 0 0    # 100ms delay, 50ms jitter"
        echo "  $0 apply 200 100 5 0   # 200ms delay, 100ms jitter, 5% loss"
        echo "  $0 apply 0 0 20 0      # 20% packet loss"
        exit 1
        ;;
esac
