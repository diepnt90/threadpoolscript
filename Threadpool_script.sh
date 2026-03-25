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

##########################################
# GET INSTANCE FROM COMPUTERNAME
##########################################
get_instance_name() {
    local dotnet_pid
    dotnet_pid=$(/tools/dotnet-dump ps | awk '$0 ~ /\/usr\/share\/dotnet\/dotnet/ {print $1; exit}' || true)
    [[ -n "$dotnet_pid" ]] || return 1
    tr '\0' '\n' < "/proc/$dotnet_pid/environ" | awk -F'=' '$1=="COMPUTERNAME"{print $2; exit}'
}

instancehome="$(get_instance_name || true)"
if [[ -z "$instancehome" ]]; then
    echo "[error] Could not find COMPUTERNAME from running .NET process"
    exit 1
fi

# WORKDIR unique for this instance
WORKDIR="/home/Troubleshooting/${instancehome}"

# Clean existing WORKDIR if present
if [[ "$WORKDIR" == /home/Troubleshooting/* ]]; then
    rm -rf "$WORKDIR"
    echo "deleted old troubleshooting folder."
else
    echo "[error] WORKDIR path is unsafe, aborting delete."
    exit 1
fi

mkdir -p "$WORKDIR"

COLLECTOR_URL="https://raw.githubusercontent.com/hapm0598/Threadpool/refs/heads/main/collector_core.sh"
AUTO_RESP_URL="https://raw.githubusercontent.com/hapm0598/Threadpool/refs/heads/main/Auto_resp_collect.sh"
AUTO_CPU_URL="https://raw.githubusercontent.com/hapm0598/Threadpool/refs/heads/main/Auto_cpu_collect.sh"
AUTO_MEM_URL="https://raw.githubusercontent.com/hapm0598/Threadpool/refs/heads/main/Auto_mem_collect.sh"
AUTO_TCP_URL="https://raw.githubusercontent.com/hapm0598/Threadpool/refs/heads/main/Auto_tcp_collect.sh"

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
# HELPER: USE LOCAL SCRIPT IF AVAILABLE
############################################
prepare_script() {
    local local_name="$1"
    local url="$2"
    local dest="$3"

    # Prefer bundled local script (same directory as launcher)
    local launcher_dir
    launcher_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local local_path="${launcher_dir}/${local_name}"

    if [[ -f "$local_path" ]]; then
        echo "[prepare] Using local ${local_name}"
        cp "$local_path" "$dest"
        chmod +x "$dest"
        sed -i 's/\r$//' "$dest"
        return 0
    fi

    echo "[prepare] Local ${local_name} not found, downloading..."
    download_script "$url" "$dest"
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
    echo "4) TCP Outbound Connection Auto Mode"
    read -r -p "Select (1/2/3/4): " AUTO_MODE

    case "$AUTO_MODE" in

    #############################################################
    # AUTO MODE 1 — RESPONSE TIME
    #############################################################
    1)
        read -r -p "Enter URL (-l), default http://localhost:80: " AUTO_L
        read -r -p "Enter threshold (-t ms), default 1000: " AUTO_T
        read -r -p "Enter frequency (-f seconds), default 10: " AUTO_F
        read -r -p "Enter consecutive trigger window seconds (default 30): " AUTO_W
        read -r -p "Collect memory dump when threshold exceeded? (y/N): " AUTO_DUMP
        AUTO_DUMP=${AUTO_DUMP:-N}

        if [[ "$AUTO_DUMP" =~ ^[Yy]$ ]]; then
        DUMP_FLAG="--enable-dump"
       else
        DUMP_FLAG=""
       fi
        AUTO_L=${AUTO_L:-http://localhost:80}
        AUTO_T=${AUTO_T:-1000}
        AUTO_F=${AUTO_F:-10}
        AUTO_W=${AUTO_W:-30}

        read -r -p "Max monitor run time (days, 0=run forever, default 5): " AUTO_MAX_DAYS
        AUTO_MAX_DAYS=${AUTO_MAX_DAYS:-5}

        echo "[auto] Max days: $AUTO_MAX_DAYS"

        echo "[auto] ResponseTime args: -l $AUTO_L -t $AUTO_T -f $AUTO_F -w $AUTO_W $DUMP_FLAG"

        pkill -f Auto_resp_collect.sh 2>/dev/null || true
        pkill -f curl 2>/dev/null || true

        prepare_script "collector_core.sh" "$COLLECTOR_URL" "$WORKDIR/collector_core.sh"
        prepare_script "Auto_resp_collect.sh" "$AUTO_RESP_URL" "$WORKDIR/Auto_resp_collect.sh"

        echo "[auto] Starting ResponseTime Auto Monitor..."
        nohup "$WORKDIR/Auto_resp_collect.sh" -l "$AUTO_L" -t "$AUTO_T" -f "$AUTO_F" $DUMP_FLAG \
            --trigger-window-seconds "$AUTO_W" \
            --max-days "$AUTO_MAX_DAYS" \
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
        read -r -p "Enter consecutive trigger window seconds (default 30): " CPU_W
        read -r -p "Collect memory dump when threshold exceeded? (y/N): " AUTO_DUMP
        AUTO_DUMP=${AUTO_DUMP:-N}

        if [[ "$AUTO_DUMP" =~ ^[Yy]$ ]]; then
        DUMP_FLAG="--enable-dump"
       else
        DUMP_FLAG=""
       fi

        CPU_P=${CPU_P:-80}
        CPU_F=${CPU_F:-10}
        CPU_W=${CPU_W:-30}

        read -r -p "Max monitor run time (days, 0=run forever, default 5): " AUTO_MAX_DAYS
        AUTO_MAX_DAYS=${AUTO_MAX_DAYS:-5}

        echo "[auto] CPU args: -p $CPU_P -f $CPU_F -w $CPU_W $DUMP_FLAG"

        pkill -f Auto_cpu_collect.sh 2>/dev/null || true
        pkill -f curl 2>/dev/null || true

        prepare_script "collector_core.sh" "$COLLECTOR_URL" "$WORKDIR/collector_core.sh"
        prepare_script "Auto_cpu_collect.sh" "$AUTO_CPU_URL" "$WORKDIR/Auto_cpu_collect.sh"

        echo "[auto] Starting CPU Auto Monitor..."
        nohup "$WORKDIR/Auto_cpu_collect.sh" -p "$CPU_P" -f "$CPU_F" $DUMP_FLAG \
            --trigger-window-seconds "$CPU_W" \
            --max-days "$AUTO_MAX_DAYS" \
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
        read -r -p "Enter consecutive trigger window seconds (default 30): " MEM_W
        read -r -p "Collect memory dump when threshold exceeded? (y/N): " AUTO_DUMP
        AUTO_DUMP=${AUTO_DUMP:-N}

        if [[ "$AUTO_DUMP" =~ ^[Yy]$ ]]; then
        DUMP_FLAG="--enable-dump"
       else
        DUMP_FLAG=""
       fi

        MEM_T=${MEM_T:-80}
        MEM_F=${MEM_F:-10}
        MEM_W=${MEM_W:-30}

        read -r -p "Max monitor run time (days, 0=run forever, default 5): " AUTO_MAX_DAYS
        AUTO_MAX_DAYS=${AUTO_MAX_DAYS:-5}

        echo "[auto] Memory args: -t $MEM_T -f $MEM_F -w $MEM_W $DUMP_FLAG"

        pkill -f Auto_mem_collect.sh 2>/dev/null || true
        pkill -f curl 2>/dev/null || true

        prepare_script "collector_core.sh" "$COLLECTOR_URL" "$WORKDIR/collector_core.sh"
        prepare_script "Auto_mem_collect.sh" "$AUTO_MEM_URL" "$WORKDIR/Auto_mem_collect.sh"

        echo "[auto] Starting Memory Auto Monitor..."
        nohup "$WORKDIR/Auto_mem_collect.sh" -t "$MEM_T" -f "$MEM_F" $DUMP_FLAG \
            --trigger-window-seconds "$MEM_W" \
            --max-days "$AUTO_MAX_DAYS" \
            > "$WORKDIR/auto_mem_monitor.log" 2>&1 &

        echo "[auto] Memory Auto monitoring started."
        exit 0
        ;;
    #############################################################
    # AUTO MODE 4 — TCP Outbound Connection Monitor
    #############################################################
   4)
       read -r -p "Enter TCP connection threshold (default 200): " TCP_T
       read -r -p "Enter frequency (seconds, default 10): " TCP_F
       read -r -p "Collect memory dump when threshold exceeded? (y/N): " AUTO_DUMP
        AUTO_DUMP=${AUTO_DUMP:-N}

       if [[ "$AUTO_DUMP" =~ ^[Yy]$ ]]; then
        DUMP_FLAG="--enable-dump"
       else
        DUMP_FLAG=""
       fi

       TCP_T=${TCP_T:-200}
       TCP_F=${TCP_F:-10}
     
       read -r -p "Max monitor run time (days, 0=run forever, default 5): " AUTO_MAX_DAYS
       AUTO_MAX_DAYS=${AUTO_MAX_DAYS:-5}

       echo "[auto] Max days: $AUTO_MAX_DAYS"

       echo "[auto] TCP args: -t $TCP_T -f $TCP_F $DUMP_FLAG"

        pkill -f Auto_tcp_collect.sh 2>/dev/null || true
        pkill -f curl 2>/dev/null || true

       prepare_script "collector_core.sh" "$COLLECTOR_URL" "$WORKDIR/collector_core.sh"
       prepare_script "Auto_tcp_collect.sh" "$AUTO_TCP_URL" "$WORKDIR/Auto_tcp_collect.sh"

       echo "[auto] Starting TCP Auto Monitor..."
       nohup "$WORKDIR/Auto_tcp_collect.sh" -t "$TCP_T" -f "$TCP_F" $DUMP_FLAG --max-days "$AUTO_MAX_DAYS" > "$WORKDIR/auto_tcp_monitor.log" 2>&1 &

       echo "[auto] TCP Auto monitoring started."
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
prepare_script "collector_core.sh" "$COLLECTOR_URL" "$WORKDIR/collector_core.sh"

read -r -p "Collect memory dump? (y/N): " USER_DUMP
USER_DUMP=${USER_DUMP:-N}

if [[ "$USER_DUMP" =~ ^[Yy]$ ]]; then
    DUMP_FLAG="--manual-dump"
else
    DUMP_FLAG="--manual-nodump"
fi

echo "[manual] Running collector ..."
bash "$WORKDIR/collector_core.sh" --manual $DUMP_FLAG
