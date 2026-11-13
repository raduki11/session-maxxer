#!/bin/bash
#
# SessionMaxxer v2 — start a fresh Claude Code / Codex 5-hour window the
# moment the previous one resets.
#
# Per tool, independently:
#   1. Read the tool's real 5-hour window (used %, reset time) from the same
#      usage endpoint the tool itself uses. No guessing with fixed timers.
#   2. No window running (reset time passed, or 0% used with the full 5 h
#      left)? Send one tiny ping so a new window starts now.
#   3. Window running? Remember its reset time and come back right after it.
#
# A per-user LaunchAgent (no root) ticks every 60 s. A tick only reads a few
# local files unless something is due. launchd also runs it right after the
# Mac wakes, so a reset you slept through is caught when you open the lid.
# With the optional `sudo ./sessionmaxxer.sh enable-wake`, it also schedules
# a wake for the next reset so it works with the lid closed.
#
# Usage:
#   ./sessionmaxxer.sh install            install / update the agent (no sudo)
#   sudo ./sessionmaxxer.sh enable-wake   optional: allow wakes with the lid closed
#   ./sessionmaxxer.sh check              show what each tool reports (no pings)
#   ./sessionmaxxer.sh status             agent state, windows, next wake, log
#   ./sessionmaxxer.sh run-now            ping both tools right now
#   ./sessionmaxxer.sh uninstall          remove the agent (no sudo)
#   sudo ./sessionmaxxer.sh disable-wake  remove the wake permission
#   sudo ./sessionmaxxer.sh remove-old    remove the v1 root LaunchDaemon
#
set -u

LABEL="com.sessionmaxxer.agent"
MESSAGE="Reply with just: ok"

TICK_SEC=60           # launchd cadence
REFRESH_SEC=7200      # while awake, re-read usage at least this often. Kept low-frequency on purpose:
                      # the Claude usage endpoint is rate-limited per login, and menu-bar apps
                      # (e.g. TokenEater) poll it with the same login.
GRACE_SEC=60          # act this long after a reset
PING_COOLDOWN=600     # never ping the same tool twice within this
RETRY_SEC=180         # retry a failed ping after this while awake
SLEEP_RETRY_SEC=600   # ...and wake the Mac for a retry after this
WINDOW_SEC=18000      # 5 h
CLI_TIMEOUT=180

APP_DIR="$HOME/Library/Application Support/SessionMaxxer"
STATE="$APP_DIR/state"
WORK="$APP_DIR/work"          # empty folder the CLIs run in, so they never look at your files
LOG="$APP_DIR/sessionmaxxer.log"
CONF="$APP_DIR/config"
BIN="$APP_DIR/sessionmaxxer.sh"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SUDOERS="/etc/sudoers.d/sessionmaxxer"
OLD_LABEL="com.sessionmaxxer.checkup"
OLD_PLIST="/Library/LaunchDaemons/${OLD_LABEL}.plist"
PMSET="/usr/bin/pmset"

# Defaults; $CONF (written by install) overrides them.
CLAUDE_BIN=""
CODEX_BIN=""
JQ="/usr/bin/jq"
SM_PATH=""
CLAUDE_MODEL="haiku"   # cheapest model; any message starts the window
CODEX_MODEL=""         # empty = whatever ~/.codex/config.toml uses
CODEX_EFFORT="low"     # reasoning effort for the ping; a one-word reply needs no thinking
if [ "$(id -u)" -ne 0 ] && [ -f "$CONF" ]; then . "$CONF"; fi

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

now()  { date +%s; }
ts()   { date -r "$1" '+%Y-%m-%d %H:%M:%S'; }
when() { if [ "${1:-0}" -gt 0 ] 2>/dev/null; then ts "$1"; else echo "unknown"; fi; }
log()  { mkdir -p "$APP_DIR"; echo "[$(ts "$(now)")] $*" >> "$LOG"; }
get()  { local v; v="$(cat "$STATE/$1" 2>/dev/null)"; echo "${v:-${2:-0}}"; }
put()  { mkdir -p "$STATE"; echo "$2" > "$STATE/$1"; }
die()  { echo "$*" >&2; exit 1; }
oneline() { echo "$1" | tr '\n' ' ' | cut -c1-"${2:-200}"; }
pmset_date() { date -r "$1" '+%m/%d/%y %H:%M:%S'; }

