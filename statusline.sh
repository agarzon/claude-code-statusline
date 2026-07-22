#!/usr/bin/env bash
# Claude Code statusline — Starship-inspired single line (portable)
set -f  # disable globbing

input=$(cat)
if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ── Extract all fields in a single jq call ──────────────────────────
IFS=$'\x1f' read -r MODEL CWD PCT COST DURATION_MS LINES_ADD LINES_DEL VERSION \
    CTX_SIZE CURRENT_TOK EFFORT_LEVEL FIVE_PCT FIVE_RESET SEVEN_PCT SEVEN_RESET \
    SESSION_NAME WORKTREE_NAME AGENT_NAME THINKING < <(
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
    (.context_window.total_input_tokens // 0),
    (.effort.level // ""),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.seven_day.resets_at // ""),
    (.session_name // ""),
    (.worktree.name // ""),
    (.agent.name // ""),
    (.thinking.enabled // false)
  ] | join("\u001f")'
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

# Format Unix epoch seconds to local HH:MM or "Mon D HH:MM"
format_reset() {
    local epoch="$1" style="$2"
    { [ -z "$epoch" ] || [ "$epoch" = "null" ]; } && return
    case "$style" in
        time)     date -d "@$epoch" +"%H:%M" 2>/dev/null || date -j -r "$epoch" +"%H:%M" 2>/dev/null ;;
        datetime) date -d "@$epoch" +"%b %-d %H:%M" 2>/dev/null || date -j -r "$epoch" +"%b %-d %H:%M" 2>/dev/null ;;
    esac
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
EFFORT="${EFFORT_LEVEL:-medium}"
case "$EFFORT" in
    low)    EFFORT_FMT="${DIM}lo${RESET}" ;;
    high)   EFFORT_FMT="${GREEN}hi${RESET}" ;;
    xhigh)  EFFORT_FMT="${GREEN}xhi${RESET}" ;;
    max)    EFFORT_FMT="${GREEN}max${RESET}" ;;
    *)      EFFORT_FMT="${ORANGE}md${RESET}" ;;
esac
# Extended thinking marker
[ "$THINKING" = "true" ] && EFFORT_FMT="${EFFORT_FMT}${YELLOW}*${RESET}"

# ── Build lines ──────────────────────────────────────────────────────
# Line 1: identity / context (session, git, agent, model, folder)
# Line 2: live metrics (tokens, effort, cost, time, rate limits)
L1=""
L2=""

# === Line 1 ===

# Session name (when set via --name or /rename)
[ -n "$SESSION_NAME" ] && L1+="${CYAN}${BOLD}${SESSION_NAME}${RESET}  ${SEP}  "

# Git segment
if [ -n "$BRANCH" ]; then
    L1+="${GREEN}⌲${RESET} ${CYAN}${BOLD}${BRANCH}${RESET}"
    [ -n "$GIT_DIRTY" ] && L1+="${YELLOW}!${RESET}"
    [ -n "$WORKTREE_NAME" ] && L1+=" ${DIM}(${WORKTREE_NAME})${RESET}"
    if [ "$LINES_ADD" -gt 0 ] || [ "$LINES_DEL" -gt 0 ]; then
        L1+=" ${GREEN}+${LINES_ADD}${RESET} ${RED}-${LINES_DEL}${RESET}"
    fi
    L1+="  ${SEP}  "
fi

# Agent prefix (when running with --agent)
[ -n "$AGENT_NAME" ] && L1+="${CYAN}@${AGENT_NAME}${RESET}  ${SEP}  "

# Model (always present, anchor of line 1)
L1+="${MAGENTA}${MODEL}${RESET}"

# Folder + version
L1+="  ${SEP}  ${BLUE}${FOLDER}${RESET}"
[ -n "$VERSION" ] && L1+=" ${DIM}v${VERSION}${RESET}"

# === Line 2 ===

# Tokens + bar (anchor of line 2)
L2+="${ORANGE}${USED_FMT}${DIM}/${RESET}${ORANGE}${TOTAL_FMT}${RESET} ${BAR_COLOR}${BAR}${RESET} ${BAR_COLOR}${PCT}%${RESET}"

# Effort (with extended-thinking marker)
L2+="  ${SEP}  ${EFFORT_FMT}"

# Cost
[ "$COST" != "0" ] && L2+="  ${SEP}  ${YELLOW}${COST_FMT}${RESET}"

# Time
L2+="  ${SEP}  ${DIM}${TIME_FMT}${RESET}"

# Rate limits (from stdin)
if [ -n "$FIVE_PCT" ]; then
    five_pct=$(awk "BEGIN {printf \"%.0f\", $FIVE_PCT}")
    five_reset=$(format_reset "$FIVE_RESET" "time")
    five_color=$(usage_color "$five_pct")
    L2+="  ${SEP}  ${WHITE}5h${RESET} ${five_color}${five_pct}%${RESET}"
    [ -n "$five_reset" ] && L2+=" ${DIM}@${five_reset}${RESET}"
fi
if [ -n "$SEVEN_PCT" ]; then
    seven_pct=$(awk "BEGIN {printf \"%.0f\", $SEVEN_PCT}")
    seven_reset=$(format_reset "$SEVEN_RESET" "datetime")
    seven_color=$(usage_color "$seven_pct")
    L2+="  ${SEP}  ${WHITE}7d${RESET} ${seven_color}${seven_pct}%${RESET}"
    [ -n "$seven_reset" ] && L2+=" ${DIM}@${seven_reset}${RESET}"
fi

printf "%b\n%b" "$L1" "$L2"
exit 0
