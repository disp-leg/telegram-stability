#!/usr/bin/env bash
# telegram-watchdog.sh — Runs via cron every 60s.
# Detects: duplicate processes, zombies, total absence.
# Alerts via Bot API (works even when MCP is broken).

TOKEN=$(grep 'BOT_TOKEN' ~/.claude/channels/telegram/.env 2>/dev/null | cut -d'=' -f2)
GRP_CHAT="-5127377005"

[ -z "$TOKEN" ] && exit 0

alert() {
  curl -s "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d "chat_id=${GRP_CHAT}" \
    --data-urlencode "text=$1" >/dev/null 2>&1
}

# Count telegram bun processes
TG_PIDS=$(pgrep -f "bun.*telegram" 2>/dev/null || true)
TG_COUNT=0
[ -n "$TG_PIDS" ] && TG_COUNT=$(echo "$TG_PIDS" | wc -l | tr -d ' ')

# Multiple processes — kill extras
if [ "$TG_COUNT" -gt 1 ]; then
  HUB_PID=$(pgrep -f "claude.*--channels.*telegram" 2>/dev/null | head -1)
  if [ -n "$HUB_PID" ]; then
    HUB_TG=$(pgrep -P "$HUB_PID" -f "bun" 2>/dev/null | head -1)
    KILLED=0
    echo "$TG_PIDS" | while read pid; do
      [ -n "$pid" ] && [ "$pid" != "$HUB_TG" ] && kill "$pid" 2>/dev/null && ((KILLED++))
    done
  fi
  alert "⚠️ Watchdog: killed $(($TG_COUNT - 1)) duplicate telegram process(es)"
fi

# Zero processes — telegram is down
if [ "$TG_COUNT" -eq 0 ]; then
  alert "🔴 Watchdog: Telegram is DOWN. No bot process running. Run /mcp at terminal to restart."
fi

# Zombie check (ppid=1)
if [ "$TG_COUNT" -eq 1 ]; then
  TG_PID=$(echo "$TG_PIDS" | head -1)
  PPID_VAL=$(ps -o ppid= -p "$TG_PID" 2>/dev/null | tr -d ' ')
  if [ "$PPID_VAL" = "1" ]; then
    kill "$TG_PID" 2>/dev/null
    alert "⚠️ Watchdog: killed orphaned telegram zombie (ppid=1). Run /mcp to restart."
  fi
fi
