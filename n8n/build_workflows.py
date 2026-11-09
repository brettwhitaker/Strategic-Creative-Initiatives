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
  let kind = 'ignore', target = null, decision = null, arg = null;
  if (cb) {
    let m = /^ap:([0-9a-f-]{36}):(approved|rejected)$/.exec(cb.data || '');
    if (m) { kind = 'decision'; target = m[1]; decision = m[2]; }
    m = /^dc:([0-9a-f-]{36}):(research|skip)$/.exec(cb.data || '');
    if (m) { kind = 'candidate'; target = m[1]; decision = m[2]; }
    m = /^rd:([0-9a-f-]{36})$/.exec(cb.data || '');
    if (m) { kind = 'redraft'; target = m[1]; }
    m = /^hw:([0-9a-f-]{36}):(replied|skip)$/.exec(cb.data || '');
    if (m) { kind = 'helpwanted'; target = m[1]; decision = m[2]; }
  } else if (msg && typeof msg.text === 'string') {
    const text = msg.text.trim();
    const cmd = text.split(/\s+/)[0].split('@')[0].toLowerCase();
    if (['/pause', '/resume', '/status', '/help', '/start', '/prospect'].includes(cmd)) {
      kind = cmd.slice(1);
      arg = text.slice(text.split(/\s+/)[0].length).trim().slice(0, 200);
    }
    // A reply to a draft card = notes for a rewrite.
    const replied = msg.reply_to_message && msg.reply_to_message.text || '';
    const ref = /Ref D-([0-9a-f]{8})/.exec(replied);
    if (kind === 'ignore' && ref && !text.startsWith('/')) { kind = 'redraft_note'; decision = ref[1]; arg = text.slice(0, 1500); }
  }
  if (kind === 'ignore') return;
  out.push({ json: {
    kind, target, decision, arg,
    fromId: String(cb ? cb.from.id : msg.from.id),
    chatId: String(cb ? cb.message.chat.id : msg.chat.id),
    callbackId: cb ? cb.id : '',
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
       "select sci.handle_telegram($1, $2, nullif($3, '')::uuid, nullif($4, ''), nullif($5, '')) as reply",
       "={{ [ $json.kind, $json.fromId, $json.target || '', $json.decision || '', $json.arg || '' ] }}",
       [480, 0], "approver"),
    node("Is it from Brett?", "n8n-nodes-base.if", 2.2, {
        "conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose", "version": 2},
                       "conditions": [{"id": "has-reply", "leftValue": "={{ $json.reply }}", "rightValue": "",
                                       "operator": {"type": "string", "operation": "notEmpty", "singleValue": True}}],
                       "combinator": "and"},
        "options": {}}, [720, 0]),
    node("Was it a button?", "n8n-nodes-base.if", 2.2, {
        "conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose", "version": 2},
                       "conditions": [{"id": "is-button", "leftValue": f"={{{{ {P}.callbackId }}}}", "rightValue": "",
                                       "operator": {"type": "string", "operation": "notEmpty", "singleValue": True}}],
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

# ---------------------------------------------------------------- 4. Sales: research prospects
SUBMIT_TOOL = {
    "name": "submit_research",
    "description": "Submit your complete research result for this prospect. Call exactly once, at the end.",
    "strict": True,
    "input_schema": {
        "type": "object", "additionalProperties": False,
        "required": ["business_summary", "official_name", "official_website", "industry", "size_estimate", "findings", "score_breakdown",
                     "top_opportunity", "recommended_service", "secondary_service", "disqualify_reason",
                     "public_contact", "open_questions"],
        "properties": {
            "business_summary": {"type": "string", "description": "2-3 sentences: what they do, who they serve, where."},
            "official_name": {"type": "string", "description": "The business's official name as shown on its website"},
            "official_website": {"type": "string", "description": "Official website URL you confirmed; empty string if not found"},
            "industry": {"type": "string"},
            "size_estimate": {"type": "string", "description": "e.g. '10-20 staff (inferred from team page)' or 'unknown'"},
            "findings": {"type": "array", "items": {
                "type": "object", "additionalProperties": False,
                "required": ["category", "statement", "status", "source_url", "evidence_quote"],
                "properties": {
                    "category": {"type": "string", "enum": ["website_copy", "blog_content", "email_newsletter", "social_media",
                                                            "reviews", "thought_leadership", "company_facts", "growth_signal",
                                                            "poor_fit_signal", "other"]},
                    "statement": {"type": "string"},
                    "status": {"type": "string", "enum": ["verified", "inferred", "unknown"]},
                    "source_url": {"type": "string", "description": "URL retrieved in this session; empty string if none"},
                    "evidence_quote": {"type": "string", "description": "Exact short quote from that page; empty unless verified"}}}},
            "score_breakdown": {"type": "object", "additionalProperties": False,
                "required": ["gap", "trust_driven", "ability_to_invest", "growth", "geography", "reachability"],
                "properties": {"gap": {"type": "integer", "description": "0-40"},
                               "trust_driven": {"type": "integer", "description": "0-10"},
                               "ability_to_invest": {"type": "integer", "description": "0-20"},
                               "growth": {"type": "integer", "description": "0-15"},
                               "geography": {"type": "integer", "description": "0-10"},
                               "reachability": {"type": "integer", "description": "0-5"}}},
            "top_opportunity": {"type": "string", "description": "The single most compelling way SCI could help, in one sentence."},
            "recommended_service": {"type": "string", "description": "ONE service from SCI's list"},
            "secondary_service": {"type": "string", "description": "Optional second service; empty string if none"},
            "disqualify_reason": {"type": "string", "description": "Empty unless a poor-fit rule clearly applies"},
            "public_contact": {"type": "object", "additionalProperties": False,
                "required": ["name", "role", "email", "source_url"],
                "description": "Public business contact seen on a retrieved page; all empty strings if none",
                "properties": {"name": {"type": "string"}, "role": {"type": "string"},
                               "email": {"type": "string"}, "source_url": {"type": "string"}}},
            "open_questions": {"type": "array", "items": {"type": "string"},
                               "description": "Things you could not determine that Brett may want to check"}}}}

BUILD_REQUEST_JS = r"""
// Build the Claude request from what the database returned.
const ctx = $json.ctx;
const k = ctx.knowledge || {};
const knowledge = ['positioning', 'icp', 'services', 'fit_rubric', 'evidence_policy']
  .map(key => '## ' + key.toUpperCase() + '\n' + String(k[key] || '').trim()).join('\n\n');
const request = {
  model: ctx.model,
  max_tokens: 16000,
  thinking: { type: 'adaptive' },
  output_config: { effort: ctx.effort },
  fallbacks: 'default',
  system: [
    { type: 'text', text: String(ctx.system_text).trim() },
    { type: 'text', text: 'SCI BUSINESS KNOWLEDGE\n\n' + knowledge, cache_control: { type: 'ephemeral' } },
  ],
  tools: [
    { type: 'web_search_20260209', name: 'web_search', max_uses: 4 },
    { type: 'web_fetch_20260209', name: 'web_fetch', max_uses: 5, max_content_tokens: 10000 },
    SUBMIT_TOOL_JSON,
  ],
  tool_choice: { type: 'auto' },
  messages: [{ role: 'user', content:
    'Research this prospect and finish by calling submit_research.' +
    (ctx.prospect.website ? '' : ' Its website is not on file: first find the OFFICIAL website with a search ' +
      '(not a directory listing), and only research it if you are confident it is the same business.') +
    '\n\n<prospect>\n' +
    JSON.stringify(ctx.prospect, null, 2) + '\n</prospect>' }],
};
return [{ json: { state: {
  ctx: { run_id: ctx.run_id, task_id: ctx.task_id, business: ctx.prospect.business_name },
  request, iter: 0, retrieved: [],
  usage: { model: ctx.model, input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0, web_searches: 0 },
} } }];
""".strip().replace("SUBMIT_TOOL_JSON", json.dumps(SUBMIT_TOOL))

AFTER_CALL_JS = r"""
// Add up usage, remember which URLs were actually retrieved, and continue if Claude paused.
const st = JSON.parse(JSON.stringify($('Prepare Claude call').last().json.state));
const res = $json;
const u = res.usage || {};
st.usage.input_tokens += u.input_tokens || 0;
st.usage.output_tokens += u.output_tokens || 0;
st.usage.cache_read_tokens += u.cache_read_input_tokens || 0;
st.usage.cache_write_tokens += u.cache_creation_input_tokens || 0;
st.usage.web_searches += (u.server_tool_use && u.server_tool_use.web_search_requests) || 0;
const walk = (v, inResult) => {
  if (v == null) return;
  if (typeof v === 'string') { if (inResult) for (const m of v.matchAll(/https?:\/\/[^\s"'<>)\]]+/g)) st.retrieved.push(m[0]); return; }
  if (Array.isArray(v)) { v.forEach(x => walk(x, inResult)); return; }
  if (typeof v === 'object') {
    const isRes = inResult || (typeof v.type === 'string' && v.type.endsWith('_tool_result'));
    for (const val of Object.values(v)) walk(val, isRes);
  }
};
walk(res.content, false);
st.iter += 1;
st.stop_reason = res.stop_reason;
if (res.stop_reason === 'pause_turn' && st.iter < 5) {
  st.request.messages.push({ role: 'assistant', content: res.content });
  return [{ json: { state: st, again: true } }];
}
st.final_content = res.content || [];
delete st.request;
return [{ json: { state: st, again: false } }];
""".strip()

VALIDATE_JS = r"""
// Anti-fabrication check: a 'verified' finding must point to a page Claude actually retrieved.
const st = $json.state;
// Normalize a URL to host+path (no scheme, www, query, fragment or trailing slash). No URL() in n8n's sandbox.
const norm = s => {
  const m = /^https?:\/\/(?:www\.)?([^\/?#\s]+)([^?#\s]*)/i.exec(String(s || '').trim());
  return m ? (m[1] + m[2].replace(/\/+$/, '')).toLowerCase() : null;
};
const seen = new Set(st.retrieved.map(norm).filter(Boolean));
const call = st.final_content.find(b => b.type === 'tool_use' && b.name === 'submit_research');
if (!call) {
  return [{ json: { ok: false, ctx: st.ctx, usage: st.usage,
    error: 'Claude finished without submitting research (stop reason: ' + st.stop_reason + ')' } }];
}
const r = typeof call.input === 'string' ? JSON.parse(call.input) : call.input;
let downgraded = 0;
r.findings = (r.findings || []).filter(f => f && f.statement).map(f => {
  if (!['verified', 'inferred', 'unknown'].includes(f.status)) f.status = 'unknown';
  if (f.status === 'verified' && !(f.source_url && f.evidence_quote && seen.has(norm(f.source_url)))) {
    downgraded++;
    return { ...f, status: 'inferred', evidence_quote: '', statement: f.statement + ' (source not confirmed)' };
  }
  return f;
});
if (r.public_contact && r.public_contact.source_url && !seen.has(norm(r.public_contact.source_url))) {
  r.public_contact = { name: '', role: '', email: '', source_url: '' };
}
return [{ json: { ok: true, result: r, downgraded, ctx: st.ctx, usage: st.usage } }];
""".strip()

def if_node(name, left, op, right, pos, typ="boolean"):
    cond = {"id": name, "leftValue": left, "rightValue": right, "operator": {"type": typ, "operation": op}}
    if op in ("true", "false", "notEmpty", "empty"): cond["operator"]["singleValue"] = True
    return node(name, "n8n-nodes-base.if", 2.2, {
        "conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose", "version": 2},
                       "conditions": [cond], "combinator": "and"}, "options": {}}, pos)

