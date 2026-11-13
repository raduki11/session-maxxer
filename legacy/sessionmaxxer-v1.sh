#!/bin/bash
#
# SessionMaxxer — keeps your Claude Code and Codex usage windows ticking.
#
# Every 301 minutes it sends a one-shot checkup message ("ready to build?")
# to BOTH the `claude` and `codex` CLIs. It works while the Mac is asleep by
# scheduling a maintenance wake before each cycle, and — as a safety net —
# also fires on every wake/boot and sends if the last send was too long ago.
#
# Usage:
#   sudo ./sessionmaxxer.sh install     # set it up (run once)
#   ./sessionmaxxer.sh status           # show state, next wake, recent log
#   ./sessionmaxxer.sh run-now          # send immediately (test the CLIs)
#   sudo ./sessionmaxxer.sh uninstall   # remove everything
#
set -u

LABEL="com.sessionmaxxer.checkup"
MESSAGE="ready to build?"

INTERVAL_MIN=301
INTERVAL_SEC=18060      # 301 min — the launchd cadence
SKIP_SEC=18000          # 300 min — if last send is newer than this, skip (dedupe)
CLI_TIMEOUT=180         # kill a CLI call that hangs longer than this

INSTALL_PATH="/usr/local/bin/sessionmaxxer"
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"
DAEMON_LOG="/Library/Logs/SessionMaxxer.daemon.log"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

now_epoch() { date +%s; }

human_ts() {  # epoch -> readable
  local e="$1"
  [ -z "$e" ] && { echo "never"; return; }
  date -r "$e" "+%Y-%m-%d %H:%M:%S"
}

human_ago() {  # epoch -> "1h 4m ago"
  local e="$1"
  [ -z "$e" ] && { echo "never"; return; }
  local d=$(( $(now_epoch) - e ))
  printf '%dh %dm ago\n' $(( d / 3600 )) $(( (d % 3600) / 60 ))
}

state_dir_for_user() {  # user -> "~/Library/Application Support/SessionMaxxer"
  local u="$1" home
  home="$(/usr/bin/dscl . -read "/Users/${u}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  [ -z "$home" ] && home="/Users/${u}"
  echo "${home}/Library/Application Support/SessionMaxxer"
}

# run "$@" but SIGTERM it after CLI_TIMEOUT seconds; returns the cmd's rc (124 on timeout)
with_timeout() {
  "$@" &
  local pid=$!
  ( sleep "$CLI_TIMEOUT"; kill -TERM "$pid" 2>/dev/null ) &
  local killer=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill -TERM "$killer" 2>/dev/null
  wait "$killer" 2>/dev/null
  [ "$rc" -ge 143 ] && rc=124
  return "$rc"
}

# ---------------------------------------------------------------------------
# _send  <state_dir>  [--force]
#   Runs AS THE USER. Guards against sending too often, calls both CLIs,
#   logs everything, records the send time.
# ---------------------------------------------------------------------------

