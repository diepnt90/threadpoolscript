
#!/bin/bash
set -euo pipefail

# =========================
# Config (có thể tùy biến)
# =========================
WORKDIR="/home/Threadpool"
TOOLS_DIR="/tools"
TRACE_DURATION_SECONDS=90            # Thời lượng nettrace
COUNTER_LIST="System.Runtime,System.Threading.Tasks.TplEventSource,Microsoft.AspNetCore.Hosting,Microsoft-AspNetCore-Server-Kestrel"
UPLOAD_INITIAL_DELAY=20              # chờ trước khi upload (giây)
UPLOAD_GAP=10                        # nghỉ giữa các lần upload (giây)
MAX_UPLOAD_RETRY=5

# =========================
# Chuẩn bị môi trường
# =========================
mkdir -p "$WORKDIR"
cd "$WORKDIR"

teardown() {
  echo "[cleanup] Stopping dotnet-counters, dotnet-trace, dotnet-dump, azcopy processes..."
  pkill -f "$TOOLS_DIR/dotnet-counters" || true
  pkill -f "$TOOLS_DIR/dotnet-trace"    || true
  pkill -f "$TOOLS_DIR/dotnet-dump"     || true
  pkill -f "$TOOLS_DIR/azcopy"          || true
  echo "[cleanup] Cleanup completed."
  exit 0
}
trap teardown SIGINT SIGTERM

die() { echo "[error] $1" >&2; exit "${2:-1}"; }

