#!/usr/bin/env bash
# Claude Code statusline — Starship-inspired single line (portable)
set -f  # disable globbing

input=$(cat)
if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ── Extract all fields in a single jq call ──────────────────────────
IFS=$'\t' read -r MODEL CWD PCT COST DURATION_MS LINES_ADD LINES_DEL VERSION \
    CTX_SIZE INPUT_TOK CACHE_CREATE CACHE_READ < <(
  echo "$input" | jq -r '[
    (.model.display_name // "?"),
    (.workspace.current_dir // .cwd // "."),
    (.context_window.used_percentage // 0),
    (.cost.total_cost_usd // 0),
    (.cost.total_duration_ms // 0),
    (.cost.total_lines_added // 0),
    (.cost.total_lines_removed // 0),
    (.version // ""),
    (.context_window.context_window_size // 200000),
    (.context_window.current_usage.input_tokens // 0),
    (.context_window.current_usage.cache_creation_input_tokens // 0),
    (.context_window.current_usage.cache_read_input_tokens // 0)
  ] | join("\t")'
)

# ── Colors (bright-black instead of DIM for WSL compat) ─────────────
BOLD='\033[1m'
DIM='\033[90m'
RESET='\033[0m'
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
ORANGE='\033[38;2;255;176;85m'
CYAN='\033[36m'
MAGENTA='\033[35m'
BLUE='\033[34m'
WHITE='\033[37m'

# ── Symbols (Nerd Font) ─────────────────────────────────────────────
SEP="${DIM}│${RESET}"

# ── Helpers ──────────────────────────────────────────────────────────
format_tokens() {
    local n=$1
    if [ "$n" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fm\", $n / 1000000}"
    elif [ "$n" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $n / 1000}"
    else
        printf "%d" "$n"
    fi
}

usage_color() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf '%s' "$RED"
    elif [ "$pct" -ge 70 ]; then printf '%s' "$ORANGE"
    elif [ "$pct" -ge 50 ]; then printf '%s' "$YELLOW"
    else printf '%s' "$GREEN"
    fi
}

# ── Folder ───────────────────────────────────────────────────────────
FOLDER=$(basename "$CWD" 2>/dev/null || echo "?")

# ── Git ──────────────────────────────────────────────────────────────
BRANCH=""
GIT_DIRTY=""
if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BRANCH=$(git -C "$CWD" symbolic-ref --short HEAD 2>/dev/null \
          || git -C "$CWD" rev-parse --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$CWD" status --porcelain 2>/dev/null | head -1)" ]; then
        GIT_DIRTY="!"
    fi
fi

# ── Duration ─────────────────────────────────────────────────────────
DURATION_SEC=$((DURATION_MS / 1000))
MINS=$((DURATION_SEC / 60))
SECS=$((DURATION_SEC % 60))
if [ "$MINS" -gt 0 ]; then TIME_FMT="${MINS}m${SECS}s"
else TIME_FMT="${SECS}s"; fi

# ── Cost ─────────────────────────────────────────────────────────────
COST_FMT=$(printf '$%.2f' "$COST")

# ── Token counts ─────────────────────────────────────────────────────
CURRENT_TOK=$(( INPUT_TOK + CACHE_CREATE + CACHE_READ ))
USED_FMT=$(format_tokens "$CURRENT_TOK")
TOTAL_FMT=$(format_tokens "$CTX_SIZE")

# ── Context bar (8-wide) ────────────────────────────────────────────
BAR_WIDTH=8
FILLED=$((PCT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))
BAR_COLOR=$(usage_color "$PCT")
BAR=""
for ((i=0; i<FILLED; i++)); do BAR+="▓"; done
for ((i=0; i<EMPTY;  i++)); do BAR+="░"; done

# ── Effort level ─────────────────────────────────────────────────────
claude_config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
EFFORT="medium"
if [ -n "$CLAUDE_CODE_EFFORT_LEVEL" ]; then
    EFFORT="$CLAUDE_CODE_EFFORT_LEVEL"
elif [ -f "$claude_config_dir/settings.json" ]; then
    val=$(jq -r '.effortLevel // empty' "$claude_config_dir/settings.json" 2>/dev/null)
    [ -n "$val" ] && EFFORT="$val"
fi
case "$EFFORT" in
    low)    EFFORT_FMT="${DIM}lo${RESET}" ;;
    high)   EFFORT_FMT="${GREEN}hi${RESET}" ;;
    *)      EFFORT_FMT="${ORANGE}md${RESET}" ;;
esac

# ── OAuth token (cross-platform) ────────────────────────────────────
get_oauth_token() {
    # 1. Env var override
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        echo "$CLAUDE_CODE_OAUTH_TOKEN"; return 0
    fi
    # 2. macOS Keychain
    if command -v security >/dev/null 2>&1; then
        local blob
        blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            local t
            t=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            [ -n "$t" ] && [ "$t" != "null" ] && { echo "$t"; return 0; }
        fi
    fi
    # 3. Linux credentials file
    local creds="$claude_config_dir/.credentials.json"
    if [ -f "$creds" ]; then
        local t
        t=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null)
        [ -n "$t" ] && [ "$t" != "null" ] && { echo "$t"; return 0; }
    fi
    # 4. GNOME Keyring
    if command -v secret-tool >/dev/null 2>&1; then
        local blob
        blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        if [ -n "$blob" ]; then
            local t
            t=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            [ -n "$t" ] && [ "$t" != "null" ] && { echo "$t"; return 0; }
        fi
    fi
    echo ""
}

# ── Rate limits (cached 60s) ────────────────────────────────────────
cache_file="/tmp/claude/statusline-usage-cache.json"
cache_max_age=60
mkdir -p /tmp/claude

needs_refresh=true
usage_data=""

if [ -f "$cache_file" ]; then
    cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
    now=$(date +%s)
    if [ $(( now - cache_mtime )) -lt "$cache_max_age" ]; then
        needs_refresh=false
    fi
    usage_data=$(cat "$cache_file" 2>/dev/null)
fi

if $needs_refresh; then
    touch "$cache_file" 2>/dev/null
    token=$(get_oauth_token)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        resp=$(curl -s --max-time 5 \
            -H "Accept: application/json" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        if [ -n "$resp" ] && echo "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
            usage_data="$resp"
            echo "$resp" > "$cache_file"
        fi
    fi
fi

# Format reset time to local HH:MM or "Mon D, HH:MM"
format_reset() {
    local iso="$1" style="$2"
    { [ -z "$iso" ] || [ "$iso" = "null" ]; } && return
    local epoch
    epoch=$(date -d "$iso" +%s 2>/dev/null)
    if [ -z "$epoch" ]; then
        local s="${iso%%.*}"; s="${s%%Z}"; s="${s%%+*}"
        if [[ "$iso" == *"Z"* ]] || [[ "$iso" == *"+00:00"* ]]; then
            epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$s" +%s 2>/dev/null)
        else
            epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$s" +%s 2>/dev/null)
        fi
    fi
    [ -z "$epoch" ] && return
    case "$style" in
        time)     date -d "@$epoch" +"%H:%M" 2>/dev/null || date -j -r "$epoch" +"%H:%M" 2>/dev/null ;;
        datetime) date -d "@$epoch" +"%b %-d %H:%M" 2>/dev/null || date -j -r "$epoch" +"%b %-d %H:%M" 2>/dev/null ;;
    esac
}

# ── Build line ───────────────────────────────────────────────────────
L=""

# Git segment
if [ -n "$BRANCH" ]; then
    L+="${GREEN}⌲${RESET} ${CYAN}${BOLD}${BRANCH}${RESET}"
    [ -n "$GIT_DIRTY" ] && L+="${YELLOW}!${RESET}"
    if [ "$LINES_ADD" -gt 0 ] || [ "$LINES_DEL" -gt 0 ]; then
        L+=" ${GREEN}+${LINES_ADD}${RESET} ${RED}-${LINES_DEL}${RESET}"
    fi
    L+="  ${SEP}"
fi

# Model
L+="  ${MAGENTA}${MODEL}${RESET}"

# Tokens + bar
L+="  ${SEP}  ${ORANGE}${USED_FMT}${DIM}/${RESET}${ORANGE}${TOTAL_FMT}${RESET} ${BAR_COLOR}${BAR}${RESET} ${BAR_COLOR}${PCT}%${RESET}"

# Effort
L+="  ${SEP}  ${EFFORT_FMT}"

# Cost
if [ "$COST" != "0" ]; then
    L+="  ${SEP}  ${YELLOW}${COST_FMT}${RESET}"
fi

# Time
L+="  ${SEP}  ${DIM}${TIME_FMT}${RESET}"

# Rate limits
if [ -n "$usage_data" ] && echo "$usage_data" | jq -e '.five_hour' >/dev/null 2>&1; then
    five_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
    five_reset=$(format_reset "$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')" "time")
    five_color=$(usage_color "$five_pct")

    seven_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
    seven_reset=$(format_reset "$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')" "datetime")
    seven_color=$(usage_color "$seven_pct")

    L+="  ${SEP}  ${WHITE}5h${RESET} ${five_color}${five_pct}%${RESET}"
    [ -n "$five_reset" ] && L+=" ${DIM}@${five_reset}${RESET}"

    L+="  ${SEP}  ${WHITE}7d${RESET} ${seven_color}${seven_pct}%${RESET}"
    [ -n "$seven_reset" ] && L+=" ${DIM}@${seven_reset}${RESET}"

    # Extra usage
    extra_on=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
    if [ "$extra_on" = "true" ]; then
        extra_used=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0' | LC_NUMERIC=C awk '{printf "%.2f", $1/100}')
        extra_limit=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | LC_NUMERIC=C awk '{printf "%.2f", $1/100}')
        extra_pct=$(echo "$usage_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
        extra_color=$(usage_color "$extra_pct")
        L+="  ${SEP}  ${WHITE}ex${RESET} ${extra_color}\$${extra_used}${DIM}/${RESET}${extra_color}\$${extra_limit}${RESET}"
    fi
fi

# Folder + version
L+="  ${SEP}  ${BLUE}${FOLDER}${RESET}"
[ -n "$VERSION" ] && L+=" ${DIM}v${VERSION}${RESET}"

printf "%b" "$L"
exit 0
