#!/bin/bash
set -euo pipefail

############################################
# GLOBAL CLEANUP BEFORE ANYTHING RUNS
############################################
echo "[startup] Cleaning stale diagnostic processes..."
pkill -f dotnet-counters 2>/dev/null || true
pkill -f dotnet-trace    2>/dev/null || true
pkill -f dotnet-dump     2>/dev/null || true
pkill -f azcopy          2>/dev/null || true
pkill -f Auto_resp_collect.sh 2>/dev/null || true
pkill -f Auto_cpu_collect.sh  2>/dev/null || true
pkill -f Auto_mem_collect.sh  2>/dev/null || true
pkill -f collector_core.sh     2>/dev/null || true
pkill -f curl 2>/dev/null || true
echo "[startup] Cleanup completed."

############################################
# CONFIG
############################################
WORKDIR="/home/Threadpool"
mkdir -p "$WORKDIR"

COLLECTOR_URL="https://raw.githubusercontent.com/hapm0598/Threadpool/refs/heads/main/collector_core.sh"
AUTO_RESP_URL="https://raw.githubusercontent.com/hapm0598/Threadpool/refs/heads/main/Auto_resp_collect.sh"
AUTO_CPU_URL="https://raw.githubusercontent.com/hapm0598/Threadpool/refs/heads/main/Auto_cpu_collect.sh"
AUTO_MEM_URL="https://raw.githubusercontent.com/hapm0598/Threadpool/refs/heads/main/Auto_mem_collect.sh"

############################################
# HELPER: DOWNLOAD SCRIPT
############################################
download_script() {
    local url="$1"
    local dest="$2"
    echo "[download] Fetching $dest ..."
    curl -sSL "$url" -o "$dest"
    chmod +x "$dest"
    sed -i 's/\r$//' "$dest"

    if [[ ! -s "$dest" ]]; then
        echo "[error] Failed to download $dest"
        exit 1
    fi
}

############################################
# MAIN MENU
############################################
echo "==============================="
echo " THREADPOOL DIAGNOSTIC TOOL"
echo "==============================="
echo "1) Manual Mode"
echo "2) Auto Mode"
read -r -p "Select mode (1/2): " MODE
MODE=${MODE:-1}

############################################
# AUTO MODE
############################################
if [[ "$MODE" == "2" ]]; then
    echo "==============================="
    echo "        AUTO MODE OPTIONS"
    echo "==============================="
    echo "1) Response Time Auto Mode"
    echo "2) CPU Auto Mode"
    echo "3) Memory Auto Mode"
    read -r -p "Select (1/2/3): " AUTO_MODE

    case "$AUTO_MODE" in

    #############################################################
    # AUTO MODE 1 — RESPONSE TIME
    #############################################################
    1)
        read -r -p "Enter URL (-l), default http://localhost:80: " AUTO_L
        read -r -p "Enter threshold (-t ms), default 1000: " AUTO_T
        read -r -p "Enter frequency (-f seconds), default 10: " AUTO_F

        AUTO_L=${AUTO_L:-http://localhost:80}
        AUTO_T=${AUTO_T:-1000}
        AUTO_F=${AUTO_F:-10}

        echo "[auto] ResponseTime args: -l $AUTO_L -t $AUTO_T -f $AUTO_F"

        pkill -f Auto_resp_collect.sh 2>/dev/null || true
        pkill -f curl 2>/dev/null || true

        download_script "$COLLECTOR_URL" "$WORKDIR/collector_core.sh"
        download_script "$AUTO_RESP_URL" "$WORKDIR/Auto_resp_collect.sh"

        echo "[auto] Starting ResponseTime Auto Monitor..."
        nohup "$WORKDIR/Auto_resp_collect.sh" \
            -l "$AUTO_L" -t "$AUTO_T" -f "$AUTO_F" enable-dump-trace \
            > "$WORKDIR/auto_resp_monitor.log" 2>&1 &

        echo "[auto] ResponseTime Auto monitoring started."
        exit 0
        ;;

    #############################################################
    # AUTO MODE 2 — CPU MONITOR
    #############################################################
    2)
        read -r -p "Enter CPU threshold (%) of TOTAL CPU (default 80): " CPU_P
        read -r -p "Enter frequency (seconds), default 10: " CPU_F

        CPU_P=${CPU_P:-80}
        CPU_F=${CPU_F:-10}

        echo "[auto] CPU args: -p $CPU_P -f $CPU_F"

        pkill -f Auto_cpu_collect.sh 2>/dev/null || true
        pkill -f curl 2>/dev/null || true

        download_script "$COLLECTOR_URL" "$WORKDIR/collector_core.sh"
        download_script "$AUTO_CPU_URL" "$WORKDIR/Auto_cpu_collect.sh"

        echo "[auto] Starting CPU Auto Monitor..."
        nohup "$WORKDIR/Auto_cpu_collect.sh" \
            -p "$CPU_P" -f "$CPU_F" \
            > "$WORKDIR/auto_cpu_monitor.log" 2>&1 &

        echo "[auto] CPU Auto monitoring started."
        exit 0
        ;;

    #############################################################
    # AUTO MODE 3 — MEMORY MONITOR (TOTAL MEMORY)
    #############################################################
    3)
        read -r -p "Enter Memory threshold (% used), default 80: " MEM_T
        read -r -p "Enter frequency (seconds), default 10: " MEM_F

        MEM_T=${MEM_T:-80}
        MEM_F=${MEM_F:-10}

        echo "[auto] Memory args: -t $MEM_T -f $MEM_F"

        pkill -f Auto_mem_collect.sh 2>/dev/null || true
        pkill -f curl 2>/dev/null || true

        download_script "$COLLECTOR_URL" "$WORKDIR/collector_core.sh"
        download_script "$AUTO_MEM_URL" "$WORKDIR/Auto_mem_collect.sh"

        echo "[auto] Starting Memory Auto Monitor..."
        nohup "$WORKDIR/Auto_mem_collect.sh" \
            -t "$MEM_T" -f "$MEM_F" \
            > "$WORKDIR/auto_mem_monitor.log" 2>&1 &

        echo "[auto] Memory Auto monitoring started."
        exit 0
        ;;

    *)
        echo "[error] Invalid Auto Mode selection"
        exit 1
        ;;
    esac
fi

############################################
# MANUAL MODE
############################################
echo "[manual] Manual Mode Selected"
download_script "$COLLECTOR_URL" "$WORKDIR/collector_core.sh"

read -r -p "Collect memory dump? (y/N): " USER_DUMP
USER_DUMP=${USER_DUMP:-N}

if [[ "$USER_DUMP" =~ ^[Yy]$ ]]; then
    DUMP_FLAG="--manual-dump"
else
    DUMP_FLAG="--manual-nodump"
fi

echo "[manual] Running collector ..."
bash "$WORKDIR/collector_core.sh" --manual $DUMP_FLAG