user_home() { # user -> home dir (works under sudo)
  local h; h="$(/usr/bin/dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  echo "${h:-/Users/$1}"
}

rotate_log() {
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then mv -f "$LOG" "$LOG.1"; fi
}

# run "$@", SIGTERM it after CLI_TIMEOUT s; returns its rc (124 on timeout)
with_timeout() {
  local start; start=$(now)
  "$@" &
  local pid=$!
  ( sleep "$CLI_TIMEOUT"; kill -TERM "$pid" 2>/dev/null ) &
  local killer=$! rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill -TERM "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
  [ "$rc" -ge 143 ] && rc=124
  # some CLIs exit 0 when terminated; don't count a killed run as success
  [ $(( $(now) - start )) -ge "$CLI_TIMEOUT" ] && rc=124
  return "$rc"
}

# GET a URL with secret headers passed via stdin (never on the command line).
# Sets HTTP_CODE and HTTP_BODY. Returns 1 on network failure.
http_get() { # http_get <url> <curl-config-lines>
  local out
  out="$(printf '%s' "$2" | /usr/bin/curl -sS -m 20 -K - -w '\n%{http_code}' \
          -H 'Accept: application/json' "$1" 2>&1)" || { HTTP_CODE=0; HTTP_BODY="$out"; return 1; }
  HTTP_CODE="${out##*$'\n'}"
  HTTP_BODY="${out%$'\n'*}"
}

# ---------------------------------------------------------------------------
# reading the real 5-hour window
#   Each fetch_* sets U_PCT (used %), U_RESET (epoch, 0 = none), U_WINDOW (s),
#   U_SRC (where it came from) or U_ERR, and returns 0 on success.
# ---------------------------------------------------------------------------

set_from_tsv() { # "<pct>\t<reset>\t<window>"
  U_PCT="$(echo "$1" | cut -f1)"
  U_RESET="$(echo "$1" | cut -f2)"; U_RESET="${U_RESET%%.*}"
  U_WINDOW="$(echo "$1" | cut -f3)"; U_WINDOW="${U_WINDOW%%.*}"
  [ -n "$U_RESET" ] || U_RESET=0
  [ -n "$U_WINDOW" ] || U_WINDOW=$WINDOW_SEC
}