# =========================
# Helpers
# =========================
get_env_from_pid() {
  local pid="$1" key="$2"
  local val
  val=$(cat "/proc/$pid/environ" | tr '\0' '\n' | grep -w "$key" || true)
  val=${val#*=}
  echo "${val:-}"
}

upload_to_blob() {
  local file_path="$1" sas_url="$2"
  local attempt=1
  while [ $attempt -le $MAX_UPLOAD_RETRY ]; do
    echo "[upload] Uploading $file_path (attempt $attempt/$MAX_UPLOAD_RETRY)..."
    azcopy_output=$("$TOOLS_DIR/azcopy" copy "$file_path" "$sas_url" 2>&1 || true)
    if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
      echo "[upload] $file_path uploaded."
      return 0
    fi
    echo "[upload] Upload failed, retrying..."
    attempt=$((attempt+1))
    sleep 3
  done
  echo "[upload] Upload $file_path failed after $MAX_UPLOAD_RETRY attempts."
  return 1
}

# =========================
# Xác định PID .NET & metadata
# =========================
pid=$("$TOOLS_DIR/dotnet-dump" ps | grep "/usr/share/dotnet/dotnet" | grep -v grep | tr -s " " | cut -d" " -f2 || true)
[ -n "${pid:-}" ] || die "Could not find any running .NET process"

instance="$(get_env_from_pid "$pid" "COMPUTERNAME")"
[ -n "$instance" ] || die "Could not find COMPUTERNAME environment variable"

sas_url="$(get_env_from_pid "$pid" "DIAGNOSTICS_AZUREBLOBCONTAINERSASURL")"
[ -n "$sas_url" ] || die "Could not find DIAGNOSTICS_AZUREBLOBCONTAINERSASURL environment variable"

# =========================
# Hỏi thời lượng counters
# =========================
read -r -p "Enter dotnet-counters collection duration in seconds (default 300): " COUNTER_DURATION
COUNTER_DURATION=${COUNTER_DURATION:-300}

# =========================
# Bắt đầu COUNTERS (nền)
# =========================
echo "[counter] Starting dotnet-counters in background..."
countertrace_file="countertrace_${instance}_$(date '+%Y%m%d_%H%M%S').csv"
COUNTERS_START_TS=$(date +%s)

"$TOOLS_DIR/dotnet-counters" collect \
  --process-id "$pid" \
  --counters "$COUNTER_LIST" \
  --refresh-interval 1 \
  --format csv \
  --output "$countertrace_file" > /dev/null &
COUNTERS_PID=$!

# Đợi file counters xuất hiện (tối đa 10s)
for i in {1..10}; do
  [ -e "$countertrace_file" ] && break
  sleep 1
done

# =========================
# Chụp STACK TRACE (nhanh)
# =========================
echo "[stack] Capturing stack trace..."
stacktrace_file="stacktrace_${instance}_$(date '+%Y%m%d_%H%M%S').txt"
"$TOOLS_DIR/dotnet-stack" report -p "$pid" > "$stacktrace_file" \
  || { echo "[error] Stack trace collection failed"; rm -f "$stacktrace_file"; }
[ -s "$stacktrace_file" ] && echo "[stack] Stack trace collected." || echo "[stack] Missing or empty."

# =========================
# Thu NETTRACE (90s)
# =========================
echo "[trace] Collecting nettrace for ${TRACE_DURATION_SECONDS}s..."
trace_file="trace_${instance}_$(date '+%Y%m%d_%H%M%S').nettrace"
"$TOOLS_DIR/dotnet-trace" collect -p "$pid" --providers "Microsoft-DotNETCore-SampleProfiler,Microsoft-Windows-DotNETRuntime:0x0001C001:5,Microsoft-AspNetCore-Hosting:0xFFFFFFFFFFFFFFFF:4,Microsoft-AspNetCore-Server-Kestrel:0xFFFFFFFFFFFFFFFF:4,System.Net.Http:0xFFFFFFFFFFFFFFFF:4,System.Net.Sockets:0xFFFFFFFFFFFFFFFF:4" -o "$trace_file" --duration "00:01:30" > /dev/null \
  || { echo "[error] Nettrace collection failed"; touch "$trace_file.failed"; }
[ -s "$trace_file" ] && echo "[trace] Nettrace collected." || echo "[trace] Missing or empty."

# =========================
# Thu DUMP (cuối cùng)
# =========================
echo "[dump] Collecting memory dump (this may pause the app briefly)..."
dump_file="dump_${instance}_$(date '+%Y%m%d_%H%M%S').dmp"
"$TOOLS_DIR/dotnet-dump" collect -p "$pid" -o "$dump_file" > /dev/null \
  || { echo "[error] Memory dump collection failed"; rm -f "$dump_file"; }
[ -s "$dump_file" ] && echo "[dump] Memory dump collected." || echo "[dump] Missing or empty."

# =========================
# Đảm bảo COUNTERS chạy đủ lâu
# =========================
COUNTERS_END_TS=$(date +%s)
ELAPSED=$((COUNTERS_END_TS - COUNTERS_START_TS))
if [ "$ELAPSED" -lt "$COUNTER_DURATION" ]; then
  REMAIN=$((COUNTER_DURATION - ELAPSED))
  echo "[counter] Ensuring minimum duration, sleeping ${REMAIN}s..."
  sleep "$REMAIN" || true
fi
echo "[counter] Stopping dotnet-counters..."
kill "$COUNTERS_PID" || true
# chờ tắt hẳn
wait "$COUNTERS_PID" 2>/dev/null || true
[ -s "$countertrace_file" ] && echo "[counter] Counter trace collected." || echo "[error] Counter trace missing or empty."

# =========================
# Upload artefacts
# =========================
echo "All data have been collected, waiting for ${UPLOAD_INITIAL_DELAY}s before uploading to Blob."
sleep "$UPLOAD_INITIAL_DELAY"

if [ -e "$trace_file" ]; then
  echo "[trace] Uploading nettrace..."
  upload_to_blob "$trace_file" "$sas_url" || echo "[error] Nettrace upload failed"
  sleep "$UPLOAD_GAP"
fi

if [ -e "$dump_file" ]; then
  echo "[dump] Uploading memory dump..."
  upload_to_blob "$dump_file" "$sas_url" || echo "[error] Memory dump upload failed"
  sleep "$UPLOAD_GAP"
fi

if [ -e "$stacktrace_file" ]; then
  echo "[stack] Uploading stack trace..."
  upload_to_blob "$stacktrace_file" "$sas_url" || echo "[error] Stack trace upload failed"
  sleep "$UPLOAD_GAP"
fi

if [ -e "$countertrace_file" ]; then
  echo "[counter] Uploading counter trace..."
  upload_to_blob "$countertrace_file" "$sas_url" || echo "[error] Counter trace upload failed"
  sleep "$UPLOAD_GAP"
fi

echo "[done] All data collection and upload steps are complete. Hand off to Problem team. Have a great day!"

# =========================
# Cleanup (chỉ file đã tạo)
# =========================
echo "[cleanup] Deleting diagnostic files in $WORKDIR..."
rm -f "$trace_file" "$dump_file" "$stacktrace_file" "$countertrace_file" 2>/dev/null || true
echo "Completed"