CLAUDE_CALL = node("Call Claude", "n8n-nodes-base.httpRequest", 4.2, {
    "method": "POST", "url": "https://api.anthropic.com/v1/messages",
    "authentication": "predefinedCredentialType", "nodeCredentialType": "anthropicApi",
    "sendHeaders": True, "headerParameters": {"parameters": [
        {"name": "anthropic-version", "value": "2023-06-01"},
        {"name": "anthropic-beta", "value": "server-side-fallback-2026-07-01"}]},
    "sendBody": True, "specifyBody": "json", "jsonBody": "={{ JSON.stringify($json.state.request) }}",
    "options": {"timeout": 300000}},
    [1680, 0], {"anthropicApi": {"id": "", "name": "SCI – Claude (Sales)"}},
    retryOnFail=True, maxTries=2, waitBetweenTries=5000)

V = "$('Check the research').item.json"
research = workflow("SCI – Sales: Research Prospects", [
    node("Run now (manual)", "n8n-nodes-base.manualTrigger", 1, {}, [0, -100]),
    node("Hourly 8 AM–7 PM ET", "n8n-nodes-base.scheduleTrigger", 1.2,
         {"rule": {"interval": [{"field": "cronExpression", "expression": "20 8-19 * * *"}]}}, [0, 100]),
    pg("Safety check (pause + budget)", "select ok, reason from sci.guard_check('sales', 0.60)", None, [240, 0], "sales"),
    if_node("OK to run?", "={{ $json.ok }}", "true", "", [480, 0]),
    pg("Take next research task",
       "select id from sci.claim_next_task_of_type('sales', 'research_prospect', 'n8n')", None, [720, 0], "sales"),
    pg("Load prospect + instructions",
       "select sci.sales_start_research($1::uuid, $2) as ctx",
       "={{ [ $json.id, String($execution.id) ] }}", [960, 0], "sales"),
    node("Build Claude request", "n8n-nodes-base.code", 2, {"jsCode": BUILD_REQUEST_JS}, [1200, 0]),
    node("Prepare Claude call", "n8n-nodes-base.code", 2, {"jsCode": "return $input.all();"}, [1440, 0]),
    CLAUDE_CALL,
    node("Collect results", "n8n-nodes-base.code", 2, {"jsCode": AFTER_CALL_JS}, [1920, 0]),
    if_node("Claude paused? Continue", "={{ $json.again }}", "true", "", [2160, 0]),
    node("Check the research", "n8n-nodes-base.code", 2, {"jsCode": VALIDATE_JS}, [2400, 100]),
    if_node("Got a result?", "={{ $json.ok }}", "true", "", [2640, 100]),
    pg("Save + score", "select sci.sales_save_research($1::uuid, $2::uuid, $3::jsonb, $4::jsonb) as saved",
       "={{ [ $json.ctx.run_id, $json.ctx.task_id, JSON.stringify($json.result), JSON.stringify($json.usage) ] }}",
       [2880, 0], "sales"),
    tg_send("Send summary to Brett", OWNER_CHAT_ID,
            "={{ $json.saved.summary + (" + V + ".downgraded ? '\\n⚠️ ' + " + V + ".downgraded + \" claim(s) couldn't be matched to a page and were marked 'inferred'.\" : '') }}",
            [3120, 0]),
    pg("Record failure", "select sci.sales_fail_research($1::uuid, $2::uuid, $3, $4::jsonb)",
       "={{ [ $json.ctx.run_id, $json.ctx.task_id, $json.error, JSON.stringify($json.usage) ] }}", [2880, 200], "sales"),
    tg_send("Tell Brett it failed", OWNER_CHAT_ID,
            "={{ '⚠️ Research failed for ' + " + V + ".ctx.business + '\\n' + " + V + ".error + '\\nIt will be retried automatically (up to 3 tries).' }}",
            [3120, 200]),
], link(("Run now (manual)", "Safety check (pause + budget)"),
        ("Hourly 8 AM–7 PM ET", "Safety check (pause + budget)"),
        ("Safety check (pause + budget)", "OK to run?"),
        ("OK to run?", "Take next research task"),
        ("Take next research task", "Load prospect + instructions"),
        ("Load prospect + instructions", "Build Claude request"),
        ("Build Claude request", "Prepare Claude call"),
        ("Prepare Claude call", "Call Claude"),
        ("Call Claude", "Collect results"),
        ("Collect results", "Claude paused? Continue"),
        ("Claude paused? Continue", "Prepare Claude call", 0),
        ("Claude paused? Continue", "Check the research", 1),
        ("Check the research", "Got a result?"),
        ("Got a result?", "Save + score", 0),
        ("Got a result?", "Record failure", 1),
        ("Save + score", "Send summary to Brett"),
        ("Record failure", "Tell Brett it failed")))
