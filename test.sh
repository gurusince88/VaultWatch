#!/bin/bash
# VaultWatch end-to-end smoke test against the real vault.
# Usage (from the VaultWatch folder):
#   ./test.sh                     # tests the first vault from `ob sync-list-local`
#   ./test.sh /path/to/vault      # tests a specific vault
#   ./test.sh /path/to/vault --activity
#       also creates, edits, and deletes a small test note to check the Activity view
#       (this syncs to your other devices, then gets deleted again)
# Leaves VaultWatch running and syncing when it finishes.
set -u
cd "$(dirname "$0")"

VAULT="${1:-}"
ACTIVITY_TEST=0
for a in "$@"; do [[ "$a" == "--activity" ]] && ACTIVITY_TEST=1; done
[[ "$VAULT" == "--activity" ]] && VAULT=""
if [[ -z "$VAULT" ]]; then
    VAULT="$(ob sync-list-local --json 2>/dev/null | sed -n 's/.*"path": *"\(.*\)".*/\1/p' | head -1)"
fi
[[ -n "$VAULT" ]] || { echo "No vault given and none found via 'ob sync-list-local'."; exit 1; }
echo "Testing vault: $VAULT"
APP="/Applications/VaultWatch.app"
LOG="$HOME/Library/Logs/VaultWatch/$(basename "$VAULT").log"
PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
step() { echo; echo "== $1"; }

# PIDs of `ob sync --path <vault> ...` (excludes `ob sync-status`).
obpids()  { pgrep -f "ob sync --path $VAULT" || true; }
apppid()  { pgrep -x VaultWatch || true; }
quit_app() {
    osascript -e 'tell application "VaultWatch" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do [[ -z "$(apppid)" ]] && return 0; sleep 0.5; done
    pkill -TERM -x VaultWatch || true; sleep 2
}
wait_for_ob() {   # wait_for_ob <seconds> [pid-to-differ-from]
    for _ in $(seq 1 "$1"); do
        local p; p="$(obpids | head -1)"
        if [[ -n "$p" && "$p" != "${2:-}" ]]; then echo "$p"; return 0; fi
        sleep 1
    done
    return 1
}

step "0. Preconditions"
command -v ob >/dev/null && ok "ob found at $(command -v ob)" || { bad "ob not on PATH"; exit 1; }
ob sync-status --path "$VAULT" | grep -q "Vault:" && ok "vault is configured for Headless Sync" || bad "ob sync-status did not report a vault"
if pgrep -x Obsidian >/dev/null; then echo "  NOTE  Obsidian desktop is running; the app should show a warning"; fi

osascript -e 'tell application "ObSyncBar" to quit' >/dev/null 2>&1 || true   # pre-rename build
quit_app
EXISTING="$(obpids)"
if [[ -n "$EXISTING" ]]; then
    echo "  An ob sync is already running on this vault (PID $EXISTING), probably your Terminal session."
    read -r -p "  Stop it so the test can run? [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || { echo "Stop it (Ctrl-C in that Terminal) and re-run."; exit 1; }
    kill -TERM $EXISTING; sleep 3
    [[ -z "$(obpids)" ]] && ok "stopped external ob sync" || { bad "external ob sync still running"; exit 1; }
fi

step "1. Build and install"
if ./build.sh --install > build.log 2>&1; then ok "build succeeded"; else
    bad "build failed (last 40 lines of build.log):"; tail -40 build.log; exit 1; fi

[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] && ok "app icon bundled" || bad "AppIcon.icns missing from bundle"

