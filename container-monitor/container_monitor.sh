#!/usr/bin/env bash

set -uo pipefail

# Defaults
INTERVAL=1
CONTAINER=""
VERBOSE=false
EXTENDED=false
LOG_DIR="${DOCKER_MONITOR_LOG_DIR:-$HOME/logs/docker-stats}"
TIMESTAMP="$(date +%F_%H-%M-%S)"
MAX_EMPTY_STATS=3

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [OPTIONS]

Options:
  -c, --container CONTAINER
      Container name or ID. If omitted, an interactive selector using fzf is opened.

  -i, --interval SECONDS
      Sampling interval in seconds. Default: 1.

  -o, --output-dir DIR
      Directory where CSV logs are written.
      Default: \$HOME/logs/docker-stats
      Can also be configured with DOCKER_MONITOR_LOG_DIR.

  -v, --verbose
      Print live metrics to stdout while also writing the CSV file.

  -e, --extended
      Write an extended CSV with additional raw metrics:
      container_id, memory limit, cumulative network MB, and block I/O MB.

  -h, --help
      Show this help.

Default CSV columns:
  timestamp
      Sample timestamp in ISO-8601 format.

  container_name
      Docker container name.

  cpu_pct
      CPU usage percentage reported by Docker.
      Values above 100 are normal when the container uses more than one CPU core.
      Example: 250 means approximately 2.5 cores.

  mem_mb
      Current memory usage in MiB.

  mem_pct
      Memory usage percentage relative to the container memory limit.

  net_rx_mbps
      Approximate network receive rate in megabits per second.
      This is calculated from the delta between Docker cumulative NetIO samples.

  net_tx_mbps
      Approximate network transmit rate in megabits per second.
      This is calculated from the delta between Docker cumulative NetIO samples.

  pids
      Number of processes/threads currently running inside the container.

Extended CSV extra columns:
  container_id
      Short Docker container ID.

  mem_limit_mb
      Memory limit available to the container, in MiB.

  net_rx_mb
      Cumulative network data received by the container, in MiB.

  net_tx_mb
      Cumulative network data transmitted by the container, in MiB.

  block_read_mb
      Cumulative data read from block devices, in MiB.

  block_write_mb
      Cumulative data written to block devices, in MiB.

Examples:
  $(basename "$0")
  $(basename "$0") -v
  $(basename "$0") -i 2 -v
  $(basename "$0") -c my_container
  $(basename "$0") -c my_container -e -v
  $(basename "$0") -o ~/logs/docker-monitoring
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

trim() {
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

to_bytes() {
    local raw
    raw="$(echo "$1" | trim)"

    local num unit
    num="$(echo "$raw" | sed -E 's/^([0-9.]+).*/\1/')"
    unit="$(echo "$raw" | sed -E 's/^[0-9.]+//')"

    awk -v n="$num" -v u="$unit" '
        BEGIN {
            u = tolower(u)

            if (u == "b" || u == "")        m = 1
            else if (u == "kb")             m = 1000
            else if (u == "mb")             m = 1000^2
            else if (u == "gb")             m = 1000^3
            else if (u == "tb")             m = 1000^4
            else if (u == "kib")            m = 1024
            else if (u == "mib")            m = 1024^2
            else if (u == "gib")            m = 1024^3
            else if (u == "tib")            m = 1024^4
            else                            m = 1

            printf "%.0f", n * m
        }
    '
}

bytes_to_mb() {
    awk -v b="$1" 'BEGIN { printf "%.2f", b / 1024 / 1024 }'
}

bytes_per_sec_to_mbps() {
    awk -v bps="$1" 'BEGIN { printf "%.2f", (bps * 8) / 1000 / 1000 }'
}

sanitize_filename() {
    echo "$1" | sed -E 's/[^A-Za-z0-9_.-]+/_/g'
}

select_container_with_fzf() {
    require_cmd fzf

    local selected

    selected="$(
        docker ps \
            --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}' |
        fzf \
            --header='Select Docker container' \
            --with-nth=2,3,4 \
            --delimiter='\t'
    )"

    [[ -n "$selected" ]] || die "No container selected."

    echo "$selected" | awk -F'\t' '{print $1}'
}

container_exists() {
    docker inspect --type container "$1" >/dev/null 2>&1
}

