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
check "owner's /prospect added a business; stranger's did not" "select exists(select 1 from sci.organizations where name='Bartram Trail Dental') and not exists(select 1 from sci.organizations where name='Sneaky Biz')"
grep -q "Approved. (Sending is OFF" "$WORK/bot.out" && echo "PASS approval card text gets updated" || { echo "FAIL card update"; cat "$WORK/bot.out"; exit 1; }

echo "== 3. Sales research workflow (Claude replaced by a scripted stand-in: pause, then result)"
"$N8N" import:workflow --input="$WORK/04_sales_research.json" >/dev/null 2>&1
"$N8N" execute --id=testResearch --rawOutput > "$WORK/research.out" 2>&1 || { cat "$WORK/research.out"; exit 1; }
cp "$WORK/research.out" /tmp/ 2>/dev/null || true
check "first queued prospect was researched and scored (66 -> qualified)" "select fit_score=66 and stage='qualified' from sci.prospects p join sci.tasks t on t.related_id=p.id where t.type='research_prospect' and t.status='done'"
check "honest finding saved as verified" "select count(*)=1 from sci.research_findings where status='verified' and statement like 'Homepage headline%'"
check "made-up source was downgraded to inferred" "select count(*)=1 from sci.research_findings where status='inferred' and statement like 'Has 40 employees%(source not confirmed)'"
check "usage from BOTH Claude calls was costed" "select cost_usd = round((45000*4 + 3000*20 + 3000*0.2)/1e6 + 3*0.01, 4) from sci.llm_usage order by created_at desc limit 1"
check "run marked succeeded" "select status='succeeded' from sci.agent_runs order by started_at desc limit 1"
grep -q "couldn't be matched" "$WORK/research.out" && echo "PASS Telegram summary warns about the unconfirmed claim" || { echo "FAIL summary"; exit 1; }
check "research saved the official website it found" "select count(*)=1 from sci.organizations o join sci.prospects p on p.organization_id=o.id join sci.tasks t on t.related_id=p.id where t.type='research_prospect' and t.status='done' and o.domain='official-site.test'"

echo "== 4. Weekly discovery workflow"
"$N8N" import:workflow --input="$WORK/05_weekly_discovery.json" >/dev/null 2>&1
"$N8N" execute --id=testDiscovery --rawOutput > "$WORK/disc.out" 2>&1 || { cat "$WORK/disc.out"; exit 1; }
cp "$WORK/disc.out" /tmp/ 2>/dev/null || true
check "2 new candidates saved; already-known business skipped" "select count(*)=2 from sci.prospect_candidates"
check "real signal kept as verified" "select signal_status='verified' from sci.prospect_candidates where name='Ancient City Accounting'"
check "unconfirmed signal downgraded to inferred" "select signal_status='inferred' and source_url is null from sci.prospect_candidates where name='Made Up Signal LLC'"
CAND=$("${PSQL[@]}" -c "select id from sci.prospect_candidates where name='Ancient City Accounting'")
grep -q "dc:$CAND:research" "$WORK/disc.out" && echo "PASS candidate card carries Research button" || { echo "FAIL card buttons"; exit 1; }
grep -q "Weekly discovery:" "$WORK/disc.out" && echo "PASS header message produced" || { echo "FAIL header"; exit 1; }

echo "== 5. Tapping Research on a candidate (through the bot workflow)"
python3 - "$WORK/02_telegram_bot.json" "$CAND" <<'PY'
import json, sys
p, cand = sys.argv[1], sys.argv[2]
wf = json.load(open(p)); wf["id"] = "testBot2"; wf["name"] += " 2"
for n in wf["nodes"]:
    if n["name"] == "Telegram message or button":
        n["parameters"]["jsCode"] = "return " + json.dumps([{"json": {"update_id": 9, "callback_query": {"id": "cb9", "from": {"id": 111111},
            "data": f"dc:{cand}:research", "message": {"message_id": 90, "chat": {"id": 111111}, "text": "🧭 Ancient City Accounting"}}}}]) + ";"
json.dump(wf, open(p.replace(".json", "_2.json"), "w"))
PY
"$N8N" import:workflow --input="$WORK/02_telegram_bot_2.json" >/dev/null 2>&1
"$N8N" execute --id=testBot2 --rawOutput > "$WORK/bot2.out" 2>&1 || { cat "$WORK/bot2.out"; exit 1; }
check "Research button queued the candidate for research" "select exists(select 1 from sci.tasks t join sci.prospects p on p.id=t.related_id join sci.organizations o on o.id=p.organization_id where o.name='Ancient City Accounting' and t.status='queued')"
echo "ALL N8N WORKFLOW TESTS PASSED"