step "2. Launch: app should spawn ob sync --continuous"
open "$APP"
PID="$(wait_for_ob 40)" && ok "ob sync started (PID $PID)" || { bad "no ob sync within 40s"; tail -20 "$LOG" 2>/dev/null; exit 1; }
ARGS="$(ps -o command= -p "$PID")"
[[ "$ARGS" == *"--continuous"* ]] && ok "running with --continuous" || bad "missing --continuous: $ARGS"
PPID_OF="$(ps -o ppid= -p "$PID" | tr -d ' ')"
[[ "$PPID_OF" == "$(apppid)" ]] && ok "ob is a child of VaultWatch" || bad "ob parent is $PPID_OF, app is $(apppid)"
[[ "$(obpids | wc -l | tr -d ' ')" == "1" ]] && ok "exactly one ob sync on the vault" || bad "more than one ob sync running"
grep -q "starting:" "$LOG" 2>/dev/null && ok "log written to $LOG" || bad "no 'starting:' line in log"
CFG="$HOME/Library/Application Support/VaultWatch/config.json"
grep -qF "$VAULT" "$CFG" 2>/dev/null && ok "vault present in config" || bad "vault not in $CFG"

step "3. Stays up for 20s"
sleep 20
[[ "$(obpids | head -1)" == "$PID" ]] && ok "same ob process still running" || bad "ob restarted or died; see log"

step "4. Crash recovery: kill -9 the ob child"
kill -9 "$PID"
NEW="$(wait_for_ob 20 "$PID")" && ok "restarted automatically (new PID $NEW)" || bad "did not restart within 20s"
PID="${NEW:-$PID}"

step "5. Duplicate guard: a second ob sync must not be started"
quit_app
[[ -z "$(obpids)" ]] && ok "quitting app stopped ob" || bad "ob still running after quit"
ob sync --path "$VAULT" --continuous > /dev/null 2>&1 &
MANUAL=$!
sleep 4
open "$APP"; sleep 10
COUNT="$(obpids | wc -l | tr -d ' ')"
[[ "$COUNT" == "1" ]] && ok "app did not start a second sync" || bad "$COUNT ob sync processes running"
tail -5 "$LOG" | grep -q "Another \`ob sync\`" && ok "app reported the duplicate (menu shows Take Over)" || bad "no duplicate message in log"
kill -TERM "$MANUAL" 2>/dev/null; pkill -TERM -f "ob sync --path $VAULT" 2>/dev/null; sleep 3
quit_app

step "6. Clean shutdown via SIGTERM to the app (pkill)"
open "$APP"
PID="$(wait_for_ob 40)" && ok "ob sync started (PID $PID)" || bad "no ob sync after relaunch"
pkill -TERM -x VaultWatch
for _ in $(seq 1 15); do [[ -z "$(obpids)" && -z "$(apppid)" ]] && break; sleep 1; done
[[ -z "$(obpids)" ]] && ok "ob exited with the app (no orphan)" || bad "orphaned ob sync left running: $(obpids)"
tail -20 "$LOG" | grep -q "SIGKILL" && bad "needed SIGKILL to stop ob" || ok "ob stopped without SIGKILL"

step "7. Relaunch and leave running"
open "$APP"
PID="$(wait_for_ob 40)" && ok "syncing again (PID $PID)" || bad "did not restart"

if [[ $ACTIVITY_TEST -eq 1 ]]; then
    step "8. Activity: create, edit, delete a test note"
    NOTE="VaultWatch test note.md"
    for _ in $(seq 1 30); do tail -50 "$LOG" | grep -q "Fully synced" && break; sleep 1; done
    echo "VaultWatch activity test $(date)" > "$VAULT/$NOTE"; sleep 12
    tail -80 "$LOG" | grep -q "Upload.*$NOTE" && ok "upload of new note logged (shows in Activity)" || bad "no upload line for test note"
    rm -f "$VAULT/$NOTE"; sleep 12
    tail -80 "$LOG" | grep -q "Deleting remote file $NOTE" && ok "delete logged (shows in Activity)" || bad "no delete line for test note"
fi

echo
echo "== Last 15 log lines"
tail -15 "$LOG"
echo
echo "== Result: $PASS passed, $FAIL failed"
echo "Manual checks: menu icon state, Pause/Sync Now, View Log window, Launch at Login toggle, sleep/wake."
[[ $FAIL -eq 0 ]]
