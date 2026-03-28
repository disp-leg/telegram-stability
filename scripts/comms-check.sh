#!/bin/bash
# COMMS CHECK — Yuna diagnostic + repair routine
# Checks: tmux hygiene, telegram patches, process health, API send,
#         two-way receive verification, Tailscale, SSH
#
# Modes:
#   comms-check.sh          — full diagnostic (default)
#   comms-check.sh --fix    — diagnose + auto-repair (kill zombies, restart)
#   comms-check.sh --quick  — infra-only, skip two-way test

set -o pipefail

MODE="${1:-full}"
PASS=0
FAIL=0
WARN=0

BOT_TOKEN=$(grep 'TELEGRAM_BOT_TOKEN' ~/.claude/channels/telegram/.env 2>/dev/null | cut -d'=' -f2)
DM_CHAT="7194360736"
GRP_CHAT="-5127377005"
DIAG_LOG="$HOME/.claude/channels/telegram/diag.log"

ok()   { echo "  ✅ $1"; ((PASS++)); }
fail() { echo "  ❌ $1"; ((FAIL++)); }
warn() { echo "  ⚠️  $1"; ((WARN++)); }

echo "═══════════════════════════════════"
echo "  COMMS CHECK — $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════"
echo ""

# ─── 0. HUB SELF-PROTECTION ──────────────────────────────
# Walk up process tree to find our Claude and our telegram PID
# so --fix mode never kills the hub's own processes.
MY_CLAUDE_PID=""
check_pid=$$
for _ in $(seq 1 10); do
  parent=$(ps -o ppid= -p "$check_pid" 2>/dev/null | tr -d ' ')
  [ -z "$parent" ] && break
  cmd=$(ps -o command= -p "$parent" 2>/dev/null || true)
  if echo "$cmd" | grep -qE "^claude( |$)"; then
    MY_CLAUDE_PID="$parent"
    break
  fi
  check_pid="$parent"
done

MY_TG_PID=""
if [ -n "$MY_CLAUDE_PID" ]; then
  MY_TG_PID=$(pgrep -P "$MY_CLAUDE_PID" -f "bun.*telegram" 2>/dev/null | head -1 || true)
fi
# Fallback: if we can't find via parent, use the newest bun telegram
if [ -z "$MY_TG_PID" ]; then
  MY_TG_PID=$(pgrep -f 'bun.*telegram' 2>/dev/null | head -1 || true)
fi

MY_TMUX_SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "")

# ─── 1. TMUX ────────────────────────────────────────────
echo "▸ TMUX"
TMUX_SESSIONS=$(tmux list-sessions 2>/dev/null)
YUNA_COUNT=$(echo "$TMUX_SESSIONS" | grep -c "yuna" 2>/dev/null || echo 0)
OTHER_SESSIONS=$(echo "$TMUX_SESSIONS" | grep -v "yuna" | grep -v "^$" || true)

if [ "$YUNA_COUNT" -eq 1 ]; then
  WINDOWS=$(tmux list-windows -t yuna 2>/dev/null | wc -l | tr -d ' ')
  ok "yuna session active — $WINDOWS window(s)"
elif [ "$YUNA_COUNT" -gt 1 ]; then
  fail "MULTIPLE yuna sessions ($YUNA_COUNT) — conflict risk"
  if [ "$MODE" = "--fix" ]; then
    echo "  🔧 Killing duplicate yuna sessions..."
    # Keep the attached one, kill others
    ATTACHED=$(tmux list-sessions -F '#{session_name}:#{session_attached}' 2>/dev/null | grep 'yuna:1' | head -1 | cut -d: -f1)
    tmux list-sessions -F '#{session_name}' 2>/dev/null | grep yuna | while read s; do
      [ "$s" != "$ATTACHED" ] && tmux kill-session -t "$s" 2>/dev/null && echo "  🗑️  Killed session: $s"
    done
  fi
elif [ "$YUNA_COUNT" -eq 0 ]; then
  fail "yuna tmux session not found"
fi

