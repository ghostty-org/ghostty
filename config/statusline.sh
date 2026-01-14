#!/bin/bash
# Mr StatusLine - Claude Code statusline
# Based on cc-statusline with actual output for terminal display

# Ensure PATH includes common tool locations (GUI apps don't inherit shell PATH)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

input=$(cat)

# ---- detect jq ----
HAS_JQ=0
if command -v jq >/dev/null 2>&1; then
  HAS_JQ=1
fi

# ---- color helpers ----
use_color=1
[ -n "$NO_COLOR" ] && use_color=0

# 256-color palette
dir_color() { [ "$use_color" -eq 1 ] && printf '\033[38;5;117m'; }    # sky blue
model_color() { [ "$use_color" -eq 1 ] && printf '\033[38;5;147m'; }  # light purple
version_color() { [ "$use_color" -eq 1 ] && printf '\033[38;5;249m'; } # light gray
rst() { [ "$use_color" -eq 1 ] && printf '\033[0m'; }

# Progress bar
progress_bar() {
  pct="${1:-0}"; width="${2:-10}"
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  ((pct<0)) && pct=0; ((pct>100)) && pct=100
  filled=$(( pct * width / 100 )); empty=$(( width - filled ))
  printf '%*s' "$filled" '' | tr ' ' '='
  printf '%*s' "$empty" '' | tr ' ' '-'
}

# ---- extract data ----
if [ "$HAS_JQ" -eq 1 ]; then
  current_dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // "~"' 2>/dev/null | sed "s|^$HOME|~|g")
  model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"' 2>/dev/null)
  cc_version=$(echo "$input" | jq -r '.version // ""' 2>/dev/null)

  # Context window calculation
  usage_obj=$(echo "$input" | jq '.context_window.current_usage // empty' 2>/dev/null)
  context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000' 2>/dev/null)
  context_pct=0

  if [ -n "$usage_obj" ] && [ "$usage_obj" != "null" ]; then
    input_tokens=$(echo "$usage_obj" | jq -r '.input_tokens // 0' 2>/dev/null)
    cache_creation=$(echo "$usage_obj" | jq -r '.cache_creation_input_tokens // 0' 2>/dev/null)
    cache_read=$(echo "$usage_obj" | jq -r '.cache_read_input_tokens // 0' 2>/dev/null)
    total_current=$((input_tokens + cache_creation + cache_read))

    if [ "$total_current" -gt 0 ] && [ "$context_size" -gt 0 ]; then
      context_pct=$(( (total_current * 100 / context_size) + 22 ))
      [ "$context_pct" -gt 100 ] && context_pct=100
    fi
  fi
else
  current_dir="~"
  model_name="Claude"
  cc_version=""
  context_pct=0
fi

# ---- git info ----
git_branch=""
git_uncommitted=0
git_ahead_main=0
git_ahead_dev=0
git_behind_remote=0
git_ahead_remote=0
if git rev-parse --git-dir >/dev/null 2>&1; then
  git_branch=$(git branch --show-current 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
  git_uncommitted=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')

  # Get commits ahead/behind remote tracking branch
  tracking_branch=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)
  if [ -n "$tracking_branch" ]; then
    git_behind_remote=$(git rev-list HEAD.."$tracking_branch" --count 2>/dev/null || echo 0)
    git_ahead_remote=$(git rev-list "$tracking_branch"..HEAD --count 2>/dev/null || echo 0)
  fi

  # Get commits ahead of main branch (if main exists and we're not on it)
  if [ "$git_branch" != "main" ] && git rev-parse --verify main >/dev/null 2>&1; then
    git_ahead_main=$(git rev-list main..HEAD --count 2>/dev/null || echo 0)
  fi

  # Get commits ahead of dev branch (if dev exists and we're not on it)
  if [ "$git_branch" != "dev" ] && git rev-parse --verify dev >/dev/null 2>&1; then
    git_ahead_dev=$(git rev-list dev..HEAD --count 2>/dev/null || echo 0)
  fi

  # Time since last commit
  last_commit_epoch=$(git log -1 --format=%ct 2>/dev/null)
  if [ -n "$last_commit_epoch" ]; then
    now_epoch=$(date +%s)
    seconds_ago=$((now_epoch - last_commit_epoch))
    if [ "$seconds_ago" -lt 60 ]; then
      git_last_commit="just now"
    elif [ "$seconds_ago" -lt 3600 ]; then
      git_last_commit="$((seconds_ago / 60))m ago"
    elif [ "$seconds_ago" -lt 86400 ]; then
      git_last_commit="$((seconds_ago / 3600))h ago"
    else
      git_last_commit="$((seconds_ago / 86400))d ago"
    fi
  fi
fi

