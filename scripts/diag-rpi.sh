#!/usr/bin/env bash
# =============================================================================
# diag-rpi.sh — Diagnostic automatique sm64coopdx sur Raspberry Pi
# Usage : bash diag-rpi.sh [chemin_vers_binaire]
# Exemple : bash diag-rpi.sh ~/sm64coopdx_RaspberryPi/sm64coopdx.arm
# =============================================================================
set -euo pipefail

BIN="${1:-}"
DIAG_DIR="/tmp/sm64coopdx-diag-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DIAG_DIR"
LOG="$DIAG_DIR/report.txt"

log() { echo "$*" | tee -a "$LOG"; }
sep() { log; log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; log "$*"; log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

sep "[1/7] SYSTEME"
log "Date     : $(date)"
log "Hostname : $(hostname)"
log "OS       : $(cat /etc/os-release | grep PRETTY | cut -d= -f2 | tr -d '"')"
log "Kernel   : $(uname -a)"

sep "[2/7] CPU & MEMOIRE"
grep -E 'model name|Hardware|Revision|Features' /proc/cpuinfo | head -20 | tee -a "$LOG"
log ""
sed -n '1,15p' /proc/meminfo | tee -a "$LOG"

sep "[3/7] GPU / VIDEO"
vcgencmd measure_temp 2>/dev/null | tee -a "$LOG" || log "vcgencmd: non disponible"
vcgencmd get_mem arm 2>/dev/null | tee -a "$LOG" || true
vcgencmd get_mem gpu 2>/dev/null | tee -a "$LOG" || true
glxinfo 2>/dev/null | grep -E 'renderer|version' | tee -a "$LOG" || log "glxinfo: non disponible (normal en headless)"
ls /dev/dri/ 2>/dev/null | tee -a "$LOG" || log "/dev/dri: absent"

sep "[4/7] BINAIRE"
if [ -z "$BIN" ]; then
    BIN=$(find ~/sm64coopdx_RaspberryPi ~/sm64coopdx -maxdepth 2 -name 'sm64coopdx*' ! -name '*_debug*' -type f 2>/dev/null | head -1)
fi
if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
    log "ERREUR: binaire introuvable. Relancez avec: bash diag-rpi.sh /chemin/vers/sm64coopdx.arm"
else
    log "Binaire  : $BIN"
    file "$BIN" | tee -a "$LOG"
    log ""
    log "--- readelf ABI tags ---"
    readelf -A "$BIN" 2>/dev/null | tee -a "$LOG" || log "readelf: non disponible"
    log ""
    log "--- ldd (dependances dynamiques) ---"
    ldd "$BIN" 2>&1 | tee -a "$LOG"
fi

sep "[5/7] LIBRAIRIES SYSTEME"
for LIB in libSDL2 libGLESv2 libGL libGLEW libcurl libz; do
    FOUND=$(ldconfig -p 2>/dev/null | grep "$LIB" | head -1)
    if [ -n "$FOUND" ]; then
        log "OK  $FOUND"
    else
        log "MISSING  $LIB"
    fi
done

sep "[6/7] STRACE (crash trace)"
if [ -n "$BIN" ] && [ -f "$BIN" ]; then
    if command -v strace &>/dev/null; then
        log "Lancement strace (max 30s, headless)..."
        WORKDIR=$(dirname "$BIN")
        timeout 30 strace -f -e trace=open,openat,mmap,read,write,ioctl,brk,mprotect \
            -o "$DIAG_DIR/strace.txt" \
            bash -c "cd '$WORKDIR' && ./'$(basename "$BIN")' --headless 2>&1" || true
        log "Dernieres lignes strace :"
        tail -n 80 "$DIAG_DIR/strace.txt" | tee -a "$LOG"
    else
        log "strace non installe. Installez avec : sudo apt install -y strace"
    fi
fi

sep "[7/7] GDB BACKTRACE"
if [ -n "$BIN" ] && [ -f "$BIN" ]; then
    # Cherche un binaire debug d'abord
    DEBUG_BIN=$(find "$(dirname "$BIN")" -maxdepth 1 -name '*debug*' -type f 2>/dev/null | head -1)
    GDB_BIN="${DEBUG_BIN:-$BIN}"
    if command -v gdb &>/dev/null; then
        log "Binaire utilise pour gdb : $GDB_BIN"
        WORKDIR=$(dirname "$GDB_BIN")
        GDB_CMDS="$DIAG_DIR/gdb_commands.txt"
        cat > "$GDB_CMDS" <<'GDB_EOF'
set pagination off
set confirm off
set follow-fork-mode child
run --headless
bt full
info registers
quit
GDB_EOF
        timeout 60 bash -c "
            cd '$WORKDIR' && \
            gdb -batch -x '$GDB_CMDS' './'$(basename "$GDB_BIN")' 2>&1
        " | tee "$DIAG_DIR/gdb_output.txt" || true
        log "--- GDB output (50 dernieres lignes) ---"
        tail -n 50 "$DIAG_DIR/gdb_output.txt" | tee -a "$LOG"
    else
        log "gdb non installe. Installez avec : sudo apt install -y gdb"
        log "Puis relancez ce script."
    fi
fi

sep "RAPPORT COMPLET"
log "Tous les fichiers de diagnostic sont dans : $DIAG_DIR"
log "  - report.txt       : ce rapport"
log "  - strace.txt       : trace syscalls"
log "  - gdb_output.txt   : backtrace gdb"
log ""
log "Pour partager le rapport complet :"
log "  cat $DIAG_DIR/report.txt"
log "  cat $DIAG_DIR/gdb_output.txt"

echo
echo "==> Rapport genere : $LOG"