research["settings"]["timezone"] = "America/New_York"

# ---------------------------------------------------------------- 5. Sales: weekly prospect discovery
CANDIDATES_TOOL = {
    "name": "submit_candidates",
    "description": "Submit the prospect candidates you found. Call exactly once, at the end.",
    "strict": True,
    "input_schema": {"type": "object", "additionalProperties": False, "required": ["candidates"],
        "properties": {"candidates": {"type": "array", "items": {
            "type": "object", "additionalProperties": False,
            "required": ["name", "website", "city", "signal_type", "signal", "signal_status", "source_url", "evidence_quote"],
            "properties": {
                "name": {"type": "string"},
                "website": {"type": "string", "description": "Official website; empty string if not found"},
                "city": {"type": "string"},
                "signal_type": {"type": "string", "enum": ["hiring", "growth", "stale_content", "weak_messaging", "other"]},
                "signal": {"type": "string", "description": "One sentence: what shows they need help now"},
                "signal_status": {"type": "string", "enum": ["verified", "inferred"]},
                "source_url": {"type": "string", "description": "Page retrieved this session that shows the signal; empty if inferred"},
                "evidence_quote": {"type": "string", "description": "Exact short quote from that page; empty if inferred"}}}}}}}

BUILD_DISCOVERY_JS = r"""
const ctx = $json.ctx;
const k = ctx.knowledge || {};
const knowledge = ['positioning', 'icp', 'services', 'evidence_policy']
  .map(key => '## ' + key.toUpperCase() + '\n' + String(k[key] || '').trim()).join('\n\n');
const request = {
  model: ctx.model, max_tokens: 16000,
  thinking: { type: 'adaptive' }, output_config: { effort: ctx.effort }, fallbacks: 'default',
  system: [
    { type: 'text', text: String(ctx.system_text).trim() },
    { type: 'text', text: 'SCI BUSINESS KNOWLEDGE\n\n' + knowledge, cache_control: { type: 'ephemeral' } },
  ],
  tools: [
    { type: 'web_search_20260209', name: 'web_search', max_uses: 6 },
    { type: 'web_fetch_20260209', name: 'web_fetch', max_uses: 6, max_content_tokens: 8000 },
    CANDIDATES_TOOL_JSON,
  ],
  tool_choice: { type: 'auto' },
  messages: [{ role: 'user', content:
    'Find prospect candidates.\nCategory: ' + ctx.segment.category + '\nArea: ' + ctx.segment.area + '\n\n' +
    '<exclude>\n' + (ctx.exclude || []).join('\n') + '\n</exclude>\n\nFinish by calling submit_candidates.' }],
};
return [{ json: { state: {
  ctx: { run_id: ctx.run_id, segment: ctx.segment },
  request, iter: 0, retrieved: [],
  usage: { model: ctx.model, input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0, web_searches: 0 },
} } }];
""".strip().replace("CANDIDATES_TOOL_JSON", json.dumps(CANDIDATES_TOOL))

