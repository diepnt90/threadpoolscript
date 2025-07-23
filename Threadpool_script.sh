#!/bin/bash
set -euo pipefail

# --- Trap cleanup when script is killed ---
function teardown() {
    echo "[cleanup] Stopping dotnet-counters, dotnet-trace, dotnet-dump, azcopy processes..."
    pkill -f "/tools/dotnet-counters" || true
    pkill -f "/tools/dotnet-trace" || true
    pkill -f "/tools/dotnet-dump" || true
    pkill -f "/tools/azcopy" || true
    echo "[cleanup] Cleanup completed."
    exit 0
}
trap teardown SIGINT SIGTERM

# --- die function ---
die() {
    echo "[error] $1" >&2
    exit $2
}

# --- Get COMPUTERNAME and SAS URL from process env ---
getcomputername() {
    local pid="$1"
    local instance=$(cat "/proc/$pid/environ" | tr '\0' '\n' | grep -w COMPUTERNAME)
    instance=${instance#*=}
    echo "$instance"
}

getsasurl() {
    local pid="$1"
    local sas_url=$(cat "/proc/$pid/environ" | tr '\0' '\n' | grep -w DIAGNOSTICS_AZUREBLOBCONTAINERSASURL)
    sas_url=${sas_url#*=}
    echo "$sas_url"
}

# --- Upload with retry ---
upload_to_blob() {
    local file_path="$1"
    local sas_url="$2"
    local max_retries=5
    local attempt=1
    while [ $attempt -le $max_retries ]; do
        echo "[upload] Uploading $file_path to blob (attempt $attempt/$max_retries)..."
        azcopy_output=$(/tools/azcopy copy "$file_path" "$sas_url" 2>&1)
        if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
            echo "[upload] Upload $file_path succeeded."
            return 0
        fi
        echo "[upload] Upload failed, retrying..."
        attempt=$((attempt+1))
        sleep 3
    done
    echo "[upload] Upload $file_path failed after $max_retries attempts."
    return 1
}

# --- Find PID of dotnet process ---
pid=$(/tools/dotnet-dump ps | grep /usr/share/dotnet/dotnet | grep -v grep | tr -s " " | cut -d" " -f2)
if [ -z "$pid" ]; then
    die "Could not find any running .NET process" 1
fi

instance=$(getcomputername "$pid")
if [ -z "$instance" ]; then
    die "Could not find COMPUTERNAME environment variable" 1
fi

sas_url=$(getsasurl "$pid")
if [ -z "$sas_url" ]; then
    die "Could not find DIAGNOSTICS_AZUREBLOBCONTAINERSASURL environment variable" 1
fi

# --- Collect nettrace ---
echo "[trace] Starting nettrace collection..."
trace_file="trace_${instance}_$(date '+%Y%m%d_%H%M%S').nettrace"
/tools/dotnet-trace collect -p "$pid" -o "$trace_file" --duration 00:01:00 > /dev/null || echo "[error] Nettrace collection failed"

echo "[trace] Nettrace collected, waiting 5s before upload..."
sleep 5
echo "[trace] Starting nettrace upload..."
upload_to_blob "$trace_file" "$sas_url" || echo "[error] Nettrace upload failed"

echo "[trace] Nettrace upload succeeded."

# --- Collect memory dump ---
echo "[dump] Starting memory dump collection..."
dump_file="dump_${instance}_$(date '+%Y%m%d_%H%M%S').dmp"
/tools/dotnet-dump collect -p "$pid" -o "$dump_file" > /dev/null || echo "[error] Memory dump collection failed"

echo "[dump] Memory dump collected, waiting 5s before upload..."
sleep 5
echo "[dump] Starting memory dump upload..."
upload_to_blob "$dump_file" "$sas_url" || echo "[error] Memory dump upload failed"

echo "[dump] Memory dump upload succeeded."

# --- Collect stack trace ---
echo "[stack] Starting stack trace collection..."
stacktrace_file="stacktrace_${instance}_$(date '+%Y%m%d_%H%M%S').txt"
/tools/dotnet-stack report -p "$pid" > "$stacktrace_file" || echo "[error] Stack trace collection failed"

echo "[stack] Stack trace collected, waiting 5s before upload..."
sleep 5
echo "[stack] Starting stack trace upload..."
upload_to_blob "$stacktrace_file" "$sas_url" || echo "[error] Stack trace upload failed"

echo "[stack] Stack trace upload succeeded."

# --- Collect counter ---
echo "[counter] Starting counter collection (dotnet-counters)..."
countertrace_file="countertrace_${instance}_$(date '+%Y%m%d_%H%M%S').csv"
/tools/dotnet-counters collect --process-id "$pid" --counters "System.Runtime,System.Threading.Tasks.TplEventSource" --refresh-interval 1 --format csv --output "$countertrace_file" > /dev/null &
COUNTERS_PID=$!
# Wait for file to appear
while [[ ! -e "$countertrace_file" ]]; do sleep 1; done
# Collect for 5 minutes
sleep 300
kill $COUNTERS_PID
if [ ! -s "$countertrace_file" ]; then
    echo "[error] Counter trace collection failed"
fi

echo "[counter] Counter collected, waiting 5s before upload..."
sleep 5
echo "[counter] Starting counter trace upload..."
upload_to_blob "$countertrace_file" "$sas_url" || echo "[error] Counter trace upload failed"

echo "[counter] Counter trace upload succeeded."

echo "[done] All data collection and upload steps are complete, let transfer to Problem team for analyzing!" 
