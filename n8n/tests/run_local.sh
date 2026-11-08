#!/usr/bin/env bash
# Runs the workflows in a LOCAL n8n against a LOCAL scratch database (port 55440).
# Usage: run_local.sh <n8n-runner-script>   (needs the scratch DB from the test setup)
set -euo pipefail
N8N="$1"; HERE="$(cd "$(dirname "$0")" && pwd)"; WORK="$(mktemp -d)"
PSQL=(psql -h 127.0.0.1 -p 55440 -U postgres -At)

cat > "$WORK/creds.json" <<'EOF'
[
 {"id":"credAppr","name":"SCI DB – Approver","type":"postgres","data":{"host":"127.0.0.1","port":55440,"database":"postgres","user":"sci_approver","password":"testpw","ssl":"disable","maxConnections":5}},
 {"id":"credSales","name":"SCI DB – Sales","type":"postgres","data":{"host":"127.0.0.1","port":55440,"database":"postgres","user":"agent_sales","password":"testpw","ssl":"disable","maxConnections":5}},
 {"id":"credTg","name":"SCI – Telegram Bot","type":"telegramApi","data":{"accessToken":"0:dummy"}}
]
EOF
"$N8N" import:credentials --input="$WORK/creds.json" >/dev/null 2>&1

echo "== 1. Test approval card workflow"
python3 "$HERE/make_test_variants.py" "$WORK" "00000000-0000-0000-0000-000000000000" >/dev/null
for f in 01_error_alerts 03_test_approval_card; do "$N8N" import:workflow --input="$WORK/$f.json" >/dev/null 2>&1; done
"$N8N" execute --id=testCard --rawOutput > "$WORK/card.out" 2>&1 || { cat "$WORK/card.out"; exit 1; }
APPROVAL=$("${PSQL[@]}" -c "select id from sci.approvals where decision='pending' order by created_at desc limit 1")
echo "   created approval $APPROVAL"
grep -o '"button0": *"[^"]*"' "$WORK/card.out" | head -1
grep -q "ap:$APPROVAL:approved" "$WORK/card.out" && echo "PASS approve button carries the right approval id" || { echo "FAIL button data"; cat "$WORK/card.out"; exit 1; }

echo "== 2. Telegram bot workflow (5 fake updates: owner /status, stranger /pause, chatter, owner Approve, stranger Reject)"
python3 "$HERE/make_test_variants.py" "$WORK" "$APPROVAL" >/dev/null
"$N8N" import:workflow --input="$WORK/02_telegram_bot.json" >/dev/null 2>&1
"$N8N" execute --id=testBot --rawOutput > "$WORK/bot.out" 2>&1 || { cat "$WORK/bot.out"; exit 1; }
cp "$WORK/bot.out" "$WORK/card.out" /tmp/ 2>/dev/null || true

check() { if [ "$("${PSQL[@]}" -c "$2")" = "t" ]; then echo "PASS $1"; else echo "FAIL $1"; exit 1; fi; }
check "owner's Approve button approved the request"    "select decision='approved' and decided_by='111111' from sci.approvals where id='$APPROVAL'"
check "draft moved to approved (still can't send: sending OFF)" "select status='approved' from sci.outbound_actions o join sci.approvals a on a.subject_id=o.id where a.id='$APPROVAL'"
check "stranger's /pause was ignored"                  "select not global_pause from sci.system_controls"
grep -q "SCI status" "$WORK/bot.out" && echo "PASS /status reply was produced" || { echo "FAIL /status"; cat "$WORK/bot.out"; exit 1; }
grep -q "Approved. (Sending is OFF" "$WORK/bot.out" && echo "PASS approval card text gets updated" || { echo "FAIL card update"; cat "$WORK/bot.out"; exit 1; }
echo "ALL N8N WORKFLOW TESTS PASSED"