# Check for rogue sessions that might have telegram
if [ -n "$OTHER_SESSIONS" ]; then
  echo "$OTHER_SESSIONS" | while read -r line; do
    SNAME=$(echo "$line" | cut -d: -f1)
    warn "extra session: $SNAME"
    if [ "$MODE" = "--fix" ]; then
      # Check if session has telegram processes
      SPIDS=$(tmux list-panes -t "$SNAME" -F '#{pane_pid}' 2>/dev/null)
      for spid in $SPIDS; do
        if pgrep -P "$spid" -f "telegram" >/dev/null 2>&1; then
          echo "  🔧 Session $SNAME has telegram — killing it"
          tmux kill-session -t "$SNAME" 2>/dev/null
          break
        fi
      done
    fi
  done
fi
echo ""

# ─── 2. TELEGRAM PROCESS ─────────────────────────────────
echo "▸ TELEGRAM PROCESS"
if [ -z "$BOT_TOKEN" ]; then
  fail "Bot token not found in .env"
  echo ""
else
  # Count telegram bun processes
  TG_PIDS=$(pgrep -f "bun.*telegram" 2>/dev/null || true)
  TG_COUNT=0
  [ -n "$TG_PIDS" ] && TG_COUNT=$(echo "$TG_PIDS" | wc -l | tr -d ' ')

  if [ "$TG_COUNT" -eq 0 ]; then
    fail "No telegram bot process running"
  elif [ "$TG_COUNT" -eq 1 ]; then
    ok "Single bot process (PID $(echo $TG_PIDS | head -1))"
  else
    fail "MULTIPLE telegram processes ($TG_COUNT) — will cause 409 conflicts. >1 is a FAILURE."
    echo "  PIDs: $(echo $TG_PIDS | tr '\n' ' ')"
    if [ "$MODE" = "--fix" ]; then
      # Keep the hub's process (parent has --channels flag), kill the rest
      HUB_PID=$(pgrep -f "claude.*--channels.*telegram" 2>/dev/null | head -1)
      KEEP_PID=""
      if [ -n "$HUB_PID" ]; then
        KEEP_PID=$(pgrep -P "$HUB_PID" -f "bun" 2>/dev/null | head -1)
      fi
      if [ -z "$KEEP_PID" ]; then
        KEEP_PID=$(echo "$TG_PIDS" | tail -1)
        echo "  🔧 Could not identify hub's process, keeping newest PID $KEEP_PID"
      else
        echo "  🔧 Keeping hub's PID $KEEP_PID, killing duplicates..."
      fi
      echo "$TG_PIDS" | while read pid; do
        [ -n "$pid" ] && [ "$pid" != "$KEEP_PID" ] && kill "$pid" 2>/dev/null && echo "  🔧 Killed duplicate PID $pid"
      done
      sleep 1
      NEW_COUNT=$(pgrep -f 'bun.*telegram' 2>/dev/null | wc -l | tr -d ' ')
      if [ "$NEW_COUNT" -eq 1 ]; then
        echo "  ✅ Down to 1 process. May need /mcp reconnect."
      elif [ "$NEW_COUNT" -eq 0 ]; then
        fail "All processes killed — run /mcp to restart"
      else
        echo "  ⚠️  Still $NEW_COUNT processes — manual intervention needed"
      fi
    fi
  fi

  # Singleton lock check
  LOCK_SOCK="$HOME/.claude/channels/telegram/telegram.sock"
  if [ -e "$LOCK_SOCK" ]; then
    ok "Singleton lock active ($LOCK_SOCK)"
  else
    warn "Singleton lock socket not found — patch may not be loaded"
  fi

  # Patch verification
  MARKET_FILE="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts"
  if grep -q "SINGLETON LOCK" "$MARKET_FILE" 2>/dev/null; then
    ok "Singleton patch applied"
  else
    warn "Singleton patch NOT applied — run: bash ~/.claude/patches/telegram-singleton.sh"
    if [ "$MODE" = "--fix" ]; then
      bash ~/.claude/patches/telegram-singleton.sh 2>/dev/null
      echo "  🔧 Patch re-applied. Run /mcp to load."
    fi
  fi

  # MCP transport — is bun's parent still claude?
  BUN_PID=$(pgrep -f "bun.*server.ts" | head -1)
  if [ -n "$BUN_PID" ]; then
    PARENT_PID=$(ps -o ppid= -p "$BUN_PID" | tr -d ' ')
    if [ "$PARENT_PID" = "1" ]; then
      fail "MCP ORPHANED — bot running but disconnected from Claude (ppid=1)"
      if [ "$MODE" = "--fix" ]; then
        echo "  🔧 Killing orphaned process..."
        kill "$BUN_PID" 2>/dev/null
      fi
    else
      PARENT_CMD=$(ps -o comm= -p "$PARENT_PID" 2>/dev/null)
      ok "MCP transport connected (parent: $PARENT_CMD, pid $PARENT_PID)"
    fi
  else
    warn "bun server.ts not found"
  fi

  # Webhook check
  WH_RESULT=$(curl -s --max-time 5 "https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo" 2>&1)
  WH_URL=$(echo "$WH_RESULT" | grep -o '"url":"[^"]*"' | cut -d'"' -f4)
  if [ -n "$WH_URL" ]; then
    fail "Webhook set: $WH_URL — blocks long-polling!"
    if [ "$MODE" = "--fix" ]; then
      curl -s "https://api.telegram.org/bot${BOT_TOKEN}/deleteWebhook" >/dev/null 2>&1
      echo "  🔧 Webhook deleted"
    fi
  else
    ok "No webhook (long-polling mode)"
  fi
