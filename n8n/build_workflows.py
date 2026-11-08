#!/usr/bin/env python3
"""Generates the n8n workflow files in n8n/workflows/ (import these into n8n).

Kept as code so the workflows are reviewable and reproducible. Credentials are
referenced by NAME; after import, n8n asks you to pick the matching credential
on any node where it can't match automatically.
"""
import json, pathlib, uuid

OUT = pathlib.Path(__file__).parent / "workflows"
OWNER_CHAT_ID = "8995080526"   # Brett's Telegram ID (not a secret)

CRED = {
    "approver": {"postgres": {"id": "", "name": "SCI DB – Approver"}},
    "sales":    {"postgres": {"id": "", "name": "SCI DB – Sales"}},
    "telegram": {"telegramApi": {"id": "", "name": "SCI – Telegram Bot"}},
}

def node(name, type_, version, params, pos, creds=None, **extra):
    n = {"id": str(uuid.uuid5(uuid.NAMESPACE_URL, "sci/" + name)), "name": name,
         "type": type_, "typeVersion": version, "position": pos, "parameters": params}
    if creds: n["credentials"] = creds
    n.update(extra)
    return n

def link(*pairs):
    """pairs: (from, to) or (from, to, output_index)"""
    conns = {}
    for p in pairs:
        src, dst, idx = (p + (0,))[:3]
        outs = conns.setdefault(src, {"main": []})["main"]
        while len(outs) <= idx: outs.append([])
        outs[idx].append({"node": dst, "type": "main", "index": 0})
    return conns

def pg(name, query, params_expr, pos, cred):
    opts = {"queryReplacement": params_expr} if params_expr else {}
    return node(name, "n8n-nodes-base.postgres", 2.6,
                {"operation": "executeQuery", "query": query, "options": opts}, pos, CRED[cred])

def tg_send(name, chat, text, pos, extra_fields=None, reply_markup=None):
    params = {"chatId": chat, "text": text,
              "additionalFields": {"appendAttribution": False, **(extra_fields or {})}}
    if reply_markup: params.update(reply_markup)
    return node(name, "n8n-nodes-base.telegram", 1.2, params, pos, CRED["telegram"])

def workflow(name, nodes, connections, error_wf=True):
    settings = {"executionOrder": "v1", "saveDataSuccessExecution": "none", "saveManualExecutions": True}
    return {"name": name, "nodes": nodes, "connections": connections, "settings": settings,
            "active": False, "pinData": {}, "tags": []}

# ---------------------------------------------------------------- 1. Error alerts
error_alerts = workflow("SCI – Error Alerts", [
    node("When any workflow fails", "n8n-nodes-base.errorTrigger", 1, {}, [0, 0]),
    tg_send("Alert Brett on Telegram", OWNER_CHAT_ID,
            "={{ '⚠️ SCI workflow failed\\n\\nWorkflow: ' + $json.workflow.name"
            " + '\\nStep: ' + ($json.execution.lastNodeExecuted || 'unknown')"
            " + '\\nError: ' + (($json.execution.error && $json.execution.error.message) || 'unknown').slice(0, 300)"
            " + ($json.execution.url ? '\\n\\nDetails: ' + $json.execution.url : '') }}",
            [260, 0]),
], link(("When any workflow fails", "Alert Brett on Telegram")))

# ---------------------------------------------------------------- 2. Telegram bot
PARSE_JS = r"""
// Turn raw Telegram updates into simple commands. Anything else is dropped.
const out = [];
$input.all().forEach((item, i) => {
  const u = item.json;
  const cb = u.callback_query;
  const msg = u.message;
  let kind = 'ignore', approvalId = null, decision = null;
  if (cb) {
    const m = /^ap:([0-9a-f-]{36}):(approved|rejected)$/.exec(cb.data || '');
    if (m) { kind = 'decision'; approvalId = m[1]; decision = m[2]; }
  } else if (msg && typeof msg.text === 'string') {
    const cmd = msg.text.trim().split(/\s+/)[0].split('@')[0].toLowerCase();
    if (['/pause', '/resume', '/status', '/help', '/start'].includes(cmd)) kind = cmd.slice(1);
  }
  if (kind === 'ignore') return;
  out.push({ json: {
    kind, approvalId, decision,
    fromId: String(cb ? cb.from.id : msg.from.id),
    chatId: String(cb ? cb.message.chat.id : msg.chat.id),
    callbackId: cb ? cb.id : null,
    messageId: cb ? cb.message.message_id : null,
    originalText: cb ? (cb.message.text || '') : '',
  }, pairedItem: { item: i } });
});
return out;
""".strip()

