#!/usr/bin/env python3
"""Builds runnable TEST copies of the real workflows for a local n8n:
- triggers become a Manual trigger (+ a Code node emitting fake Telegram updates)
- Telegram steps become Set steps that evaluate the SAME expressions, so we can
  check what would have been sent without a real bot.
Usage: make_test_variants.py <outdir> <approval_id_for_button_test>
"""
import json, pathlib, sys, copy

ROOT = pathlib.Path(__file__).resolve().parents[1] / "workflows"
out, approval_id = pathlib.Path(sys.argv[1]), sys.argv[2]
out.mkdir(parents=True, exist_ok=True)
CRED_IDS = {"SCI DB – Approver": "credAppr", "SCI DB – Sales": "credSales", "SCI – Telegram Bot": "credTg"}

def fix_creds(n):
    for v in n.get("credentials", {}).values():
        v["id"] = CRED_IDS[v["name"]]

def telegram_to_set(n):
    p = n["parameters"]
    fields = {k: p[k] for k in ("chatId", "text", "queryId", "messageId") if k in p}
    if "additionalFields" in p and "text" in p["additionalFields"]:
        fields["answerText"] = p["additionalFields"]["text"]
    for r in p.get("inlineKeyboard", {}).get("rows", []):
        for i, b in enumerate(r["row"]["buttons"]):
            fields[f"button{i}"] = b["additionalFields"]["callback_data"]
    n.update(type="n8n-nodes-base.set", typeVersion=3.4, parameters={
        "assignments": {"assignments": [
            {"id": k, "name": k, "value": v if str(v).startswith("=") else str(v), "type": "string"}
            for k, v in fields.items()]},
        "options": {}})
    n.pop("credentials", None)

def variant(fname, wf_id, fake_updates=None):
    wf = json.loads((ROOT / fname).read_text())
    wf["id"] = wf_id
    wf["name"] = "TEST " + wf["name"]
    for n in wf["nodes"]:
        fix_creds(n)
        if n["type"] == "n8n-nodes-base.telegram":
            telegram_to_set(n)
        elif n["type"] == "n8n-nodes-base.telegramTrigger":
            n.update(type="n8n-nodes-base.code", typeVersion=2, parameters={
                "jsCode": "return " + json.dumps([{"json": u} for u in fake_updates]) + ";"})
            n.pop("credentials", None)
            wf["nodes"].append({"id": "start", "name": "Start", "type": "n8n-nodes-base.manualTrigger",
                                "typeVersion": 1, "position": [-240, 0], "parameters": {}})
            wf["connections"]["Start"] = {"main": [[{"node": n["name"], "type": "main", "index": 0}]]}
    (out / fname).write_text(json.dumps(wf, indent=2, ensure_ascii=False))

OWNER, STRANGER = 111111, 999999
def msg(text, who): return {"update_id": 1, "message": {"message_id": 5, "from": {"id": who}, "chat": {"id": who}, "text": text}}
updates = [
    msg("/status", OWNER),
    msg("/pause", STRANGER),                                   # must be ignored
    msg("hello there", OWNER),                                 # not a command: ignored
    {"update_id": 2, "callback_query": {"id": "cbq1", "from": {"id": OWNER}, "data": f"ap:{approval_id}:approved",
                                         "message": {"message_id": 77, "chat": {"id": OWNER}, "text": "📝 Approval needed (TEST)"}}},
    {"update_id": 3, "callback_query": {"id": "cbq2", "from": {"id": STRANGER}, "data": f"ap:{approval_id}:rejected",
                                         "message": {"message_id": 78, "chat": {"id": STRANGER}, "text": "x"}}},
]
variant("03_test_approval_card.json", "testCard")
variant("02_telegram_bot.json", "testBot", updates)
variant("01_error_alerts.json", "testErr")
print("ok")