fi
echo ""

# ─── 3. TELEGRAM PATCHES ─────────────────────────────────
echo "▸ PATCHES"
CACHE_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram"
VER=$(ls -1 "$CACHE_DIR" 2>/dev/null | sort -V | tail -1)
if [ -n "$VER" ]; then
  SERVER="$CACHE_DIR/$VER/server.ts"
  if grep -q 'allowed_updates' "$SERVER" 2>/dev/null; then
    ok "allowed_updates (reactions)"
  else
    fail "allowed_updates missing — reactions won't work"
    if [ "$MODE" = "--fix" ]; then
      bash ~/.claude/patches/telegram-reactions.sh "$VER"
    fi
  fi
  if grep -q 'replyPrefix' "$SERVER" 2>/dev/null; then
    ok "replyPrefix (quote context)"
  else
    fail "replyPrefix missing — reply context won't show"
    if [ "$MODE" = "--fix" ]; then
      bash ~/.claude/patches/telegram-reactions.sh "$VER"
    fi
  fi
  if grep -q "message_reaction" "$SERVER" 2>/dev/null; then
    ok "message_reaction handler"
  else
    fail "message_reaction handler missing"
    if [ "$MODE" = "--fix" ]; then
      bash ~/.claude/patches/telegram-reactions.sh "$VER"
    fi
  fi
else
  warn "No telegram plugin version found in cache"
fi
echo ""

# ─── 4. TELEGRAM SEND ────────────────────────────────────
echo "▸ TELEGRAM SEND"
if [ -n "$BOT_TOKEN" ]; then
  NONCE=$(date '+%s')

  # DM send
  DM_RESULT=$(curl -s --max-time 5 "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$DM_CHAT" \
    -d text="🛰️ Comms check ${NONCE} — reply to confirm two-way" 2>&1)
  DM_MSG_ID=$(echo "$DM_RESULT" | grep -o '"message_id":[0-9]*' | cut -d: -f2)
  if echo "$DM_RESULT" | grep -q '"ok":true'; then
    ok "DM send OK (msg_id: $DM_MSG_ID)"
  else
    fail "DM send FAILED"
  fi

  # Group send
  GRP_RESULT=$(curl -s --max-time 5 "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$GRP_CHAT" \
    -d text="🛰️ Comms check — group confirmed $(date '+%H:%M:%S')" 2>&1)
  if echo "$GRP_RESULT" | grep -q '"ok":true'; then
    ok "Group send OK"
  else
    fail "Group send FAILED"
  fi
fi
echo ""

