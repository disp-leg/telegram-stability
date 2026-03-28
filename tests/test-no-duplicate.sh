#!/bin/bash
MARKET_DIR="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram"
echo "Testing duplicate rejection against live plugin..."
cd "$MARKET_DIR"
OUTPUT=$(timeout 10 bun server.ts 2>&1 || true)
# Immediately clean up duplicates
HUB_TG=$(pgrep -P $(pgrep -f "claude.*--channels.*telegram" 2>/dev/null | head -1) -f "bun" 2>/dev/null | head -1)
pgrep -f "bun.*telegram" 2>/dev/null | while read pid; do
  [ -n "$pid" ] && [ "$pid" != "$HUB_TG" ] && kill "$pid" 2>/dev/null
done
if echo "$OUTPUT" | grep -q "singleton lock\|lock socket\|another instance"; then
  echo "✅ PASS: Second instance detected lock and exited"
  exit 0
else
  echo "❌ FAIL: Second instance did NOT detect lock (expected — patch not applied)"
  exit 1
fi