CHECK_CANDIDATES_JS = r"""
// A 'verified' signal must point to a page Claude actually retrieved; otherwise it becomes 'inferred'.
const st = $json.state;
const norm = s => {
  const m = /^https?:\/\/(?:www\.)?([^\/?#\s]+)([^?#\s]*)/i.exec(String(s || '').trim());
  return m ? (m[1] + m[2].replace(/\/+$/, '')).toLowerCase() : null;
};
const seen = new Set(st.retrieved.map(norm).filter(Boolean));
const call = st.final_content.find(b => b.type === 'tool_use' && b.name === 'submit_candidates');
if (!call) return [{ json: { ok: false, ctx: st.ctx, usage: st.usage,
  error: 'Discovery finished without submitting candidates (stop reason: ' + st.stop_reason + ')' } }];
const r = typeof call.input === 'string' ? JSON.parse(call.input) : call.input;
r.candidates = (r.candidates || []).slice(0, 8).map(c => {
  if (c.signal_status === 'verified' && !(c.source_url && c.evidence_quote && seen.has(norm(c.source_url)))) {
    return { ...c, signal_status: 'inferred', source_url: '', evidence_quote: '' };
  }
  if (c.signal_status !== 'verified') return { ...c, signal_status: 'inferred', source_url: '', evidence_quote: '' };
  return c;
});
return [{ json: { ok: true, result: r, ctx: st.ctx, usage: st.usage } }];
""".strip()

MESSAGES_JS = r"""
// One header message, then one card (with Research / Skip buttons) per new candidate.
const seg = $('Check the candidates').first().json.ctx.segment;
const rows = $input.all().map(i => i.json).filter(r => r.candidate_id);
if (!rows.length) return [{ json: { kind: 'header',
  text: '🧭 Weekly discovery (' + seg.category + ' in ' + seg.area + '): no new candidates this time. Next week tries a different category/area.' } }];
return [{ json: { kind: 'header', text: rows[0].header } },
        ...rows.map(r => ({ json: { kind: 'card', text: r.card, candidate_id: r.candidate_id } }))];
""".strip()

