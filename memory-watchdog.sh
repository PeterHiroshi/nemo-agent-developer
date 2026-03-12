#!/bin/bash
# Memory Watchdog for Cloudflare Container
#
# Monitors memory usage and takes progressive action to prevent OOM kills:
# 1. WARNING (80%): Log warning
# 2. SOFT LIMIT (85%): Clear caches and temp files
# 3. HARD LIMIT (90%): Kill the largest claude/node child processes (not openclaw gateway)
# 4. CRITICAL (95%): Emergency - kill all non-essential processes
#
# The watchdog protects the main OpenClaw gateway process at all costs.

set -euo pipefail

WARN_THRESHOLD=${MEM_WARN_THRESHOLD:-80}
SOFT_THRESHOLD=${MEM_SOFT_THRESHOLD:-85}
HARD_THRESHOLD=${MEM_HARD_THRESHOLD:-90}
CRITICAL_THRESHOLD=${MEM_CRITICAL_THRESHOLD:-95}
CHECK_INTERVAL=${MEM_CHECK_INTERVAL:-5}
LOGFILE="/tmp/memory-watchdog.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [watchdog] $*" | tee -a "$LOGFILE"
}

# Get memory usage percentage from cgroup v2 or fallback to /proc/meminfo
get_memory_usage_pct() {
    # Try cgroup v2 first (Cloudflare containers likely use this)
    if [ -f /sys/fs/cgroup/memory.current ] && [ -f /sys/fs/cgroup/memory.max ]; then
        local current max
        current=$(cat /sys/fs/cgroup/memory.current)
        max=$(cat /sys/fs/cgroup/memory.max)
        if [ "$max" != "max" ] && [ "$max" -gt 0 ] 2>/dev/null; then
            echo $(( current * 100 / max ))
            return
        fi
    fi

    # Try cgroup v1
    if [ -f /sys/fs/cgroup/memory/memory.usage_in_bytes ] && [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        local current max
        current=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes)
        max=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
        # cgroup v1 uses a very large number for "unlimited"
        if [ "$max" -lt 100000000000 ] 2>/dev/null; then
            echo $(( current * 100 / max ))
            return
        fi
    fi

    # Fallback to /proc/meminfo
    local total available
    total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    if [ "$total" -gt 0 ] 2>/dev/null; then
        echo $(( (total - available) * 100 / total ))
        return
    fi

    echo 0
}

# Get memory info in human readable format
get_memory_info() {
    if [ -f /sys/fs/cgroup/memory.current ] && [ -f /sys/fs/cgroup/memory.max ]; then
        local current max
        current=$(cat /sys/fs/cgroup/memory.current)
        max=$(cat /sys/fs/cgroup/memory.max)
        if [ "$max" != "max" ] && [ "$max" -gt 0 ] 2>/dev/null; then
            echo "$(( current / 1048576 ))MB / $(( max / 1048576 ))MB"
            return
        fi
    fi
    local total available
    total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    echo "$(( (total - available) / 1024 ))MB / $(( total / 1024 ))MB"
}

# Clear system caches and temp files
clear_caches() {
    log "ACTION: Clearing caches and temp files"

    # Drop page cache, dentries, inodes
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    # Clean npm/pnpm cache
    npm cache clean --force 2>/dev/null || true
    pnpm store prune 2>/dev/null || true

    # Clean temp files
    find /tmp -type f -name '*.tmp' -mmin +5 -delete 2>/dev/null || true
    find /tmp -type f -name '*.log' -size +10M -delete 2>/dev/null || true

    # Clean node_modules caches
    find /root -path '*/node_modules/.cache' -type d -exec rm -rf {} + 2>/dev/null || true

    log "Caches cleared"
}

# Get the PID of the main openclaw gateway process (the one we must protect)
get_gateway_pid() {
    pgrep -f "openclaw gateway" | head -1 2>/dev/null || echo ""
}