container_status() {
    docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null || true
}

container_is_running() {
    [[ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null || echo false)" == "true" ]]
}

print_container_final_state() {
    local container_id="$1"

    if ! container_exists "$container_id"; then
        echo "Container no longer exists: $container_id"
        return
    fi

    local status exit_code oom_killed error started_at finished_at
    status="$(docker inspect --format '{{.State.Status}}' "$container_id")"
    exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$container_id")"
    oom_killed="$(docker inspect --format '{{.State.OOMKilled}}' "$container_id")"
    error="$(docker inspect --format '{{.State.Error}}' "$container_id")"
    started_at="$(docker inspect --format '{{.State.StartedAt}}' "$container_id")"
    finished_at="$(docker inspect --format '{{.State.FinishedAt}}' "$container_id")"

    echo
    echo "Container finished."
    echo "  status      : $status"
    echo "  exit_code   : $exit_code"
    echo "  oom_killed  : $oom_killed"
    echo "  started_at  : $started_at"
    echo "  finished_at : $finished_at"

    if [[ -n "$error" ]]; then
        echo "  error       : $error"
    fi
}

cleanup() {
    if [[ -n "${WAIT_PID:-}" ]] && kill -0 "$WAIT_PID" >/dev/null 2>&1; then
        kill "$WAIT_PID" >/dev/null 2>&1 || true
        wait "$WAIT_PID" >/dev/null 2>&1 || true
    fi

    [[ -n "${WAIT_FILE:-}" && -f "$WAIT_FILE" ]] && rm -f "$WAIT_FILE"
}

graceful_shutdown() {
    local reason="$1"

    echo
    echo "$reason"

    if [[ -n "${CONTAINER_ID:-}" ]]; then
        print_container_final_state "$CONTAINER_ID"
    fi

    echo
    echo "CSV saved at: $OUTFILE"

    cleanup
    exit 0
}

write_header() {
    if [[ "$EXTENDED" == true ]]; then
        cat > "$OUTFILE" <<EOF
timestamp,container_id,container_name,cpu_pct,mem_mb,mem_pct,mem_limit_mb,net_rx_mbps,net_tx_mbps,net_rx_mb,net_tx_mb,block_read_mb,block_write_mb,pids
EOF
    else
        cat > "$OUTFILE" <<EOF
timestamp,container_name,cpu_pct,mem_mb,mem_pct,net_rx_mbps,net_tx_mbps,pids
EOF
    fi
}

print_verbose_header() {
    if [[ "$EXTENDED" == true ]]; then
        printf '%-25s %-20s %8s %10s %8s %12s %12s %12s %12s %10s %10s %6s\n' \
            "timestamp" "container" "cpu%" "mem_mb" "mem%" "rx_mbps" "tx_mbps" "rx_mb" "tx_mb" "blk_r_mb" "blk_w_mb" "pids"
    else
        printf '%-25s %-20s %8s %10s %8s %12s %12s %6s\n' \
            "timestamp" "container" "cpu%" "mem_mb" "mem%" "rx_mbps" "tx_mbps" "pids"
    fi
}

print_verbose_row() {
    if [[ "$EXTENDED" == true ]]; then
        printf '%-25s %-20s %8s %10s %8s %12s %12s %12s %12s %10s %10s %6s\n' \
            "$TIMESTAMP_LINE" \
            "$STAT_NAME" \
            "$CPU_PERCENT" \
            "$MEM_MB" \
            "$MEM_PERCENT" \
            "$NET_RX_MBPS" \
            "$NET_TX_MBPS" \
            "$NET_RX_MB" \
            "$NET_TX_MB" \
            "$BLOCK_READ_MB" \
            "$BLOCK_WRITE_MB" \
            "$PIDS"
    else
        printf '%-25s %-20s %8s %10s %8s %12s %12s %6s\n' \
            "$TIMESTAMP_LINE" \
            "$STAT_NAME" \
            "$CPU_PERCENT" \
            "$MEM_MB" \
            "$MEM_PERCENT" \
            "$NET_RX_MBPS" \
            "$NET_TX_MBPS" \
            "$PIDS"
    fi
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -c|--container|--container-name)
            [[ $# -ge 2 ]] || die "Missing value for $1"
            CONTAINER="$2"
            shift 2
            ;;
        -i|--interval)
            [[ $# -ge 2 ]] || die "Missing value for $1"
            INTERVAL="$2"
            shift 2
            ;;
        -o|--output-dir)
            [[ $# -ge 2 ]] || die "Missing value for $1"
            LOG_DIR="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -e|--extended)
            EXTENDED=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

require_cmd docker

[[ "$INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Interval must be numeric."

if [[ -z "$CONTAINER" ]]; then
    CONTAINER="$(select_container_with_fzf)"
fi

container_exists "$CONTAINER" || die "Container not found: $CONTAINER"

CONTAINER_ID="$(docker inspect --format '{{.Id}}' "$CONTAINER" | cut -c1-12)"
CONTAINER_NAME="$(docker inspect --format '{{.Name}}' "$CONTAINER" | sed 's#^/##')"
SAFE_CONTAINER_NAME="$(sanitize_filename "$CONTAINER_NAME")"

mkdir -p "$LOG_DIR"

OUTFILE="$LOG_DIR/${SAFE_CONTAINER_NAME}_stats_${TIMESTAMP}.csv"
write_header

if ! container_is_running "$CONTAINER_ID"; then
    echo "Container is not running at monitor startup."
    print_container_final_state "$CONTAINER_ID"
    echo
    echo "CSV saved at: $OUTFILE"
    exit 0
fi

WAIT_FILE="$(mktemp)"
docker wait "$CONTAINER_ID" > "$WAIT_FILE" 2>/dev/null &
WAIT_PID=$!

trap 'graceful_shutdown "Monitoring interrupted by user."' INT TERM

echo "Writing Docker stats to: $OUTFILE"
echo "Container: $CONTAINER_NAME ($CONTAINER_ID)"
echo "Mode: $([[ "$EXTENDED" == true ]] && echo "extended" || echo "minimal")"
echo "Press Ctrl+C to stop."

if [[ "$VERBOSE" == true ]]; then
    print_verbose_header
fi

EMPTY_STATS_COUNT=0
PREV_NET_RX_BYTES=""
PREV_NET_TX_BYTES=""
PREV_SAMPLE_EPOCH=""

while true; do
    if ! kill -0 "$WAIT_PID" >/dev/null 2>&1; then
        wait "$WAIT_PID" >/dev/null 2>&1 || true
        DOCKER_EXIT_CODE="$(cat "$WAIT_FILE" 2>/dev/null || true)"
        graceful_shutdown "Container stopped. docker_exit_code=${DOCKER_EXIT_CODE:-unknown}"
    fi

    STATS_LINE="$(
        docker stats \
            --no-stream \
            --format '{{.Container}},{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}},{{.BlockIO}},{{.PIDs}}' \
            "$CONTAINER_ID" 2>/dev/null
    )"

    if [[ -z "$STATS_LINE" ]]; then
        EMPTY_STATS_COUNT=$((EMPTY_STATS_COUNT + 1))
        STATUS="$(container_status "$CONTAINER_ID")"

        if [[ "$STATUS" != "running" ]]; then
            graceful_shutdown "No stats returned because container is no longer running. status=${STATUS:-unknown}"
        fi

        if (( EMPTY_STATS_COUNT >= MAX_EMPTY_STATS )); then
            graceful_shutdown "No stats returned after ${MAX_EMPTY_STATS} attempts while container status is running. Stopping monitor to avoid an infinite loop."
        fi

        echo "Warning: no stats returned for container: $CONTAINER_NAME ($EMPTY_STATS_COUNT/$MAX_EMPTY_STATS)" >&2
        sleep "$INTERVAL"
        continue
    fi

    EMPTY_STATS_COUNT=0

    IFS=',' read -r STAT_CONTAINER_ID STAT_NAME CPU_PERC MEM_USAGE MEM_PERC NET_IO BLOCK_IO PIDS <<< "$STATS_LINE"

    CPU_PERCENT="$(echo "$CPU_PERC" | tr -d '%')"
    MEM_PERCENT="$(echo "$MEM_PERC" | tr -d '%')"

    MEM_USAGE_RAW="$(echo "$MEM_USAGE" | awk -F' / ' '{print $1}')"
    MEM_LIMIT_RAW="$(echo "$MEM_USAGE" | awk -F' / ' '{print $2}')"

    NET_RX_RAW="$(echo "$NET_IO" | awk -F' / ' '{print $1}')"
    NET_TX_RAW="$(echo "$NET_IO" | awk -F' / ' '{print $2}')"

    BLOCK_READ_RAW="$(echo "$BLOCK_IO" | awk -F' / ' '{print $1}')"
    BLOCK_WRITE_RAW="$(echo "$BLOCK_IO" | awk -F' / ' '{print $2}')"

    MEM_USAGE_BYTES="$(to_bytes "$MEM_USAGE_RAW")"
    MEM_LIMIT_BYTES="$(to_bytes "$MEM_LIMIT_RAW")"
    NET_RX_BYTES="$(to_bytes "$NET_RX_RAW")"
    NET_TX_BYTES="$(to_bytes "$NET_TX_RAW")"
    BLOCK_READ_BYTES="$(to_bytes "$BLOCK_READ_RAW")"
    BLOCK_WRITE_BYTES="$(to_bytes "$BLOCK_WRITE_RAW")"

    CURRENT_SAMPLE_EPOCH="$(date +%s)"
    TIMESTAMP_LINE="$(date -Iseconds)"

    MEM_MB="$(bytes_to_mb "$MEM_USAGE_BYTES")"
    MEM_LIMIT_MB="$(bytes_to_mb "$MEM_LIMIT_BYTES")"
    NET_RX_MB="$(bytes_to_mb "$NET_RX_BYTES")"
    NET_TX_MB="$(bytes_to_mb "$NET_TX_BYTES")"
    BLOCK_READ_MB="$(bytes_to_mb "$BLOCK_READ_BYTES")"
    BLOCK_WRITE_MB="$(bytes_to_mb "$BLOCK_WRITE_BYTES")"

    NET_RX_MBPS="0.00"
    NET_TX_MBPS="0.00"

    if [[ -n "$PREV_NET_RX_BYTES" && -n "$PREV_NET_TX_BYTES" && -n "$PREV_SAMPLE_EPOCH" ]]; then
        ELAPSED_SECONDS=$((CURRENT_SAMPLE_EPOCH - PREV_SAMPLE_EPOCH))

        if (( ELAPSED_SECONDS > 0 )); then
            NET_RX_DELTA=$((NET_RX_BYTES - PREV_NET_RX_BYTES))
            NET_TX_DELTA=$((NET_TX_BYTES - PREV_NET_TX_BYTES))

            if (( NET_RX_DELTA < 0 )); then NET_RX_DELTA=0; fi
            if (( NET_TX_DELTA < 0 )); then NET_TX_DELTA=0; fi

            NET_RX_BPS=$((NET_RX_DELTA / ELAPSED_SECONDS))
            NET_TX_BPS=$((NET_TX_DELTA / ELAPSED_SECONDS))

            NET_RX_MBPS="$(bytes_per_sec_to_mbps "$NET_RX_BPS")"
            NET_TX_MBPS="$(bytes_per_sec_to_mbps "$NET_TX_BPS")"
        fi
    fi

    PREV_NET_RX_BYTES="$NET_RX_BYTES"
    PREV_NET_TX_BYTES="$NET_TX_BYTES"
    PREV_SAMPLE_EPOCH="$CURRENT_SAMPLE_EPOCH"

    if [[ "$EXTENDED" == true ]]; then
        OUTPUT_LINE="${TIMESTAMP_LINE},${STAT_CONTAINER_ID},${STAT_NAME},${CPU_PERCENT},${MEM_MB},${MEM_PERCENT},${MEM_LIMIT_MB},${NET_RX_MBPS},${NET_TX_MBPS},${NET_RX_MB},${NET_TX_MB},${BLOCK_READ_MB},${BLOCK_WRITE_MB},${PIDS}"
    else
        OUTPUT_LINE="${TIMESTAMP_LINE},${STAT_NAME},${CPU_PERCENT},${MEM_MB},${MEM_PERCENT},${NET_RX_MBPS},${NET_TX_MBPS},${PIDS}"
    fi

    echo "$OUTPUT_LINE" >> "$OUTFILE"

    if [[ "$VERBOSE" == true ]]; then
        print_verbose_row
    fi

    sleep "$INTERVAL"
done
