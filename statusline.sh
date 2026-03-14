#!/bin/bash
# Claude Code statusline with usage limits
input=$(cat)

# === Extract from JSON ===
current_dir=$(echo "$input" | jq -r '.workspace.current_dir')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir')
model_name=$(echo "$input" | jq -r '.model.display_name')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
transcript=$(echo "$input" | jq -r '.transcript_path')
mcps=$(echo "$input" | jq -r '.mcpServers // [] | length')

# === Git branch ===
cd "$current_dir" 2>/dev/null || cd "$project_dir" 2>/dev/null
branch=$(git -c core.useReplaceRefs=false -c gc.auto=0 branch --show-current 2>/dev/null)
project=$(basename "$current_dir")

# === Session time ===
if [ -f "$transcript" ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        start=$(stat -f %B "$transcript" 2>/dev/null)
    else
        start=$(stat -c %Y "$transcript" 2>/dev/null)
    fi
    if [ -n "$start" ]; then
        elapsed=$(( $(date +%s) - start ))
        mins=$(( elapsed / 60 ))
        if [ $mins -ge 60 ]; then
            session_time="$((mins / 60))h $((mins % 60))m"
        else
            session_time="${mins}m"
        fi
    else
        session_time="0m"
    fi
else
    session_time="0m"
fi

# === Context bar ===
used_int=$(printf "%.0f" "$used_pct")
context_tokens=$(echo "$used_pct $context_size" | awk '{printf "%.0f", $1 * $2 / 100}')
if [ "$context_tokens" -ge 1000 ] 2>/dev/null; then
    tokens_display="$((context_tokens / 1000))K"
else
    tokens_display="${context_tokens}"
fi
if [ "$context_size" -ge 1000 ] 2>/dev/null; then
    context_display="$((context_size / 1000))K"
else
    context_display="${context_size}"
fi

bar_len=6
filled=$((used_int * bar_len / 100))
empty=$((bar_len - filled))
if [ "$used_int" -lt 50 ]; then
    ctx_color="\033[32m"
elif [ "$used_int" -lt 80 ]; then
    ctx_color="\033[33m"
else
    ctx_color="\033[31m"
fi
bar="${ctx_color}"
for ((i=0; i<filled; i++)); do bar+="━"; done
for ((i=0; i<empty; i++)); do bar+="━"; done
bar+="\033[0m"

# === Usage limits (cached, refresh every 2 min) ===
CACHE_FILE="$HOME/.claude/.usage-cache.json"
CACHE_TTL=120
WEEK_RECOVERY_CACHE="$HOME/.claude/.week-recovery-cache.txt"
WEEK_RECOVERY_TTL=300

fetch_usage() {
    local token cred_json

    # Step 1: Read raw credentials JSON from platform-specific secure storage
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: Keychain Access
        cred_json=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    elif [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "cygwin"* || "$OSTYPE" == "win"* ]]; then
        # Windows (Git Bash / MSYS2 / Cygwin): Credential Manager via PowerShell
        cred_json=$(powershell.exe -NoProfile -Command \
            '[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String((Get-StoredCredential -Target "Claude Code-credentials" -AsCredentialObject).Password))' 2>/dev/null)
    else
        # Linux: GNOME Keyring / KWallet via libsecret
        cred_json=$(secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        # Fallback: file-based credentials (used when no keyring available)
        if [ -z "$cred_json" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
            cred_json=$(cat "$HOME/.claude/.credentials.json")
        fi
    fi

    # Step 2: Extract OAuth access token from JSON
    if [ -n "$cred_json" ]; then
        token=$(echo "$cred_json" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)
    fi

    # Step 3: Call Anthropic usage API
    if [ -n "$token" ]; then
        curl -sf --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "Accept: application/json" 2>/dev/null
    fi
}

get_usage() {
    local now cache_time
    now=$(date +%s)
    cache_time=0

    if [ -f "$CACHE_FILE" ]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            cache_time=$(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
        else
            cache_time=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
        fi
    fi

    if [ $((now - cache_time)) -gt $CACHE_TTL ]; then
        local data
        data=$(fetch_usage)
        if [ -n "$data" ] && echo "$data" | jq -e '.five_hour' >/dev/null 2>&1; then
            umask 077
            echo "$data" > "$CACHE_FILE"
        fi
    fi

    if [ -f "$CACHE_FILE" ]; then
        cat "$CACHE_FILE"
    fi
}

usage_color() {
    local val=$1
    if [ "$val" -gt 50 ] 2>/dev/null; then
        echo "\033[32m"
    elif [ "$val" -gt 20 ] 2>/dev/null; then
        echo "\033[33m"
    else
        echo "\033[31m"
    fi
}

get_week_recovery() {
    # Returns "+5%:Xh +10%:Yh" based on rolling 7-day window analysis
    # Uses JSONL files to estimate when old usage rolls off the window
    local week_used="$1"
    local now cache_time
    now=$(date +%s)
    cache_time=0

    if [ -f "$WEEK_RECOVERY_CACHE" ]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            cache_time=$(stat -f %m "$WEEK_RECOVERY_CACHE" 2>/dev/null || echo 0)
        else
            cache_time=$(stat -c %Y "$WEEK_RECOVERY_CACHE" 2>/dev/null || echo 0)
        fi
    fi

    if [ $((now - cache_time)) -gt $WEEK_RECOVERY_TTL ]; then
        local result
        result=$(python3 -c "
import json, glob, os, sys
from datetime import datetime, timezone, timedelta

week_used = float(sys.argv[1])
if week_used <= 0:
    sys.exit(0)

projects_dir = os.path.expanduser('~/.claude/projects')
day_tokens = {}
now = datetime.now(timezone.utc)

for fpath in glob.glob(os.path.join(projects_dir, '**/*.jsonl'), recursive=True):
    try:
        with open(fpath) as f:
            for line in f:
                try:
                    r = json.loads(line.strip())
                    ts = r.get('timestamp', '')
                    msg = r.get('message', {})
                    usage = msg.get('usage') if isinstance(msg, dict) else None
                    if not usage or not ts:
                        continue
                    dt = datetime.fromisoformat(ts.replace('Z', '+00:00'))
                    age_h = (now - dt).total_seconds() / 3600
                    if age_h > 168:
                        continue
                    day = dt.strftime('%Y-%m-%d')
                    day_tokens[day] = day_tokens.get(day, 0) + sum(
                        (usage.get(k) or 0) for k in
                        ['input_tokens', 'output_tokens',
                         'cache_creation_input_tokens', 'cache_read_input_tokens'])
                except Exception:
                    pass
    except Exception:
        pass

weekly_total = sum(day_tokens.values())
if weekly_total == 0:
    sys.exit(0)

# Rolling window: day N days ago rolls off between (6-N)*24 and (7-N)*24 hours from now.
# Midpoint estimate: (6-N)*24 + 12 hours.
# days_ago=6 -> 12h, days_ago=5 -> 36h, days_ago=4 -> 60h, etc.
targets = {5: None, 10: None}
cumulative = 0.0

for days_ago in range(6, -1, -1):
    day = (now - timedelta(days=days_ago)).strftime('%Y-%m-%d')
    day_pct = (day_tokens.get(day, 0) / weekly_total) * week_used
    midpoint_h = (6 - days_ago) * 24 + 12
    cumulative += day_pct
    for t in [5, 10]:
        if targets[t] is None and cumulative >= t:
            targets[t] = midpoint_h

parts = []
for t in [5, 10]:
    h = targets[t]
    if h is not None:
        if h < 2:
            parts.append(f'↑{t}%:now')
        elif h < 24:
            parts.append(f'↑{t}%:{int(h)}h')
        else:
            d, hh = int(h) // 24, int(h) % 24
            parts.append(f'↑{t}%:{d}d{hh}h' if hh else f'↑{t}%:{d}d')
print(' '.join(parts))
" "$week_used" 2>/dev/null)
        umask 077
        echo "$result" > "$WEEK_RECOVERY_CACHE"
    fi

    if [ -f "$WEEK_RECOVERY_CACHE" ]; then
        cat "$WEEK_RECOVERY_CACHE"
    fi
}

usage_data=$(get_usage)
limits_part=""

if [ -n "$usage_data" ]; then
    five_h_used=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0')
    week_used=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0')
    five_h_reset=$(echo "$usage_data" | jq -r '.five_hour.resets_at // ""')

    five_h_left=$(python3 -c "import sys; print(int(100 - float(sys.argv[1])))" "$five_h_used" 2>/dev/null || echo "?")
    week_left=$(python3 -c "import sys; print(int(100 - float(sys.argv[1])))" "$week_used" 2>/dev/null || echo "?")

    time_left=""
    if [ -n "$five_h_reset" ] && [ "$five_h_reset" != "null" ]; then
        time_left=$(python3 -c "
import sys
from datetime import datetime, timezone
try:
    reset = datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00'))
    now = datetime.now(timezone.utc)
    diff = reset - now
    s = int(diff.total_seconds())
    if s < 0:
        print('')
    elif s >= 3600:
        print(f'{s // 3600}h{(s % 3600) // 60}m')
    else:
        print(f'{(s % 3600) // 60}m')
except Exception:
    print('')
" "$five_h_reset" 2>/dev/null)
    fi

    week_recovery=$(get_week_recovery "$week_used")

    five_color=$(usage_color "$five_h_left")
    week_color=$(usage_color "$week_left")

    week_part="${week_color}W:${week_left}%\033[0m"
    [ -n "$week_recovery" ] && week_part+=" \033[36m${week_recovery}\033[0m"

    if [ -n "$time_left" ]; then
        limits_part="${five_color}H:${five_h_left}% ${time_left}\033[0m ${week_part}"
    else
        limits_part="${five_color}H:${five_h_left}%\033[0m ${week_part}"
    fi
fi

# === Build output ===
parts=("[${model_name}]")
parts+=("${bar} ${used_int}% (${tokens_display}/${context_display})")

if [ -n "$limits_part" ]; then
    parts+=("$limits_part")
fi

parts+=("${project}")
[ -n "$branch" ] && parts+=("git:(${branch})")
[ "$mcps" -gt 0 ] 2>/dev/null && parts+=("${mcps} MCPs")
parts+=("⏱ ${session_time}")

result=""
for i in "${!parts[@]}"; do
    if [ "$i" -eq 0 ]; then
        result="${parts[$i]}"
    else
        result="$result | ${parts[$i]}"
    fi
done

printf '%b\n' "$result"