# Kill largest non-gateway node/claude processes by memory usage
kill_largest_children() {
    local gateway_pid
    gateway_pid=$(get_gateway_pid)

    log "ACTION: Killing largest child processes (protecting gateway PID: ${gateway_pid:-unknown})"

    # Find all node processes sorted by RSS (descending), excluding the gateway itself
    # This targets Claude Code processes and other spawned agents
    local killed=0
    while IFS= read -r line; do
        local pid rss cmd
        pid=$(echo "$line" | awk '{print $1}')
        rss=$(echo "$line" | awk '{print $2}')
        cmd=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}')

        # Skip the gateway process itself and its direct parent
        if [ -n "$gateway_pid" ] && [ "$pid" = "$gateway_pid" ]; then
            continue
        fi

        # Skip this watchdog script
        if [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ]; then
            continue
        fi

        # Skip essential system processes (PID 1, rclone sync)
        if [ "$pid" -le 2 ] 2>/dev/null; then
            continue
        fi

        # Only kill processes using significant memory (>100MB)
        if [ "$rss" -gt 102400 ] 2>/dev/null; then
            log "KILL: PID=$pid RSS=$(( rss / 1024 ))MB CMD=$cmd"
            kill -TERM "$pid" 2>/dev/null || true
            killed=$((killed + 1))
            # Kill at most 2 processes per cycle to avoid disruption
            if [ "$killed" -ge 2 ]; then
                break
            fi
        fi
    done < <(ps aux --sort=-%mem | awk 'NR>1 {print $2, $6, $11, $12, $13}' 2>/dev/null || true)

    if [ "$killed" -eq 0 ]; then
        log "No large child processes found to kill"
    else
        log "Killed $killed processes"
        # Give processes time to clean up
        sleep 2
        # Force kill if still running
        while IFS= read -r line; do
            local pid
            pid=$(echo "$line" | awk '{print $1}')
            if [ -n "$gateway_pid" ] && [ "$pid" = "$gateway_pid" ]; then
                continue
            fi
            if [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ]; then
                continue
            fi
            kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
        done < <(ps aux --sort=-%mem | awk 'NR>1 && $6>102400 {print $2}' 2>/dev/null || true)
    fi
}

# Emergency: kill everything except gateway and essential processes
emergency_kill() {
    local gateway_pid
    gateway_pid=$(get_gateway_pid)

    log "EMERGENCY: Memory critical! Killing ALL non-essential processes"

    # Kill all node processes except the gateway
    while IFS= read -r pid; do
        if [ -n "$gateway_pid" ] && [ "$pid" = "$gateway_pid" ]; then
            continue
        fi
        if [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ]; then
            continue
        fi
        if [ "$pid" -le 2 ] 2>/dev/null; then
            continue
        fi
        log "EMERGENCY KILL: PID=$pid"
        kill -KILL "$pid" 2>/dev/null || true
    done < <(pgrep -f "node|claude|npx" 2>/dev/null || true)
}

# ============================================================
# Main loop
# ============================================================

log "Memory watchdog started"
log "Thresholds: WARN=${WARN_THRESHOLD}% SOFT=${SOFT_THRESHOLD}% HARD=${HARD_THRESHOLD}% CRITICAL=${CRITICAL_THRESHOLD}%"
log "Check interval: ${CHECK_INTERVAL}s"
log "Initial memory: $(get_memory_info) ($(get_memory_usage_pct)%)"

last_action_level=0

while true; do
    sleep "$CHECK_INTERVAL"

    mem_pct=$(get_memory_usage_pct)

    if [ "$mem_pct" -ge "$CRITICAL_THRESHOLD" ]; then
        log "CRITICAL: Memory at ${mem_pct}% ($(get_memory_info)) - threshold: ${CRITICAL_THRESHOLD}%"
        clear_caches
        emergency_kill
        last_action_level=4
    elif [ "$mem_pct" -ge "$HARD_THRESHOLD" ]; then
        log "HARD LIMIT: Memory at ${mem_pct}% ($(get_memory_info)) - threshold: ${HARD_THRESHOLD}%"
        if [ "$last_action_level" -lt 3 ]; then
            clear_caches
        fi
        kill_largest_children
        last_action_level=3
    elif [ "$mem_pct" -ge "$SOFT_THRESHOLD" ]; then
        if [ "$last_action_level" -lt 2 ]; then
            log "SOFT LIMIT: Memory at ${mem_pct}% ($(get_memory_info)) - threshold: ${SOFT_THRESHOLD}%"
            clear_caches
            last_action_level=2
        fi
    elif [ "$mem_pct" -ge "$WARN_THRESHOLD" ]; then
        if [ "$last_action_level" -lt 1 ]; then
            log "WARNING: Memory at ${mem_pct}% ($(get_memory_info)) - threshold: ${WARN_THRESHOLD}%"
            last_action_level=1
        fi
    else
        # Memory is back to normal
        if [ "$last_action_level" -gt 0 ]; then
            log "RECOVERED: Memory at ${mem_pct}% ($(get_memory_info))"
        fi
        last_action_level=0
    fi
done