cmd_send() {
  local state_dir="$1"; shift || true
  local force="${1:-}"

  export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

  mkdir -p "$state_dir"
  local stamp="${state_dir}/last_send"
  local log="${state_dir}/checkup.log"

  # rotate log if it gets big (~1 MB)
  if [ -f "$log" ] && [ "$(wc -c < "$log" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    mv -f "$log" "${log}.1"
  fi

  local n; n="$(now_epoch)"
  local last=0
  [ -f "$stamp" ] && last="$(cat "$stamp" 2>/dev/null || echo 0)"

  if [ "$force" != "--force" ] && [ $(( n - last )) -lt "$SKIP_SEC" ]; then
    echo "[$(human_ts "$n")] skip: last send was $(human_ago "$last") (< ${SKIP_SEC}s)" >> "$log"
    return 0
  fi

  echo "[$(human_ts "$n")] --- checkup run (prev send: $(human_ago "$last")) ---" >> "$log"

  local any_ok=1

  # --- Claude Code ---
  if command -v claude >/dev/null 2>&1; then
    local out rc attempt=1
    while :; do
      out="$(with_timeout caffeinate -i claude -p "$MESSAGE" </dev/null 2>&1)"; rc=$?
      { [ "$rc" -eq 0 ] || [ "$attempt" -ge 2 ]; } && break
      echo "[$(human_ts "$(now_epoch)")] claude rc=$rc (attempt $attempt), retrying in 30s" >> "$log"
      attempt=$((attempt + 1)); sleep 30
    done
    echo "[$(human_ts "$(now_epoch)")] claude rc=$rc :: $(echo "$out" | tr '\n' ' ' | cut -c1-400)" >> "$log"
    [ "$rc" -eq 0 ] && any_ok=0
  else
    echo "[$(human_ts "$(now_epoch)")] claude: NOT FOUND on PATH" >> "$log"
  fi

  # --- Codex ---
  # --skip-git-repo-check: $HOME usually isn't a git repo
  # --sandbox read-only:   auto-approved, so a non-interactive run never blocks on a prompt
  # no -m: use the model from ~/.codex/config.toml (whatever the Codex app uses)
  if command -v codex >/dev/null 2>&1; then
    local out rc attempt=1
    while :; do
      out="$(cd "$HOME" && with_timeout caffeinate -i codex exec --skip-git-repo-check --sandbox read-only "$MESSAGE" </dev/null 2>&1)"; rc=$?
      { [ "$rc" -eq 0 ] || [ "$attempt" -ge 2 ]; } && break
      echo "[$(human_ts "$(now_epoch)")] codex rc=$rc (attempt $attempt), retrying in 30s" >> "$log"
      attempt=$((attempt + 1)); sleep 30
    done
    echo "[$(human_ts "$(now_epoch)")] codex  rc=$rc :: $(echo "$out" | tr '\n' ' ' | cut -c1-400)" >> "$log"
    [ "$rc" -eq 0 ] && any_ok=0
  else
    echo "[$(human_ts "$(now_epoch)")] codex: NOT FOUND on PATH" >> "$log"
  fi

  if [ "$any_ok" -eq 0 ]; then
    echo "$(now_epoch)" > "$stamp"
    echo "[$(human_ts "$(now_epoch)")] done: recorded send time" >> "$log"
  else
    echo "[$(human_ts "$(now_epoch)")] WARNING: no CLI succeeded; send time NOT updated" >> "$log"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _run  <user>
#   Runs AS ROOT from launchd. Fires the user-context send, then schedules
#   the next maintenance wake so the next cycle happens even while asleep.
# ---------------------------------------------------------------------------

cmd_run() {
  local user="$1"
  local state_dir; state_dir="$(state_dir_for_user "$user")"
  local uid; uid="$(id -u "$user" 2>/dev/null)"

  {
    echo "[$(human_ts "$(now_epoch)")] _run: user=$user uid=$uid"
  } >> "$DAEMON_LOG" 2>&1

  # send, as the user, with a login-ish environment
  if [ -n "$uid" ]; then
    launchctl asuser "$uid" sudo -iu "$user" -- /bin/bash "$INSTALL_PATH" _send "$state_dir" \
      >> "$DAEMON_LOG" 2>&1
  else
    echo "[$(human_ts "$(now_epoch)")] _run: cannot resolve uid for $user" >> "$DAEMON_LOG"
  fi

  # schedule the next wake (best-effort; one-shot events auto-expire after firing)
  local next_wake; next_wake="$(date -v+"${INTERVAL_MIN}"M '+%m/%d/%y %H:%M:%S')"
  local prev_file="${state_dir}/next_wake"
  if [ -f "$prev_file" ]; then
    local prev; prev="$(cat "$prev_file" 2>/dev/null)"
    [ -n "$prev" ] && pmset schedule cancel wake "$prev" >/dev/null 2>&1
  fi
  if pmset schedule wake "$next_wake" >/dev/null 2>&1; then
    echo "$next_wake" > "$prev_file"
    chown "$user" "$prev_file" 2>/dev/null
    echo "[$(human_ts "$(now_epoch)")] _run: next wake scheduled for $next_wake" >> "$DAEMON_LOG"
  else
    echo "[$(human_ts "$(now_epoch)")] _run: pmset schedule wake FAILED" >> "$DAEMON_LOG"
  fi
}

# ---------------------------------------------------------------------------
# install / uninstall / status / run-now
# ---------------------------------------------------------------------------

cmd_install() {
  [ "$(id -u)" -eq 0 ] || { echo "install must be run with sudo:  sudo $0 install"; exit 1; }
  local user="${SUDO_USER:-}"
  [ -n "$user" ] && [ "$user" != "root" ] || {
    echo "Could not determine your user (SUDO_USER). Run as:  sudo $0 install"; exit 1; }

  local src; src="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  install -d /usr/local/bin
  install -m 755 "$src" "$INSTALL_PATH"
  echo "Installed script -> $INSTALL_PATH"

  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${INSTALL_PATH}</string>
        <string>_run</string>
        <string>${user}</string>
    </array>
    <key>StartInterval</key>
    <integer>${INTERVAL_SEC}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${DAEMON_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${DAEMON_LOG}</string>
</dict>
</plist>
PLIST
  chown root:wheel "$PLIST_PATH"
  chmod 644 "$PLIST_PATH"
  echo "Installed LaunchDaemon -> $PLIST_PATH"

  launchctl bootout system "$PLIST_PATH" >/dev/null 2>&1
  launchctl bootstrap system "$PLIST_PATH"
  launchctl enable "system/${LABEL}"
  launchctl kickstart -k "system/${LABEL}"

  echo
  echo "SessionMaxxer is running. It just sent the first checkup."
  echo "  check state:   $INSTALL_PATH status"
  echo "  daemon log:    $DAEMON_LOG"
  echo "  remove it:     sudo $INSTALL_PATH uninstall"
}

cmd_uninstall() {
  [ "$(id -u)" -eq 0 ] || { echo "uninstall must be run with sudo:  sudo $0 uninstall"; exit 1; }
  local user="${SUDO_USER:-}"

  launchctl bootout system "$PLIST_PATH" >/dev/null 2>&1
  rm -f "$PLIST_PATH" && echo "Removed $PLIST_PATH"

  if [ -n "$user" ] && [ "$user" != "root" ]; then
    local sd; sd="$(state_dir_for_user "$user")"
    if [ -f "${sd}/next_wake" ]; then
      local prev; prev="$(cat "${sd}/next_wake" 2>/dev/null)"
      [ -n "$prev" ] && pmset schedule cancel wake "$prev" >/dev/null 2>&1 && \
        echo "Cancelled pending wake ($prev)"
      rm -f "${sd}/next_wake"
    fi
    echo "State/logs kept at: $sd"
  fi
  rm -f "$INSTALL_PATH" && echo "Removed $INSTALL_PATH"
  echo "Done. Check 'pmset -g sched' if you want to verify no wake is pending."
}

cmd_status() {
  local user="${SUDO_USER:-$(id -un)}"
  local sd; sd="$(state_dir_for_user "$user")"
  echo "SessionMaxxer status"
  echo "  daemon plist : $([ -f "$PLIST_PATH" ] && echo installed || echo 'NOT installed')"
  if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    echo "  daemon state : loaded"
  else
    echo "  daemon state : not loaded"
  fi
  local last=0
  [ -f "${sd}/last_send" ] && last="$(cat "${sd}/last_send" 2>/dev/null)"
  echo "  last send    : $(human_ts "$last")  ($(human_ago "$last"))"
  echo "  next wake    : $([ -f "${sd}/next_wake" ] && cat "${sd}/next_wake" || echo 'unknown')"
  echo "  pmset sched  :"
  pmset -g sched | sed 's/^/    /'
  echo "  recent log (${sd}/checkup.log):"
  [ -f "${sd}/checkup.log" ] && tail -n 15 "${sd}/checkup.log" | sed 's/^/    /' || echo "    (none yet)"
}

cmd_run_now() {
  local sd; sd="$(state_dir_for_user "$(id -un)")"
  echo "Sending now (ignoring the 300-min guard)..."
  cmd_send "$sd" --force
  echo "--- log tail ---"
  tail -n 12 "${sd}/checkup.log"
}

# ---------------------------------------------------------------------------

case "${1:-}" in
  install)    cmd_install ;;
  uninstall)  cmd_uninstall ;;
  status)     cmd_status ;;
  run-now)    cmd_run_now ;;
  _run)       shift; cmd_run "${1:?user}" ;;
  _send)      shift; cmd_send "${1:?state_dir}" "${2:-}" ;;
  *)
    echo "SessionMaxxer — keep Claude Code & Codex usage windows ticking"
    echo
    echo "  sudo $0 install     set up the recurring 301-min checkup (run once)"
    echo "       $0 status      show state, next wake, recent log"
    echo "       $0 run-now     send a checkup immediately (test your CLIs)"
    echo "  sudo $0 uninstall   remove the daemon and pending wake"
    ;;
esac
