# SessionMaxxer v2

Starts a fresh **Claude Code** and **Codex** 5-hour window the moment the
previous one resets, so a new window is always running.

## How it works

For each tool, independently:

1. It reads the tool's **real** 5-hour window (% used, reset time) from the same
   usage endpoint the tool itself uses:
   - Claude Code: `api.anthropic.com/api/oauth/usage` (your Claude Code login)
   - Codex: `chatgpt.com/backend-api/wham/usage` (your `~/.codex/auth.json`),
     falling back to the rate-limit snapshot Codex writes in `~/.codex/sessions`
2. If no window is running (reset time passed, or 0% used with the full 5 h
   ahead), it sends one tiny ping (`claude -p … --model haiku`,
   `codex exec … --sandbox read-only`).
3. Otherwise it remembers the reset time and checks again 1 minute after it.

A per-user **LaunchAgent** ticks every 60 s. A tick only reads a few local files
unless something is due. It also re-reads usage every 2 h as a safety net.

| Situation | What happens |
|---|---|
| Mac awake at reset | Ping within ~1 min of the reset |
| Lid closed at reset | With `enable-wake`: a wake is scheduled for reset +1 min, the Mac wakes briefly, pings, sleeps again |
| You open the lid after missing a reset | First tick after wake re-checks both tools and pings any that are idle |
| You started a window yourself | Its real reset time is read, so nothing is wasted |
| Usage endpoint fails | If the last known window is over, it pings anyway (a ping during a running window only costs a few tokens) |
| Ping fails (no network yet after wake) | Retries in 3 min awake, or wakes the Mac again in 10 min |

## Why there are no permission popups now

- **No root daemon, no `sudo -i` login shell.** v1 ran the CLIs from a root
  LaunchDaemon via `launchctl asuser` + `sudo -iu`, so macOS attributed their
  file access to a different background process each time and kept asking.
  v2 runs as you, in your normal session, with absolute paths and a fixed `PATH`.
- **The CLIs run in an empty folder**
  (`~/Library/Application Support/SessionMaxxer/work`), not your home folder,
  so they never touch Documents, Desktop, Music, etc.
- **Usage reads use only built-in tools:** `/usr/bin/curl`, `/usr/bin/jq`, and
  `/usr/bin/security` for the Claude Code keychain item.

What macOS can still show, once each: a "Background Items Added" notification
when the agent is installed, and possibly one keychain prompt the first time it
reads the Claude Code login. Click **Always Allow** and it won't ask again. Run
`./sessionmaxxer.sh check` right after installing so that prompt (if any)
appears while you're at the keyboard.

## Running alongside TokenEater (or another usage menu-bar app)

TokenEater reads the same two endpoints with the same logins. Claude's usage
endpoint has a request budget per login, which both apps share. That's where
TokenEater's occasional "Rate limited" comes from. To stay out of its way:

- SessionMaxxer reads Claude usage only a few times per 5-hour cycle: right after
  a reset, once after each ping, after a wake if a window ended while asleep,
  and every 2 h as a safety net.
- If it gets HTTP 429 anyway, it doesn't retry in a loop. It uses the last known
  reset time and, if that time has passed, pings anyway.

Codex's usage endpoint isn't affected the same way.

## Setup

```sh
# 1. If v1 is still installed, remove it (asks for your password once)
sudo ./sessionmaxxer.sh remove-old

# 2. Install (no sudo). Run it from your normal terminal so it finds claude/codex.
./sessionmaxxer.sh install

# 3. Check that both windows can be read (no pings sent)
./sessionmaxxer.sh check

# 4. Optional, for lid-closed operation
sudo ./sessionmaxxer.sh enable-wake
```

`enable-wake` adds `/etc/sudoers.d/sessionmaxxer`, which lets your user run
**only** `pmset schedule wake …` and `pmset schedule cancel wake …` without a
password. It's checked with `visudo` before it's installed. Nothing else gets
root.

## Commands

```sh
./sessionmaxxer.sh status          # agent, each window's reset, next wake, log tail
./sessionmaxxer.sh check           # what each tool reports right now (no pings)
./sessionmaxxer.sh run-now         # ping both now
./sessionmaxxer.sh install         # also use this to update after editing the script
./sessionmaxxer.sh uninstall
sudo ./sessionmaxxer.sh disable-wake
```

## Files

- `~/Library/LaunchAgents/com.sessionmaxxer.agent.plist`
- `~/Library/Application Support/SessionMaxxer/`: installed script copy,
  `config` (CLI paths, PATH, models), `state/`, `sessionmaxxer.log`, `work/`
- `/etc/sudoers.d/sessionmaxxer`, only if you ran `enable-wake`

## Notes

- Models: `CLAUDE_MODEL` (default `haiku`) and `CODEX_MODEL` (default: your
  `~/.codex/config.toml`) live in the `config` file. Any message starts the
  window, so the cheapest model is enough.
- If you reinstall Claude Code or Codex somewhere else, run `install` again so
  it picks up the new paths.
- Lid closed depends on macOS actually bringing Wi-Fi up during the brief
  scheduled wake. That's reliable on power and usually works on battery. If a
  ping fails there, it's retried with another wake, and caught at the latest
  when you open the lid.
- The usage endpoints are the ones the tools use internally, not public APIs. If
  one changes, `check` shows the error and the script falls back to pinging once
  the last known window is over.
- `legacy/` holds the v1 script and README.