D = "$('Check the candidates').item.json"
discovery = workflow("SCI – Sales: Weekly Prospect Discovery", [
    node("Run now (manual)", "n8n-nodes-base.manualTrigger", 1, {}, [0, -100]),
    node("Mon & Wed 9:40 AM ET", "n8n-nodes-base.scheduleTrigger", 1.2,
         {"rule": {"interval": [{"field": "cronExpression", "expression": "40 9 * * 1,3"}]}}, [0, 100]),
    pg("Safety check (pause + budget)", "select ok, reason from sci.guard_check('sales', 0.80)", None, [240, 0], "sales"),
    if_node("OK to run?", "={{ $json.ok }}", "true", "", [480, 0]),
    pg("Pick category + area", "select sci.sales_start_discovery($1) as ctx", "={{ [ String($execution.id) ] }}", [720, 0], "sales"),
    node("Build Claude request", "n8n-nodes-base.code", 2, {"jsCode": BUILD_DISCOVERY_JS}, [960, 0]),
    node("Prepare Claude call", "n8n-nodes-base.code", 2, {"jsCode": "return $input.all();"}, [1200, 0]),
    {**CLAUDE_CALL, "position": [1440, 0]},
    node("Collect results", "n8n-nodes-base.code", 2, {"jsCode": AFTER_CALL_JS}, [1680, 0]),
    if_node("Claude paused? Continue", "={{ $json.again }}", "true", "", [1920, 0]),
    node("Check the candidates", "n8n-nodes-base.code", 2, {"jsCode": CHECK_CANDIDATES_JS}, [2160, 100]),
    if_node("Got a result?", "={{ $json.ok }}", "true", "", [2400, 100]),
    {**pg("Save new candidates", "select * from sci.sales_save_discovery($1::uuid, $2::jsonb, $3::jsonb)",
          "={{ [ $json.ctx.run_id, JSON.stringify($json.result), JSON.stringify($json.usage) ] }}", [2640, 0], "sales"),
     "alwaysOutputData": True},
    node("Prepare messages", "n8n-nodes-base.code", 2, {"jsCode": MESSAGES_JS}, [2880, 0]),
    if_node("Candidate card?", "={{ $json.kind }}", "equals", "card", [3120, 0], typ="string"),
    tg_send("Send candidate card", OWNER_CHAT_ID, "={{ $json.text }}", [3360, 100], reply_markup={
        "replyMarkup": "inlineKeyboard",
        "inlineKeyboard": {"rows": [{"row": {"buttons": [
            {"text": "🔎 Research", "additionalFields": {"callback_data": "={{ 'dc:' + $json.candidate_id + ':research' }}"}},
            {"text": "⏭ Skip", "additionalFields": {"callback_data": "={{ 'dc:' + $json.candidate_id + ':skip' }}"}},
        ]}}]}}),
    tg_send("Send summary", OWNER_CHAT_ID, "={{ $json.text }}", [3360, -100]),
    pg("Record failure", "update sci.agent_runs set status = 'failed', error = left($2, 2000), finished_at = now() where id = $1::uuid",
       "={{ [ $json.ctx.run_id, $json.error ] }}", [2640, 200], "sales"),
    tg_send("Tell Brett it failed", OWNER_CHAT_ID,
            "={{ '⚠️ Weekly prospect discovery failed: ' + " + D + ".error }}", [2880, 200]),
], link(("Run now (manual)", "Safety check (pause + budget)"),
        ("Mon & Wed 9:40 AM ET", "Safety check (pause + budget)"),
        ("Safety check (pause + budget)", "OK to run?"),
        ("OK to run?", "Pick category + area"),
        ("Pick category + area", "Build Claude request"),
        ("Build Claude request", "Prepare Claude call"),
        ("Prepare Claude call", "Call Claude"),
        ("Call Claude", "Collect results"),
        ("Collect results", "Claude paused? Continue"),
        ("Claude paused? Continue", "Prepare Claude call", 0),
        ("Claude paused? Continue", "Check the candidates", 1),
        ("Check the candidates", "Got a result?"),
        ("Got a result?", "Save new candidates", 0),
        ("Got a result?", "Record failure", 1),
        ("Save new candidates", "Prepare messages"),
        ("Prepare messages", "Candidate card?"),
        ("Candidate card?", "Send candidate card", 0),
        ("Candidate card?", "Send summary", 1),
        ("Record failure", "Tell Brett it failed")))
discovery["settings"]["timezone"] = "America/New_York"

# ---------------------------------------------------------------- 6. Sales: outreach drafts
DRAFT_TOOL = {
    "name": "submit_draft",
    "description": "Submit the email draft. Call exactly once.",
    "strict": True,
    "input_schema": {"type": "object", "additionalProperties": False,
        "required": ["subject", "body", "angle", "finding_ids_used", "note_for_brett"],
        "properties": {
            "subject": {"type": "string", "description": "Honest subject line, under 8 words"},
            "body": {"type": "string", "description": "Email body from greeting to the ask. NO signature, address or opt-out line."},
            "angle": {"type": "string", "enum": ["content", "social", "hiring", "hometown", "proof_point", "other"]},
            "finding_ids_used": {"type": "array", "items": {"type": "string"}},
            "note_for_brett": {"type": "string", "description": "One sentence: why this angle; anything to double-check"}}}}

BUILD_DRAFT_JS = r"""
const ctx = $json.ctx;
const k = ctx.knowledge || {};
const knowledge = ['positioning', 'services', 'outreach_rules']
  .map(key => '## ' + key.toUpperCase() + '\n' + String(k[key] || '').trim()).join('\n\n');
const request = {
  model: ctx.model, max_tokens: 8000,
  thinking: { type: 'adaptive' }, output_config: { effort: ctx.effort }, fallbacks: 'default',
  system: [
    { type: 'text', text: String(ctx.system_text).trim() },
    { type: 'text', text: 'SCI BUSINESS KNOWLEDGE\n\n' + knowledge, cache_control: { type: 'ephemeral' } },
  ],
  tools: [DRAFT_TOOL_JSON],
  tool_choice: { type: 'auto' },
  messages: [{ role: 'user', content:
    'Write the first-touch email for this prospect and finish by calling submit_draft.\n\n' +
    '<prospect>\n' + JSON.stringify(ctx.prospect, null, 2) + '\n</prospect>\n\n' +
    '<verified_findings>\n' + JSON.stringify(ctx.verified_findings, null, 2) + '\n</verified_findings>\n\n' +
    '<discovery_signal>\n' + JSON.stringify(ctx.discovery_signal) + '\n</discovery_signal>' +
    (ctx.previous_draft ? '\n\n<previous_draft>\nSubject: ' + ctx.previous_draft.subject + '\n\n' + ctx.previous_draft.body + '\n</previous_draft>' : '') +
    (ctx.owner_notes ? '\n\n<owner_notes>\n' + ctx.owner_notes + '\n</owner_notes>' : '') }],
};
return [{ json: { state: {
  ctx: { run_id: ctx.run_id, task_id: ctx.task_id, business: ctx.prospect.business_name,
         finding_ids: (ctx.verified_findings || []).map(f => f.id) },
  request, iter: 0, retrieved: [],
  usage: { model: ctx.model, input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0, web_searches: 0 },
} } }];
""".strip().replace("DRAFT_TOOL_JSON", json.dumps(DRAFT_TOOL))