fetch_claude() {
  U_PCT=0; U_RESET=0; U_WINDOW=$WINDOW_SEC; U_SRC=""; U_ERR=""
  local raw tok parsed
  # Claude Code keeps its login in a keychain item. Reading it with
  # /usr/bin/security may ask once; "Always Allow" makes that permanent.
  raw="$(/usr/bin/security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)"
  [ -n "$raw" ] || raw="$(cat "$HOME/.claude/.credentials.json" 2>/dev/null)"
  tok="$(printf '%s' "$raw" | "$JQ" -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
  [ -n "$tok" ] || { U_ERR="no Claude Code login found (run 'claude' once and log in)"; return 1; }

  http_get "https://api.anthropic.com/api/oauth/usage" \
    "header = \"Authorization: Bearer $tok\"
header = \"anthropic-beta: oauth-2025-04-20\"
" || { U_ERR="network: $(oneline "$HTTP_BODY" 150)"; return 1; }
  if [ "$HTTP_CODE" = 429 ]; then
    U_ERR="rate limited (HTTP 429): this login's usage-check budget is used up, possibly by a menu-bar app; falling back to the last known reset"
    return 1
  fi
  [ "$HTTP_CODE" = 200 ] || { U_ERR="HTTP $HTTP_CODE: $(oneline "$HTTP_BODY" 150)"; return 1; }

  parsed="$(printf '%s' "$HTTP_BODY" | "$JQ" -r --argjson w "$WINDOW_SEC" '
      (.five_hour // {}) as $f
      | [ ($f.utilization // 0),
          (($f.resets_at // "") | if . == "" then 0
             else (sub("\\.[0-9]+"; "") | sub("(\\+00:00|Z)$"; "Z") | fromdateiso8601) end),
          $w ]
      | @tsv' 2>/dev/null)"
  [ -n "$parsed" ] || { U_ERR="unexpected response: $(oneline "$HTTP_BODY" 150)"; return 1; }
  set_from_tsv "$parsed"; U_SRC="usage endpoint"
}

fetch_codex() {
  U_PCT=0; U_RESET=0; U_WINDOW=$WINDOW_SEC; U_SRC=""; U_ERR=""
  local auth="$HOME/.codex/auth.json" tok acct parsed
  tok="$("$JQ" -r '.tokens.access_token // empty' "$auth" 2>/dev/null)"
  acct="$("$JQ" -r '.tokens.account_id // empty' "$auth" 2>/dev/null)"
  if [ -z "$tok" ]; then
    U_ERR="no Codex login in ~/.codex/auth.json"
  elif ! http_get "https://chatgpt.com/backend-api/wham/usage" \
      "header = \"Authorization: Bearer $tok\"
header = \"ChatGPT-Account-Id: $acct\"
header = \"User-Agent: codex_cli_rs\"
"; then
    U_ERR="network: $(oneline "$HTTP_BODY" 150)"
  elif [ "$HTTP_CODE" != 200 ]; then
    U_ERR="HTTP $HTTP_CODE: $(oneline "$HTTP_BODY" 150)"
  else
    parsed="$(printf '%s' "$HTTP_BODY" | "$JQ" -r --argjson w "$WINDOW_SEC" '
        .rate_limit.primary_window // empty
        | [ (.used_percent // 0), (.reset_at // 0), (.limit_window_seconds // $w) ] | @tsv' 2>/dev/null)"
    if [ -n "$parsed" ]; then set_from_tsv "$parsed"; U_SRC="usage endpoint"; return 0; fi
    U_ERR="unexpected response: $(oneline "$HTTP_BODY" 150)"
  fi
  # Fallback: the latest rate-limit snapshot Codex wrote into its own session log.
  fetch_codex_from_sessions
}

fetch_codex_from_sessions() {
  local files f line parsed
  files="$(find "$HOME/.codex/sessions" -name 'rollout-*.jsonl' -mtime -2 2>/dev/null)"
  [ -n "$files" ] || return 1
  f="$(echo "$files" | while IFS= read -r p; do echo "$(stat -f %m "$p") $p"; done \
       | sort -rn | head -1 | cut -d' ' -f2-)"
  line="$(grep '"rate_limits"' "$f" 2>/dev/null | tail -1)"
  [ -n "$line" ] || return 1
  parsed="$(printf '%s' "$line" | "$JQ" -r --argjson w "$WINDOW_SEC" '
      first(.. | objects | select(has("rate_limits")) | .rate_limits.primary // empty)
      | [ (.used_percent // 0), (.resets_at // 0),
          ((.window_minutes // ($w / 60)) * 60), (.resets_in_seconds // 0) ] | @tsv' 2>/dev/null)"
  [ -n "$parsed" ] || return 1
  set_from_tsv "$parsed"
  if [ "$U_RESET" -eq 0 ]; then   # older Codex: relative seconds, measured when the log line was written
    local rel; rel="$(echo "$parsed" | cut -f4)"; rel="${rel%%.*}"
    [ "${rel:-0}" -gt 0 ] && U_RESET=$(( $(stat -f %m "$f") + rel ))
  fi
  U_SRC="Codex session log"; U_ERR=""
}

# true when no 5-hour window is running
needs_ping() {
  local n; n=$(now)
  [ "$U_RESET" -le "$n" ] && return 0
  # idle state: 0% used and the full window still ahead (the timer isn't really running)
  if [ "${U_PCT%%.*}" -eq 0 ] 2>/dev/null && [ $(( U_RESET - n )) -ge $(( U_WINDOW - 120 )) ]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# pings — run in an empty folder, no login shell, so nothing touches your files
# ---------------------------------------------------------------------------

ping_claude() {
  [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ] || { PING_OUT="claude not found (re-run install)"; return 127; }
  PING_OUT="$(cd "$WORK" && export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 && \
              with_timeout "$CLAUDE_BIN" -p "$MESSAGE" --model "$CLAUDE_MODEL" </dev/null 2>&1)"
}

ping_codex() {
  [ -n "$CODEX_BIN" ] && [ -x "$CODEX_BIN" ] || { PING_OUT="codex not found (re-run install)"; return 127; }
  local args=(exec --skip-git-repo-check --sandbox read-only -C "$WORK")
  [ -n "$CODEX_MODEL" ] && args+=(-m "$CODEX_MODEL")
  [ -n "$CODEX_EFFORT" ] && args+=(-c "model_reasoning_effort=\"$CODEX_EFFORT\"")
  args+=("$MESSAGE")
  PING_OUT="$(cd "$WORK" && with_timeout "$CODEX_BIN" "${args[@]}" </dev/null 2>&1)"
}

tool_installed() { # claude|codex
  if [ "$1" = claude ]; then [ -n "$CLAUDE_BIN" ]; else [ -n "$CODEX_BIN" ]; fi
}

# ---------------------------------------------------------------------------
# one tool, one tick
#   state per tool: _reset (known reset), _next (next check while awake),
#   _due (when it's worth waking the Mac), _last_ping
# ---------------------------------------------------------------------------

handle() { # handle <claude|codex> <force 0|1>
  local t="$1" force="$2" n; n=$(now)
  tool_installed "$t" || return 0
  # After a wake, only re-check a tool whose last known window has ended;
  # if it's still running, nothing was missed and we save a usage call.
  if [ "$force" = 1 ] && [ "$(get "${t}_reset")" -gt "$n" ]; then force=0; fi
  [ "$force" = 1 ] || [ "$n" -ge "$(get "${t}_next")" ] || return 0

  local known last_ping fetched=0 want=0 r nx rc
  known=$(get "${t}_reset"); last_ping=$(get "${t}_last_ping")

  if "fetch_$t"; then
    fetched=1
    log "$t: ${U_PCT}% used, window resets $(when "$U_RESET") (via $U_SRC)"
    needs_ping && want=1
  else
    log "$t: could not read usage — $U_ERR"
    # State unknown. If our last known window is over, ping anyway: a ping
    # during a running window only costs a few tokens.
    [ "$known" -le "$n" ] && want=1
  fi

  if [ "$want" = 0 ]; then
    if [ "$fetched" = 1 ]; then r=$U_RESET; else r=$known; fi
    put "${t}_reset" "$r"
    put "${t}_due" $(( r + GRACE_SEC ))
    nx=$(( r + GRACE_SEC ))
    [ "$nx" -gt $(( n + REFRESH_SEC )) ] && nx=$(( n + REFRESH_SEC ))
    put "${t}_next" "$nx"
    return 0
  fi

  if [ $(( n - last_ping )) -lt "$PING_COOLDOWN" ]; then
    # just pinged; the endpoint can still look idle for a few minutes
    put "${t}_next" $(( last_ping + PING_COOLDOWN ))
    return 0
  fi

  log "$t: no window running — pinging"
  if "ping_$t"; then
    log "$t: ping ok :: $(oneline "$PING_OUT")"
    put "${t}_last_ping" "$n"
    put "${t}_reset" $(( n + WINDOW_SEC ))              # provisional until the next read
    put "${t}_due" $(( n + WINDOW_SEC + GRACE_SEC ))
    put "${t}_next" $(( n + PING_COOLDOWN ))             # read the real reset time then
  else
    rc=$?
    log "$t: ping FAILED rc=$rc :: $(oneline "$PING_OUT")"
    put "${t}_next" $(( n + RETRY_SEC ))
    put "${t}_due" $(( n + SLEEP_RETRY_SEC ))
  fi
}

# ---------------------------------------------------------------------------
# lid-closed wakes (only if `sudo ... enable-wake` was run)
# ---------------------------------------------------------------------------

can_wake() { sudo -n -l "$PMSET" schedule wake "01/01/30 00:00:00" >/dev/null 2>&1; }

schedule_wake() {
  can_wake || return 0
  local n t d target=0 cur
  n=$(now)
  for t in claude codex; do
    tool_installed "$t" || continue
    d=$(get "${t}_due")
    if [ "$d" -gt "$n" ] && { [ "$target" = 0 ] || [ "$d" -lt "$target" ]; }; then target=$d; fi
  done
  [ "$target" -gt 0 ] || return 0
  cur=$(get scheduled_wake)
  [ "$cur" = "$target" ] && return 0
  if [ "$cur" -gt "$n" ]; then
    sudo -n "$PMSET" schedule cancel wake "$(pmset_date "$cur")" >/dev/null 2>&1
  fi
  if sudo -n "$PMSET" schedule wake "$(pmset_date "$target")" >/dev/null 2>&1; then
    put scheduled_wake "$target"
    log "wake scheduled for $(ts "$target")"
  else
    log "could not schedule a wake for $(ts "$target")"
  fi
}

cancel_wake() {
  local cur; cur=$(get scheduled_wake)
  if [ "$cur" -gt "$(now)" ] && can_wake; then
    sudo -n "$PMSET" schedule cancel wake "$(pmset_date "$cur")" >/dev/null 2>&1 && echo "Cancelled pending wake ($(ts "$cur"))"
  fi
  put scheduled_wake 0
}

# ---------------------------------------------------------------------------
# the launchd tick
# ---------------------------------------------------------------------------

cmd_tick() {
  mkdir -p "$STATE" "$WORK"; rotate_log
  [ -n "$SM_PATH" ] && export PATH="$SM_PATH"

  local n last force=0
  n=$(now); last=$(get last_tick)
  if [ $(( n - last )) -gt $(( TICK_SEC * 3 )) ]; then
    force=1   # first run, or the Mac was asleep: re-check everything now
    [ "$last" -gt 0 ] && log "awake after $(( (n - last) / 60 ))m — re-checking both"
  fi
  put last_tick "$n"

  if [ "$force" = 0 ] && [ "$n" -lt "$(get claude_next)" ] && [ "$n" -lt "$(get codex_next)" ]; then
    return 0   # nothing due: cheap exit
  fi

  /usr/bin/caffeinate -i -w $$ &   # keep the Mac awake until this tick finishes
  handle claude "$force"
  handle codex "$force"
  schedule_wake
  put last_tick "$(now)"   # a long tick (slow ping) shouldn't look like the Mac slept
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

cmd_install() {
  [ "$(id -u)" -ne 0 ] || die "Run install without sudo:  ./sessionmaxxer.sh install"
  [ -f "$OLD_PLIST" ] && die "The old v1 root daemon is still installed. Remove it first:  sudo $0 remove-old"

  local jq claude codex
  jq="$(command -v jq)" || die "jq not found (ships with macOS 15+, or: brew install jq)"
  claude="$(command -v claude || true)"
  codex="$(command -v codex || true)"
  [ -n "$claude$codex" ] || die "Neither claude nor codex is on your PATH."

  mkdir -p "$APP_DIR" "$STATE" "$WORK" "$HOME/Library/LaunchAgents"
  install -m 755 "$0" "$BIN"
  {
    printf 'CLAUDE_BIN=%q\n' "$claude"
    printf 'CODEX_BIN=%q\n' "$codex"
    printf 'JQ=%q\n' "$jq"
    printf 'SM_PATH=%q\n' "$PATH"
    printf 'CLAUDE_MODEL=%q\n' "$CLAUDE_MODEL"
    printf 'CODEX_MODEL=%q\n' "$CODEX_MODEL"
    printf 'CODEX_EFFORT=%q\n' "$CODEX_EFFORT"
  } > "$CONF"

  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${BIN}</string>
        <string>_tick</string>
    </array>
    <key>StartInterval</key>
    <integer>${TICK_SEC}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${APP_DIR}/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>${APP_DIR}/launchd.log</string>
</dict>
</plist>
PLIST

  launchctl bootout "gui/$(id -u)/${LABEL}" >/dev/null 2>&1
  launchctl bootstrap "gui/$(id -u)" "$PLIST" || die "launchctl bootstrap failed"

  echo "SessionMaxxer installed (runs as you, no root)."
  echo "  claude: ${claude:-not found — skipped}"
  echo "  codex : ${codex:-not found — skipped}"
  echo
  echo "Next:"
  echo "  ./sessionmaxxer.sh check                # confirm both windows can be read"
  echo "  sudo ./sessionmaxxer.sh enable-wake     # optional: also works with the lid closed"
  echo "  ./sessionmaxxer.sh status"
}

cmd_uninstall() {
  [ "$(id -u)" -ne 0 ] || die "Run uninstall without sudo."
  launchctl bootout "gui/$(id -u)/${LABEL}" >/dev/null 2>&1
  rm -f "$PLIST" && echo "Removed $PLIST"
  cancel_wake
  rm -f "$BIN" "$CONF"
  echo "Logs kept in: $APP_DIR"
  [ -f "$SUDOERS" ] && echo "Wake permission still installed; remove it with:  sudo $0 disable-wake"
  return 0
}

cmd_enable_wake() {
  [ "$(id -u)" -eq 0 ] || die "Run with sudo:  sudo $0 enable-wake"
  local u="${SUDO_USER:-}" tmp
  [ -n "$u" ] && [ "$u" != root ] || die "Run as your user via sudo, not as root."
  tmp="$(mktemp)"
  {
    echo "# SessionMaxxer: let $u schedule/cancel wake events without a password. Nothing else."
    echo "$u ALL=(root) NOPASSWD: $PMSET schedule wake *, $PMSET schedule cancel wake *"
  } > "$tmp"
  if ! /usr/sbin/visudo -cf "$tmp" >/dev/null; then rm -f "$tmp"; die "sudoers check failed; nothing changed."; fi
  install -m 440 -o root -g wheel "$tmp" "$SUDOERS"; rm -f "$tmp"
  echo "Enabled: SessionMaxxer can now schedule a wake for each reset (lid closed works)."
  echo "The next tick schedules the first one; see './sessionmaxxer.sh status'."
}

cmd_disable_wake() {
  [ "$(id -u)" -eq 0 ] || die "Run with sudo:  sudo $0 disable-wake"
  local u="${SUDO_USER:-}" f cur
  if [ -n "$u" ]; then
    f="$(user_home "$u")/Library/Application Support/SessionMaxxer/state/scheduled_wake"
    cur="$(cat "$f" 2>/dev/null)"
    if [ "${cur:-0}" -gt "$(now)" ] 2>/dev/null; then
      "$PMSET" schedule cancel wake "$(pmset_date "$cur")" >/dev/null 2>&1 && echo "Cancelled pending wake ($(ts "$cur"))"
    fi
    [ -f "$f" ] && echo 0 > "$f"
  fi
  rm -f "$SUDOERS" && echo "Removed $SUDOERS"
}

cmd_remove_old() {
  [ "$(id -u)" -eq 0 ] || die "Run with sudo:  sudo $0 remove-old"
  launchctl bootout system "$OLD_PLIST" >/dev/null 2>&1
  rm -f "$OLD_PLIST" && echo "Removed $OLD_PLIST"
  rm -f /usr/local/bin/sessionmaxxer && echo "Removed /usr/local/bin/sessionmaxxer"
  local u="${SUDO_USER:-}" f prev
  if [ -n "$u" ]; then
    f="$(user_home "$u")/Library/Application Support/SessionMaxxer/next_wake"
    prev="$(cat "$f" 2>/dev/null)"
    [ -n "$prev" ] && "$PMSET" schedule cancel wake "$prev" >/dev/null 2>&1 && echo "Cancelled old pending wake ($prev)"
    rm -f "$f"
  fi
  echo "Old v1 daemon removed. Now run (without sudo):  ./sessionmaxxer.sh install"
}

cmd_check() {
  local t
  for t in claude codex; do
    if ! tool_installed "$t" && ! command -v "$t" >/dev/null 2>&1; then echo "$t: not installed"; continue; fi
    if "fetch_$t"; then
      printf '%s: %s%% used, window resets %s (via %s)' "$t" "$U_PCT" "$(when "$U_RESET")" "$U_SRC"
      if needs_ping; then echo "  -> no window running, would ping"; else echo "  -> window running"; fi
    else
      echo "$t: could not read usage — $U_ERR"
    fi
  done
}

cmd_status() {
  local n t; n=$(now)
  echo "SessionMaxxer v2"
  if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then echo "  agent       : running"
  else echo "  agent       : NOT loaded (./sessionmaxxer.sh install)"; fi
  if can_wake; then echo "  lid closed  : enabled"
  else echo "  lid closed  : off (optional: sudo ./sessionmaxxer.sh enable-wake)"; fi
  [ -f "$OLD_PLIST" ] && echo "  WARNING     : old v1 daemon still installed (sudo ./sessionmaxxer.sh remove-old)"
  for t in claude codex; do
    tool_installed "$t" || { echo "  $t      : not installed"; continue; }
    printf '  %-12s: window resets %s, last ping %s, next check %s\n' "$t" \
      "$(when "$(get "${t}_reset")")" "$(when "$(get "${t}_last_ping")")" "$(when "$(get "${t}_next")")"
  done
  local w; w=$(get scheduled_wake)
  if [ "$w" -gt "$n" ]; then echo "  next wake   : $(ts "$w")"; else echo "  next wake   : none"; fi
  echo "  log ($LOG):"
  if [ -f "$LOG" ]; then tail -n 15 "$LOG" | sed 's/^/    /'; else echo "    (empty)"; fi
}

cmd_run_now() {
  mkdir -p "$STATE" "$WORK"
  local t n; n=$(now)
  for t in claude codex; do
    tool_installed "$t" || continue
    echo "Pinging $t..."
    if "ping_$t"; then
      log "$t: manual ping ok :: $(oneline "$PING_OUT")"; echo "  ok: $(oneline "$PING_OUT" 120)"
      put "${t}_last_ping" "$n"
    else
      log "$t: manual ping FAILED :: $(oneline "$PING_OUT")"; echo "  FAILED: $(oneline "$PING_OUT" 200)"
    fi
    put "${t}_next" $(( n + 120 ))   # the agent reads the new reset time in ~2 min
  done
}

# ---------------------------------------------------------------------------

[ "${SM_LIB:-}" = 1 ] && return 0 2>/dev/null   # allow sourcing for tests

case "${1:-}" in
  install)      cmd_install ;;
  uninstall)    cmd_uninstall ;;
  enable-wake)  cmd_enable_wake ;;
  disable-wake) cmd_disable_wake ;;
  remove-old)   cmd_remove_old ;;
  check)        cmd_check ;;
  status)       cmd_status ;;
  run-now)      cmd_run_now ;;
  _tick)        cmd_tick ;;
  *)
    echo "SessionMaxxer v2 — ping Claude Code & Codex the moment their 5-hour window resets"
    echo
    echo "  ./sessionmaxxer.sh install            install the agent (no sudo)"
    echo "  sudo ./sessionmaxxer.sh enable-wake   optional: also works with the lid closed"
    echo "  ./sessionmaxxer.sh check              show what each tool reports (no pings)"
    echo "  ./sessionmaxxer.sh status             agent state, windows, next wake, log"
    echo "  ./sessionmaxxer.sh run-now            ping both tools now"
    echo "  ./sessionmaxxer.sh uninstall          remove the agent"
    echo "  sudo ./sessionmaxxer.sh disable-wake  remove the wake permission"
    echo "  sudo ./sessionmaxxer.sh remove-old    remove the old v1 root daemon"
    ;;
esac
