#!/bin/bash
set -euo pipefail
SD="/tmp/tg-lock-test-$$"; mkdir -p "$SD"
SIM="/tmp/tg-singleton-tests/sim.ts"
PASS=0; FAIL=0; TOTAL=0
check() { ((TOTAL++)); if [ "$1" = "P" ]; then ((PASS++)); echo "  ✅ $2"; else ((FAIL++)); echo "  ❌ $2 — $3"; fi; }
cleanup() { rm -rf "$SD"; }; trap cleanup EXIT

echo "═══════════════════════════════════"
echo "  SINGLETON LOCK TEST SUITE"
echo "═══════════════════════════════════"

echo "▸ T1: Single instance"
OUT=$(S="$SD/t1.sock" H=1 bun "$SIM"); echo "$OUT" | grep -q "ACQUIRED" && check P "Acquires lock" || check F "No acquire" "$OUT"

echo "▸ T2: Concurrent rejection"
S="$SD/t2.sock" H=3 bun "$SIM" & P1=$!; sleep 2
OUT=$(S="$SD/t2.sock" H=1 bun "$SIM" || true); echo "$OUT" | grep -q "REJECTED" && check P "Second rejected" || check F "Not rejected" "$OUT"
kill $P1 2>/dev/null; wait $P1 2>/dev/null

echo "▸ T3: Stale socket recovery"
S="$SD/t3.sock" H=10 bun "$SIM" & P2=$!; sleep 1; kill -9 $P2 2>/dev/null; wait $P2 2>/dev/null; sleep 1
OUT=$(S="$SD/t3.sock" H=1 bun "$SIM"); echo "$OUT" | grep -q "ACQUIRED" && check P "Stale recovered" || check F "No recovery" "$OUT"

echo "▸ T4: Triple concurrent"
S="$SD/t4.sock" H=3 bun "$SIM" & PA=$!; sleep 2
OB=$(S="$SD/t4.sock" H=1 bun "$SIM" || true); OC=$(S="$SD/t4.sock" H=1 bun "$SIM" || true)
B=$(echo "$OB" | grep -c "REJECTED"); C=$(echo "$OC" | grep -c "REJECTED")
[ "$B" -eq 1 ] && [ "$C" -eq 1 ] && check P "Both rejected" || check F "Not all rejected" "B=$B C=$C"
kill $PA 2>/dev/null; wait $PA 2>/dev/null

echo "▸ T5: Sequential handoff"
S="$SD/t5.sock" H=2 bun "$SIM" & PD=$!; sleep 3; wait $PD 2>/dev/null
OUT=$(S="$SD/t5.sock" H=1 bun "$SIM"); echo "$OUT" | grep -q "ACQUIRED" && check P "Handoff works" || check F "No handoff" "$OUT"

echo "▸ T6: Rapid fire"
S="$SD/t6.sock" H=3 bun "$SIM" & PF=$!; sleep 2; REJ=0
for i in 2 3 4 5; do OUT=$(S="$SD/t6.sock" H=1 bun "$SIM" || true); echo "$OUT" | grep -q "REJECTED" && ((REJ++)); done
[ "$REJ" -eq 4 ] && check P "4/4 rejected" || check F "Rapid fire" "$REJ/4"
kill $PF 2>/dev/null; wait $PF 2>/dev/null

echo ""; echo "═══════════════════════════════════"
echo "  RESULTS: $PASS/$TOTAL passed, $FAIL failed"
echo "═══════════════════════════════════"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