CHECK_DRAFT_JS = r"""
// Basic quality gates. Anything doubtful is flagged on the card for Brett (he approves every draft).
const st = $json.state;
const call = st.final_content.find(b => b.type === 'tool_use' && b.name === 'submit_draft');
if (!call) return [{ json: { ok: false, ctx: st.ctx, usage: st.usage,
  error: 'Claude finished without a draft (stop reason: ' + st.stop_reason + ')' } }];
const d = typeof call.input === 'string' ? JSON.parse(call.input) : call.input;
const flags = [];
const known = new Set(st.ctx.finding_ids || []);
const unknownIds = (d.finding_ids_used || []).filter(id => !known.has(id));
if (unknownIds.length) flags.push('cited ' + unknownIds.length + ' finding id(s) that were not provided');
const words = String(d.body || '').trim().split(/\s+/).length;
if (words > 170) flags.push('long (' + words + ' words)');
if (/unsubscribe|opt.?out|\bP\.?O\.? Box\b/i.test(d.body || '')) flags.push('body contains its own footer text');
if (!String(d.subject || '').trim() || String(d.body || '').trim().length < 40) {
  return [{ json: { ok: false, ctx: st.ctx, usage: st.usage, error: 'Draft was empty or too short' } }];
}
if (flags.length) d.note_for_brett = (d.note_for_brett || '') + ' ⚠️ Check: ' + flags.join('; ') + '.';
return [{ json: { ok: true, draft: d, ctx: st.ctx, usage: st.usage } }];
""".strip()

drafts = workflow("SCI – Sales: Outreach Drafts", [
    node("Run now (manual)", "n8n-nodes-base.manualTrigger", 1, {}, [0, -100]),
    node("Hourly 8 AM–7 PM ET", "n8n-nodes-base.scheduleTrigger", 1.2,
         {"rule": {"interval": [{"field": "cronExpression", "expression": "50 8-19 * * *"}]}}, [0, 100]),
    pg("Safety check (pause + budget)", "select ok, reason from sci.guard_check('sales', 0.20)", None, [240, 0], "sales"),
    if_node("OK to run?", "={{ $json.ok }}", "true", "", [480, 0]),
    pg("Take next draft task", "select id from sci.claim_next_task_of_type('sales', 'draft_outreach', 'n8n')", None, [720, 0], "sales"),
    pg("Load prospect + findings", "select sci.sales_start_outreach($1::uuid, $2) as ctx",
       "={{ [ $json.id, String($execution.id) ] }}", [960, 0], "sales"),
    if_node("Opted out? Skip", "={{ $json.ctx.skip === true }}", "true", "", [1200, 0]),
    tg_send("Tell Brett it was skipped", OWNER_CHAT_ID, "={{ '⏭ ' + $json.ctx.reason }}", [1440, -150]),
    node("Build Claude request", "n8n-nodes-base.code", 2, {"jsCode": BUILD_DRAFT_JS}, [1440, 50]),
    node("Prepare Claude call", "n8n-nodes-base.code", 2, {"jsCode": "return $input.all();"}, [1680, 50]),
    {**CLAUDE_CALL, "position": [1920, 50]},
    node("Collect results", "n8n-nodes-base.code", 2, {"jsCode": AFTER_CALL_JS}, [2160, 50]),
    if_node("Claude paused? Continue", "={{ $json.again }}", "true", "", [2400, 50]),
    node("Check the draft", "n8n-nodes-base.code", 2, {"jsCode": CHECK_DRAFT_JS}, [2640, 150]),
    if_node("Got a draft?", "={{ $json.ok }}", "true", "", [2880, 150]),
    pg("Save draft + approval", "select sci.sales_save_outreach($1::uuid, $2::uuid, $3::jsonb, $4::jsonb) as saved",
       "={{ [ $json.ctx.run_id, $json.ctx.task_id, JSON.stringify($json.draft), JSON.stringify($json.usage) ] }}",
       [3120, 50], "sales"),
    tg_send("Send approval card", OWNER_CHAT_ID, "={{ $json.saved.card }}", [3360, 50], reply_markup={
        "replyMarkup": "inlineKeyboard",
        "inlineKeyboard": {"rows": [{"row": {"buttons": [
            {"text": "✅ Approve", "additionalFields": {"callback_data": "={{ 'ap:' + $json.saved.approval_id + ':approved' }}"}},
            {"text": "❌ Reject", "additionalFields": {"callback_data": "={{ 'ap:' + $json.saved.approval_id + ':rejected' }}"}},
        ]}}, {"row": {"buttons": [
          {"text": "✏️ Redraft", "additionalFields": {"callback_data": "={{ 'rd:' + $json.saved.approval_id }}"}},
        ]}}]}}),
    pg("Record failure", "select sci.sales_fail_research($1::uuid, $2::uuid, $3, $4::jsonb)",
       "={{ [ $json.ctx.run_id, $json.ctx.task_id, $json.error, JSON.stringify($json.usage) ] }}", [3120, 250], "sales"),
    tg_send("Tell Brett it failed", OWNER_CHAT_ID,
            "={{ '⚠️ Outreach draft failed for ' + $('Check the draft').item.json.ctx.business + '\\n' + $('Check the draft').item.json.error + '\\nIt will be retried automatically (up to 3 tries).' }}",
            [3360, 250]),
], link(("Run now (manual)", "Safety check (pause + budget)"),
        ("Hourly 8 AM–7 PM ET", "Safety check (pause + budget)"),
        ("Safety check (pause + budget)", "OK to run?"),
        ("OK to run?", "Take next draft task"),
        ("Take next draft task", "Load prospect + findings"),
        ("Load prospect + findings", "Opted out? Skip"),
        ("Opted out? Skip", "Tell Brett it was skipped", 0),
        ("Opted out? Skip", "Build Claude request", 1),
        ("Build Claude request", "Prepare Claude call"),
        ("Prepare Claude call", "Call Claude"),
        ("Call Claude", "Collect results"),
        ("Collect results", "Claude paused? Continue"),
        ("Claude paused? Continue", "Prepare Claude call", 0),
        ("Claude paused? Continue", "Check the draft", 1),
        ("Check the draft", "Got a draft?"),
        ("Got a draft?", "Save draft + approval", 0),
        ("Got a draft?", "Record failure", 1),
        ("Save draft + approval", "Send approval card"),
        ("Record failure", "Tell Brett it failed")))