# ---- weekly usage from cache ----
weekly_pct=""
usage_cache="$HOME/.claude/usage-cache.json"
USAGE_WORKER_URL="https://claude-usage-proxy.petefromsf.workers.dev?key=46accd563fbd06231d68f8f6af6cfab4"

# Check cache age
cache_stale=1
if [ -f "$usage_cache" ]; then
  cache_age=$(($(date +%s) - $(stat -f %m "$usage_cache" 2>/dev/null || echo 0)))
  [ "$cache_age" -lt 300 ] && cache_stale=0
fi

# Fetch if stale (2 second timeout)
if [ "$cache_stale" -eq 1 ] && [ "$HAS_JQ" -eq 1 ]; then
  fresh_data=$(curl -s --max-time 2 "$USAGE_WORKER_URL" 2>/dev/null)
  if echo "$fresh_data" | jq -e '.weekly' >/dev/null 2>&1; then
    echo "$fresh_data" > "$usage_cache"
  fi
fi

# Read weekly usage
if [ -f "$usage_cache" ] && [ "$HAS_JQ" -eq 1 ]; then
  weekly_val=$(jq -r '.weekly // empty' "$usage_cache" 2>/dev/null)
  if [ -n "$weekly_val" ] && [ "$weekly_val" != "null" ]; then
    weekly_pct=$(printf "%.0f" "$weekly_val" 2>/dev/null)
  fi
fi

# ---- color functions based on values ----
context_color() {
  if [ "$context_pct" -ge 80 ]; then
    [ "$use_color" -eq 1 ] && printf '\033[38;5;203m'  # red
  elif [ "$context_pct" -ge 60 ]; then
    [ "$use_color" -eq 1 ] && printf '\033[38;5;215m'  # orange
  else
    [ "$use_color" -eq 1 ] && printf '\033[38;5;158m'  # green
  fi
}

weekly_color() {
  if [ "${weekly_pct:-0}" -ge 80 ]; then
    [ "$use_color" -eq 1 ] && printf '\033[38;5;203m'  # red
  elif [ "${weekly_pct:-0}" -ge 50 ]; then
    [ "$use_color" -eq 1 ] && printf '\033[38;5;215m'  # orange
  else
    [ "$use_color" -eq 1 ] && printf '\033[38;5;158m'  # green
  fi
}

# ---- render output ----
# Line 1: Directory, model, version
printf "$(dir_color)📁 %s$(rst)  $(model_color)🤖 %s$(rst)" "$current_dir" "$model_name"
[ -n "$cc_version" ] && printf "  $(version_color)📟 v%s$(rst)" "$cc_version"
printf "\n"

# Line 2: Git info (if in repo)
if [ -n "$git_branch" ]; then
  printf "\033[38;5;150m🌿 %s$(rst)" "$git_branch"
  [ "$git_behind_remote" -gt 0 ] && printf "  \033[38;5;203m↓ %d behind$(rst)" "$git_behind_remote"
  [ "$git_ahead_remote" -gt 0 ] && printf "  \033[38;5;81m↑ %d ahead$(rst)" "$git_ahead_remote"
  [ "$git_uncommitted" -gt 0 ] && printf "  \033[38;5;215m📝 %d uncommitted$(rst)" "$git_uncommitted"
  [ "$git_ahead_main" -gt 0 ] && printf "  \033[38;5;81m⬆ %d ahead main$(rst)" "$git_ahead_main"
  [ "$git_ahead_dev" -gt 0 ] && printf "  \033[38;5;81m⬆ %d ahead dev$(rst)" "$git_ahead_dev"
  [ -n "$git_last_commit" ] && printf "  \033[38;5;245m⏱ %s$(rst)" "$git_last_commit"
  printf "\n"
fi

# Line 3: Context and weekly usage (just percentages, no progress bar)
printf "$(context_color)🧠 %d%%$(rst)" "$context_pct"
if [ -n "$weekly_pct" ]; then
  printf "  $(weekly_color)📊 Week: %d%%$(rst)" "$weekly_pct"
fi
printf "\n"

# ---- Write state to Terminaut dashboard ----
mkdir -p "$HOME/.terminaut/states"

