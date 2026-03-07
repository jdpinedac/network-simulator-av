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

# Comparación flotante: retorna 0 (true) si $1 > $2
_gt() { awk "BEGIN { exit !($1 > $2) }"; }

apply_netem() {
    local delay_ms="$1"
    local jitter_ms="$2"
    local loss_pct="$3"
    local corrupt_pct="$4"

    # Calcular límite de cola: delay alto → más paquetes en tránsito
    # ~200 pkt/s × (delay_ms + jitter_ms) / 1000 × 3 (margen) + 2000 base
    local queue_limit=2000
    if _gt "$delay_ms" 100; then
        queue_limit=$(awk "BEGIN { printf \"%d\", ($delay_ms + $jitter_ms) * 200 * 3 / 1000 + 2000 }")
    fi

    # Si no hay ningún impairment, limpiar y salir
    if ! _gt "$delay_ms" 0 && ! _gt "$loss_pct" 0 && ! _gt "$corrupt_pct" 0; then
        tc qdisc del dev "$IFACE" root 2>/dev/null || true
        echo "CLEAR: Sin impairments (red limpia)"
        return
    fi

    # replace: actualiza atómicamente la qdisc existente (o la crea si no existe).
    # IMPORTANTE: SIEMPRE incluir loss% y corrupt% explícitamente (incluso 0%).
    # replace hace update parcial: parámetros omitidos CONSERVAN su valor anterior.
    # Sin "corrupt 0%", un corrupt 5% del nivel anterior persiste al cambiar.
    local CMD="tc qdisc replace dev $IFACE root netem limit $queue_limit"

    if _gt "$delay_ms" 0; then
        CMD="$CMD delay ${delay_ms}ms"
        if _gt "$jitter_ms" 0; then
            CMD="$CMD ${jitter_ms}ms distribution normal"
        fi
    fi

    # Siempre incluir loss y corrupt para limpiar valores del nivel anterior
    CMD="$CMD loss ${loss_pct}% corrupt ${corrupt_pct}%"

    # Aplicar con replace. Si falla, intentar del+add como fallback.
    local tc_output
    if tc_output=$(eval "$CMD" 2>&1); then
        echo "APPLIED: $CMD"
    else
        echo "WARN: replace falló ($tc_output), intentando del+add..."
        tc qdisc del dev "$IFACE" root 2>/dev/null || true
        local CMD_ADD="${CMD/replace/add}"
        if tc_output=$(eval "$CMD_ADD" 2>&1); then
            echo "APPLIED (fallback): $CMD_ADD"
        else
            echo "ERROR: No se pudo aplicar netem: $tc_output"
            return 1
        fi
    fi

    # Verificar que los parámetros se aplicaron correctamente
    local actual
    actual=$(tc qdisc show dev "$IFACE" 2>/dev/null | head -1)
    if echo "$actual" | grep -q "netem"; then
        echo "VERIFY OK: $actual"
    else
        echo "VERIFY FAIL: netem no encontrado en qdisc. Actual: $actual"
        return 1
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