drafts["settings"]["timezone"] = "America/New_York"

# ---------------------------------------------------------------- 7. Sales: weekly Help Wanted scan (read-only)
POSTS_TOOL = {
    "name": "submit_posts",
    "description": "Submit the help-wanted posts you found. Call exactly once, at the end.",
    "strict": True,
    "input_schema": {"type": "object", "additionalProperties": False, "required": ["posts"],
        "properties": {"posts": {"type": "array", "items": {
            "type": "object", "additionalProperties": False,
            "required": ["url", "platform", "community", "title", "posted", "location", "need_type", "summary", "quote", "fit_note", "suggested_reply"],
            "properties": {
                "url": {"type": "string", "description": "Exact URL of the post you retrieved"},
                "platform": {"type": "string", "enum": ["reddit", "craigslist", "other"]},
                "community": {"type": "string", "description": "e.g. 'Jacksonville Craigslist gigs' or the site/board name"},
                "title": {"type": "string"},
                "posted": {"type": "string", "description": "As shown on the post, or 'unknown'"},
                "location": {"type": "string"},
                "need_type": {"type": "string", "enum": ["website", "social_media", "content", "marketing", "other"]},
                "summary": {"type": "string"},
                "quote": {"type": "string", "description": "Short exact quote from the post"},
                "fit_note": {"type": "string"},
                "suggested_reply": {"type": "string", "description": "60-110 words, helpful first, for Brett to post himself"}}}}}}}

BUILD_HW_JS = r"""
const ctx = $json.ctx;
const k = ctx.knowledge || {};
const knowledge = ['positioning', 'services'].map(key => '## ' + key.toUpperCase() + '\n' + String(k[key] || '').trim()).join('\n\n');
const request = {
  model: ctx.model, max_tokens: 16000,
  thinking: { type: 'adaptive' }, output_config: { effort: ctx.effort }, fallbacks: 'default',
  system: [
    { type: 'text', text: String(ctx.system_text).trim() },
    { type: 'text', text: 'SCI BUSINESS KNOWLEDGE\n\n' + knowledge, cache_control: { type: 'ephemeral' } },
  ],
  tools: [
    { type: 'web_search_20260209', name: 'web_search', max_uses: 6 },
    { type: 'web_fetch_20260209', name: 'web_fetch', max_uses: 6, max_content_tokens: 6000 },
    POSTS_TOOL_JSON,
  ],
  tool_choice: { type: 'auto' },
  messages: [{ role: 'user', content:
    'Today is ' + ctx.today + '. Find recent help-wanted posts and finish by calling submit_posts.\n\n' +
    '<already_found>\n' + (ctx.known_urls || []).join('\n') + '\n</already_found>' }],
};
return [{ json: { state: {
  ctx: { run_id: ctx.run_id }, request, iter: 0, retrieved: [],
  usage: { model: ctx.model, input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0, web_searches: 0 },
} } }];
""".strip().replace("POSTS_TOOL_JSON", json.dumps(POSTS_TOOL))

CHECK_POSTS_JS = r"""
// Keep only posts whose URL Claude actually retrieved in this run (no invented posts).
const st = $json.state;
const norm = s => {
  const m = /^https?:\/\/(?:www\.|old\.)?([^\/?#\s]+)([^?#\s]*)/i.exec(String(s || '').trim());
  return m ? (m[1] + m[2].replace(/\/+$/, '')).toLowerCase() : null;
};
const seen = new Set(st.retrieved.map(norm).filter(Boolean));
const call = st.final_content.find(b => b.type === 'tool_use' && b.name === 'submit_posts');
if (!call) return [{ json: { ok: false, ctx: st.ctx, usage: st.usage,
  error: 'Help Wanted scan finished without submitting posts (stop reason: ' + st.stop_reason + ')' } }];
const r = typeof call.input === 'string' ? JSON.parse(call.input) : call.input;
const all = r.posts || [];
r.posts = all.filter(p => seen.has(norm(p.url))).slice(0, 6);
return [{ json: { ok: true, result: r, dropped: all.length - r.posts.length, ctx: st.ctx, usage: st.usage } }];
""".strip()