if [ "$HAS_JQ" -eq 1 ]; then
  # Create project-based state file (not per-session, so todos persist)
  # Use sanitized directory name for filename
  project_name=$(basename "$current_dir" | tr -cd '[:alnum:]-_')
  STATE_FILE="$HOME/.terminaut/states/project-${project_name}.json"

  # Preserve existing todos from state file
  existing_todos="[]"
  if [ -f "$STATE_FILE" ]; then
    existing_todos=$(jq -c '.todos // []' "$STATE_FILE" 2>/dev/null || echo "[]")
  fi

  # Extract context window data that Claude Code actually provides
  total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null)
  total_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null)
  context_size_from_input=$(echo "$input" | jq -r '.context_window.context_window_size // 200000' 2>/dev/null)
  used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' 2>/dev/null)
  remaining_pct=$(echo "$input" | jq -r '.context_window.remaining_percentage // 100' 2>/dev/null)

  # Current usage breakdown (from latest API call)
  current_input=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0' 2>/dev/null)
  current_output=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // 0' 2>/dev/null)
  cache_creation=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0' 2>/dev/null)
  cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0' 2>/dev/null)

  # Escape strings for JSON
  model_escaped=$(echo "$model_name" | sed 's/"/\\"/g')
  version_escaped=$(echo "$cc_version" | sed 's/"/\\"/g')
  dir_escaped=$(echo "$current_dir" | sed 's/"/\\"/g')
  branch_escaped=$(echo "$git_branch" | sed 's/"/\\"/g')

  # Extract todos from JSONL transcript file (current session)
  transcript_path=$(echo "$input" | jq -r '.transcript_path // ""' 2>/dev/null)
  session_todos="[]"
  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    session_todos=$(grep '"name":"TodoWrite"' "$transcript_path" 2>/dev/null | tail -1 | jq -c '.message.content[0].input.todos // []' 2>/dev/null)
  fi

  # Use session todos if available, otherwise preserve existing todos
  if [ -n "$session_todos" ] && [ "$session_todos" != "null" ] && [ "$session_todos" != "[]" ]; then
    todos_json="$session_todos"
  else
    todos_json="$existing_todos"
  fi
  [ -z "$todos_json" ] || [ "$todos_json" = "null" ] && todos_json="[]"

  # Fetch open PRs from origin repo (not upstream) - only for peteknowsai repos
  open_prs="[]"
  # Find gh binary (might not be in PATH)
  GH_BIN=""
  if command -v gh >/dev/null 2>&1; then
    GH_BIN="gh"
  elif [ -x "/opt/homebrew/bin/gh" ]; then
    GH_BIN="/opt/homebrew/bin/gh"
  elif [ -x "/usr/local/bin/gh" ]; then
    GH_BIN="/usr/local/bin/gh"
  fi
  if [ -n "$GH_BIN" ] && git rev-parse --git-dir >/dev/null 2>&1; then
    # Get the origin remote URL and extract owner/repo
    origin_url=$(git remote get-url origin 2>/dev/null)
    if [ -n "$origin_url" ]; then
      # Extract owner/repo from git URL (handles both HTTPS and SSH formats)
      repo_path=$(echo "$origin_url" | sed -E 's#^(https://github.com/|git@github.com:)##' | sed 's/\.git$//')
      repo_owner=$(echo "$repo_path" | cut -d'/' -f1)

      # Only fetch PRs for peteknowsai repos
      if [ "$repo_owner" = "peteknowsai" ]; then
        pr_data=$($GH_BIN pr list --repo "$repo_path" --state open --limit 10 --json number,title,author,isDraft,updatedAt 2>/dev/null)
        if [ -n "$pr_data" ] && [ "$pr_data" != "null" ]; then
          # Transform to match our struct (author is nested object with login)
          open_prs=$(echo "$pr_data" | jq -c '[.[] | {number, title, author: .author.login, isDraft, updatedAt}]' 2>/dev/null || echo "[]")
        fi
      fi
    fi
  fi
  [ -z "$open_prs" ] || [ "$open_prs" = "null" ] && open_prs="[]"

  # Write to per-project state file (atomic: write to temp, then rename)
  STATE_TMP="${STATE_FILE}.tmp.$$"
  cat > "$STATE_TMP" <<JSONEOF
{
  "projectName": "$project_name",
  "model": "$model_escaped",
  "version": "$version_escaped",
  "cwd": "$dir_escaped",
  "contextPercent": ${used_pct:-0},
  "quotaPercent": ${weekly_pct:-0},
  "gitBranch": "$branch_escaped",
  "gitUncommitted": ${git_uncommitted:-0},
  "gitAhead": ${git_ahead_remote:-0},
  "gitBehind": ${git_behind_remote:-0},
  "todos": $todos_json,
  "openPRs": $open_prs,
  "context": {
    "totalInputTokens": ${total_input:-0},
    "totalOutputTokens": ${total_output:-0},
    "maxTokens": ${context_size_from_input:-200000},
    "usedPercent": ${used_pct:-0},
    "remainingPercent": ${remaining_pct:-100},
    "currentInput": ${current_input:-0},
    "currentOutput": ${current_output:-0},
    "cacheCreation": ${cache_creation:-0},
    "cacheRead": ${cache_read:-0}
  },
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSONEOF
  mv "$STATE_TMP" "$STATE_FILE"
fi