P = "$('Read the command').item.json"
telegram_bot = workflow("SCI – Telegram Bot", [
    node("Telegram message or button", "n8n-nodes-base.telegramTrigger", 1.2,
         {"updates": ["message", "callback_query"], "additionalFields": {}}, [0, 0], CRED["telegram"]),
    node("Read the command", "n8n-nodes-base.code", 2, {"jsCode": PARSE_JS}, [240, 0]),
    pg("Ask the database (checks it's you)",
       "select sci.handle_telegram($1, $2, nullif($3, '')::uuid, nullif($4, '')) as reply",
       "={{ [ $json.kind, $json.fromId, $json.approvalId || '', $json.decision || '' ] }}",
       [480, 0], "approver"),
    node("Is it from Brett?", "n8n-nodes-base.if", 2.2, {
        "conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose", "version": 2},
                       "conditions": [{"id": "has-reply", "leftValue": "={{ $json.reply }}", "rightValue": "",
                                       "operator": {"type": "string", "operation": "notEmpty", "singleValue": True}}],
                       "combinator": "and"},
        "options": {}}, [720, 0]),
    node("Was it a button?", "n8n-nodes-base.if", 2.2, {
        "conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose", "version": 2},
                       "conditions": [{"id": "is-button", "leftValue": f"={{{{ {P}.kind }}}}", "rightValue": "decision",
                                       "operator": {"type": "string", "operation": "equals"}}],
                       "combinator": "and"},
        "options": {}}, [960, 0]),
    node("Confirm button press", "n8n-nodes-base.telegram", 1.2, {
        "resource": "callback", "queryId": f"={{{{ {P}.callbackId }}}}",
        "additionalFields": {"text": "={{ $('Ask the database (checks it\\'s you)').item.json.reply.slice(0, 190) }}"}},
        [1200, -100], CRED["telegram"]),
    node("Update the approval card", "n8n-nodes-base.telegram", 1.2, {
        "resource": "message", "operation": "editMessageText",
        "chatId": f"={{{{ {P}.chatId }}}}", "messageId": f"={{{{ {P}.messageId }}}}",
        "updateFields": {}, "replyMarkup": "none",
        "text": f"={{{{ {P}.originalText + '\\n\\n— ' + $('Ask the database (checks it\\'s you)').item.json.reply }}}}"},
        [1440, -100], CRED["telegram"]),
    tg_send("Reply to command", f"={{{{ {P}.chatId }}}}",
            "={{ $('Ask the database (checks it\\'s you)').item.json.reply }}", [1200, 100]),
], link(("Telegram message or button", "Read the command"),
        ("Read the command", "Ask the database (checks it's you)"),
        ("Ask the database (checks it's you)", "Is it from Brett?"),
        ("Is it from Brett?", "Was it a button?"),
        ("Was it a button?", "Confirm button press", 0),
        ("Was it a button?", "Reply to command", 1),
        ("Confirm button press", "Update the approval card")))

# ---------------------------------------------------------------- 3. Test approval card
TEST_SQL = """
with o as (
  insert into sci.outbound_actions (created_by, channel, prospect_id, recipient, subject, body, idempotency_key, status, is_test)
  values ('sales', 'email', '00000000-0000-0000-0000-0000000000d1', 'dana@riverbendplumbing.test',
          'TEST: Quick idea for Riverbend Plumbing',
          'This is a TEST draft to check that approval buttons work. It can never be sent.',
          'test-approval:' || gen_random_uuid(), 'pending_approval', true)
  returning id, recipient, subject, body
), a as (
  insert into sci.approvals (subject_table, subject_id, summary)
  select 'outbound_actions', id, 'TEST email to ' || recipient from o
  returning id, subject_id
)
select a.id as approval_id, o.recipient, o.subject, o.body from a join o on o.id = a.subject_id
""".strip()

test_card = workflow("SCI – Test Approval Card", [
    node("Click 'Execute workflow' to test", "n8n-nodes-base.manualTrigger", 1, {}, [0, 0]),
    pg("Create a TEST draft", TEST_SQL, None, [240, 0], "sales"),
    tg_send("Send approval card", OWNER_CHAT_ID,
            "={{ '📝 Approval needed (TEST)\\n\\nTo: ' + $json.recipient + '\\nSubject: ' + $json.subject + '\\n\\n' + $json.body }}",
            [480, 0], reply_markup={
                "replyMarkup": "inlineKeyboard",
                "inlineKeyboard": {"rows": [{"row": {"buttons": [
                    {"text": "✅ Approve", "additionalFields": {"callback_data": "={{ 'ap:' + $json.approval_id + ':approved' }}"}},
                    {"text": "❌ Reject",  "additionalFields": {"callback_data": "={{ 'ap:' + $json.approval_id + ':rejected' }}"}},
                ]}}]}}),
], link(("Click 'Execute workflow' to test", "Create a TEST draft"), ("Create a TEST draft", "Send approval card")))

if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    for fname, wf in [("01_error_alerts.json", error_alerts), ("02_telegram_bot.json", telegram_bot),
                      ("03_test_approval_card.json", test_card)]:
        (OUT / fname).write_text(json.dumps(wf, indent=2, ensure_ascii=False))
        print("wrote", OUT / fname)