HW_MESSAGES_JS = r"""
const rows = $input.all().map(i => i.json).filter(r => r.post_id);
const dropped = $('Check the posts').first().json.dropped || 0;
const tail = dropped ? ' (' + dropped + ' unconfirmed post(s) were dropped.)' : '';
if (!rows.length) return [{ json: { kind: 'header', text: '🙋 Weekly Help Wanted scan: no new posts this week.' + tail } }];
return [{ json: { kind: 'header', text: rows[0].header + tail } },
        ...rows.map(r => ({ json: { kind: 'card', text: r.card, post_id: r.post_id } }))];
""".strip()

helpwanted = workflow("SCI – Sales: Weekly Help Wanted Scan", [
    node("Run now (manual)", "n8n-nodes-base.manualTrigger", 1, {}, [0, -100]),
    node("Thursdays 9:40 AM ET", "n8n-nodes-base.scheduleTrigger", 1.2,
         {"rule": {"interval": [{"field": "cronExpression", "expression": "40 9 * * 4"}]}}, [0, 100]),
    pg("Safety check (pause + budget)", "select ok, reason from sci.guard_check('sales', 0.60)", None, [240, 0], "sales"),
    if_node("OK to run?", "={{ $json.ok }}", "true", "", [480, 0]),
    pg("Start scan", "select sci.sales_start_helpwanted($1) as ctx", "={{ [ String($execution.id) ] }}", [720, 0], "sales"),
    node("Build Claude request", "n8n-nodes-base.code", 2, {"jsCode": BUILD_HW_JS}, [960, 0]),
    node("Prepare Claude call", "n8n-nodes-base.code", 2, {"jsCode": "return $input.all();"}, [1200, 0]),
    {**CLAUDE_CALL, "position": [1440, 0]},
    node("Collect results", "n8n-nodes-base.code", 2, {"jsCode": AFTER_CALL_JS}, [1680, 0]),
    if_node("Claude paused? Continue", "={{ $json.again }}", "true", "", [1920, 0]),
    node("Check the posts", "n8n-nodes-base.code", 2, {"jsCode": CHECK_POSTS_JS}, [2160, 100]),
    if_node("Got a result?", "={{ $json.ok }}", "true", "", [2400, 100]),
    {**pg("Save new posts", "select * from sci.sales_save_helpwanted($1::uuid, $2::jsonb, $3::jsonb)",
          "={{ [ $json.ctx.run_id, JSON.stringify($json.result), JSON.stringify($json.usage) ] }}", [2640, 0], "sales"),
     "alwaysOutputData": True},
    node("Prepare messages", "n8n-nodes-base.code", 2, {"jsCode": HW_MESSAGES_JS}, [2880, 0]),
    if_node("Post card?", "={{ $json.kind }}", "equals", "card", [3120, 0], typ="string"),
    tg_send("Send summary", OWNER_CHAT_ID, "={{ $json.text }}", [3360, -100], extra_fields={"disable_web_page_preview": True}),
    tg_send("Send post card", OWNER_CHAT_ID, "={{ $json.text }}", [3360, 100], extra_fields={"disable_web_page_preview": True}, reply_markup={
        "replyMarkup": "inlineKeyboard",
        "inlineKeyboard": {"rows": [{"row": {"buttons": [
            {"text": "👍 I replied", "additionalFields": {"callback_data": "={{ 'hw:' + $json.post_id + ':replied' }}"}},
            {"text": "⏭ Skip", "additionalFields": {"callback_data": "={{ 'hw:' + $json.post_id + ':skip' }}"}},
        ]}}]}}),
    pg("Record failure", "update sci.agent_runs set status = 'failed', error = left($2, 2000), finished_at = now() where id = $1::uuid",
       "={{ [ $json.ctx.run_id, $json.error ] }}", [2640, 200], "sales"),
    tg_send("Tell Brett it failed", OWNER_CHAT_ID, "={{ '⚠️ Help Wanted scan failed: ' + $('Check the posts').item.json.error }}", [2880, 200]),
], link(("Run now (manual)", "Safety check (pause + budget)"),
        ("Thursdays 9:40 AM ET", "Safety check (pause + budget)"),
        ("Safety check (pause + budget)", "OK to run?"),
        ("OK to run?", "Start scan"),
        ("Start scan", "Build Claude request"),
        ("Build Claude request", "Prepare Claude call"),
        ("Prepare Claude call", "Call Claude"),
        ("Call Claude", "Collect results"),
        ("Collect results", "Claude paused? Continue"),
        ("Claude paused? Continue", "Prepare Claude call", 0),
        ("Claude paused? Continue", "Check the posts", 1),
        ("Check the posts", "Got a result?"),
        ("Got a result?", "Save new posts", 0),
        ("Got a result?", "Record failure", 1),
        ("Save new posts", "Prepare messages"),
        ("Prepare messages", "Post card?"),
        ("Post card?", "Send post card", 0),
        ("Post card?", "Send summary", 1),
        ("Record failure", "Tell Brett it failed")))
helpwanted["settings"]["timezone"] = "America/New_York"

if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    for fname, wf in [("01_error_alerts.json", error_alerts), ("02_telegram_bot.json", telegram_bot),
                      ("03_test_approval_card.json", test_card),
                      ("04_sales_research.json", research),
                      ("05_weekly_discovery.json", discovery),
                      ("06_outreach_drafts.json", drafts),
                      ("07_help_wanted_scan.json", helpwanted)]:
        (OUT / fname).write_text(json.dumps(wf, indent=2, ensure_ascii=False))
        print("wrote", OUT / fname)