# ─── 5. TWO-WAY RECEIVE TEST ─────────────────────────────
if [ "$MODE" != "--quick" ] && [ -n "$BOT_TOKEN" ]; then
  echo "▸ TWO-WAY RECEIVE"
  echo "  ⏳ Waiting for reply on Telegram (30s timeout)..."
  echo "     Reply to the DM comms check message to verify receive path."

  # Tail the diag log for evidence of inbound delivery
  if [ -f "$DIAG_LOG" ]; then
    BEFORE_LINES=$(wc -l < "$DIAG_LOG" | tr -d ' ')
  else
    BEFORE_LINES=0
  fi

  # Also check if Claude's MCP notification path works by watching stderr
  # We use a simple approach: poll getUpdates with offset to peek without stealing
  # Actually, we CAN'T poll getUpdates — it steals from grammy.
  # Instead, we rely on the user replying and Claude confirming in-session.
  echo "  📋 Receive verification requires in-session confirmation:"
  echo "     1. User replies on Telegram"
  echo "     2. Claude sees <channel> tag appear"
  echo "     3. Claude confirms 'Check Cleared' on Telegram"
  echo ""
  echo "  → This script verifies INFRA. Claude verifies RECEIVE in-session."
  echo ""
fi

# ─── 6. MSAP NODE HEALTH ─────────────────────────────────
echo "▸ MSAP NODES"
ACTIVE_STATE="$HOME/.claude/projects/-Users-dispatch/memory/active_state.md"
NODE_SESSIONS=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -v '^yuna$' || true)

if [ -z "$NODE_SESSIONS" ]; then
  echo "  (no active nodes)"
else
  echo "$NODE_SESSIONS" | while read -r node; do
    if tmux has-session -t "$node" 2>/dev/null; then
      # Check if claude is running in the node
      PANE_CMD=$(tmux list-panes -t "$node" -F '#{pane_current_command}' 2>/dev/null | head -1)
      if echo "$PANE_CMD" | grep -qi "claude\|node\|bun"; then
        ok "Node '$node' — alive (running: $PANE_CMD)"
      else
        warn "Node '$node' — session alive but Claude may not be running ($PANE_CMD)"
      fi
    fi
  done

  # Check for ghost entries in active_state (registered but no tmux session)
  if [ -f "$ACTIVE_STATE" ]; then
    grep "| running |" "$ACTIVE_STATE" 2>/dev/null | while IFS='|' read -r _ name _ _ _ _; do
      name=$(echo "$name" | xargs)
      if [ -n "$name" ] && [ "$name" != "*(no active nodes)*" ]; then
        if ! tmux has-session -t "$name" 2>/dev/null; then
          fail "Ghost node '$name' — in registry but no tmux session"
          if [ "$MODE" = "--fix" ]; then
            echo "  🔧 Removing ghost entry from registry"
            sed -i '' "/| $name |.*| running |/d" "$ACTIVE_STATE"
          fi
        fi
      fi
    done
  fi
fi
echo ""

# ─── 7. TAILSCALE ────────────────────────────────────────
echo "▸ TAILSCALE"
TS_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
if [ -x "$TS_BIN" ]; then
  TS_STATUS=$("$TS_BIN" status 2>&1)
  if echo "$TS_STATUS" | grep -q "dispatchs-mac-mini"; then
    ok "Mac Mini online"
  else
    fail "Mac Mini not found in Tailscale"
  fi
  echo "$TS_STATUS" | while read -r line; do
    if echo "$line" | grep -q "offline"; then
      DEV=$(echo "$line" | awk '{print $2}')
      warn "$DEV — offline"
    fi
  done
else
  warn "Tailscale binary not found"
fi
echo ""

# ─── 8. SSH ───────────────────────────────────────────────
echo "▸ SSH"
if systemsetup -getremotelogin 2>/dev/null | grep -q "On"; then
  ok "SSH enabled"
else
  warn "Could not verify SSH status"
fi
echo ""

# ─── SUMMARY ─────────────────────────────────────────────
echo "═══════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo "  ✅ ALL CLEAR — $PASS passed, $WARN warnings"
else
  echo "  ❌ $FAIL FAILED — $PASS passed, $WARN warnings"
  if [ "$MODE" != "--fix" ]; then
    echo "  💡 Run: comms-check.sh --fix  to auto-repair"
  fi
fi
echo "═══════════════════════════════════"
