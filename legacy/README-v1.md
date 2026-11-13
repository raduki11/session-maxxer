# SessionMaxxer

Keeps your **Claude Code** and **Codex** usage windows ticking so your coding
sessions stay aligned.

Every **301 minutes** it sends a one-shot checkup message (`ready to build?`) to
**both** the `claude` and `codex` CLIs. One command sets it up; then it runs
forever in the background.

## Setup (run once)

```sh
sudo ./sessionmaxxer.sh install
```

That's it. It installs a LaunchDaemon, sends the first checkup immediately, and
schedules the next one.

## How it hits every requirement

| Requirement | Mechanism |
|---|---|
| Send to **both** CLIs, one run | `_send` calls `claude -p "ready to build?"` and `codex exec "ready to build?"` (headless, as your user). |
| Every **301 min** | LaunchDaemon `StartInterval = 18060` while awake. |
| Works while **asleep** | Before each cycle, root schedules a one-shot `pmset schedule wake` for now + 301 min. The Mac wakes briefly, sends, sleeps again (`caffeinate -i` holds it awake during the send). This is the same wake facility Calendar/Time Machine use; events auto-expire after firing and `uninstall` clears any pending one. |
| Send **on wake if overdue** (battery died, long sleep, etc.) | `RunAtLoad` + launchd replaying the missed interval means it also runs on every wake/boot. A guard skips the send if the last one was < 300 min ago, so the scheduled wake and the on-wake fire never double-send. |

## Commands

```sh
./sessionmaxxer.sh status      # daemon state, last send, next wake, recent log
./sessionmaxxer.sh run-now     # send right now (ignores the 300-min guard) — good for testing
sudo ./sessionmaxxer.sh uninstall
```

## Files it creates

- `/usr/local/bin/sessionmaxxer` — installed copy of the script (what the daemon runs)
- `/Library/LaunchDaemons/com.sessionmaxxer.checkup.plist`
- `/Library/Logs/SessionMaxxer.daemon.log` — root-side log
- `~/Library/Application Support/SessionMaxxer/` — `last_send`, `next_wake`, `checkup.log`

## Notes

- Each cycle is two tiny API calls. That token cost *is* the mechanism — it's
  what starts/keeps each tool's usage window running.
- A scheduled wake is a short "maintenance wake"; the Mac returns to sleep on its
  own afterwards. Nothing is left running.
- If `claude` or `codex` isn't on your login `PATH`, the log will say
  `NOT FOUND` — fix your PATH and the next cycle picks it up.
- Each CLI call is retried once (30 s apart) on failure, to ride out
  transient "Reconnecting" / provider blips.
- `codex` runs with `--skip-git-repo-check --sandbox read-only` and uses
  whatever model is in `~/.codex/config.toml` (same as the Codex app). If
  ChatGPT/Codex has an outage the log shows a `codex rc=1 :: ... 404` line;
  `claude` still goes through, and codex recovers on the next cycle.
