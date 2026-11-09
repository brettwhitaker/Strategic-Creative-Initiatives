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
CRED_IDS = {"SCI DB – Approver": "credAppr", "SCI DB – Sales": "credSales", "SCI – Telegram Bot": "credTg", "SCI – Claude (Sales)": "credClaude", "SCI DB – Social": "credSocial"}

def fix_creds(n):
    for v in n.get("credentials", {}).values():
        v["id"] = CRED_IDS[v["name"]]

def telegram_to_set(n):
    p = n["parameters"]
    fields = {k: p[k] for k in ("chatId", "text", "queryId", "messageId") if k in p}
    if "additionalFields" in p and "text" in p["additionalFields"]:
        fields["answerText"] = p["additionalFields"]["text"]
    k = 0
    for r in p.get("inlineKeyboard", {}).get("rows", []):
        for b in r["row"]["buttons"]:
            fields[f"button{k}"] = b["additionalFields"]["callback_data"]; k += 1
    n.update(type="n8n-nodes-base.set", typeVersion=3.4, parameters={
        "assignments": {"assignments": [
            {"id": k, "name": k, "value": v if str(v).startswith("=") else str(v), "type": "string"}
            for k, v in fields.items()]},
        "options": {}})
    n.pop("credentials", None)


MOCK_CLAUDE = r"""
const st = $json.state;
if (!st.request || !st.request.model || !Array.isArray(st.request.tools)) throw new Error('bad request built');
if (st.request.tools.some(t => t.name === 'submit_posts')) {
  const um = st.request.messages[0].content;
  if (!um.includes('MODE: PLAN') || !um.includes('<slots>')) throw new Error('plan request malformed');
  if (!st.request.system[1].text.includes('CLIENT KNOWLEDGE')) throw new Error('client knowledge missing');
  const post = (i, pillar) => ({ slot_index: i, pillar, hook: 'Hook ' + i, caption: 'Caption for slot ' + i + ' with enough words to count as a real post.',
    hashtags: '#test', creative_brief: 'A photo', note_for_brett: 'Note ' + i });
  const posts = [post(0, 'Feeling at home'), post(1, 'Explaining'), post(2, 'Tips')];
  posts[2].caption = 'A post that slips in a price of $500 and should be flagged for review by Brett.';
  return [{ json: { stop_reason: 'tool_use', usage: { input_tokens: 9000, output_tokens: 2500 },
    content: [{ type: 'tool_use', id: 't5', name: 'submit_posts', input: { posts } }] } }];
}
if (st.request.tools.some(t => t.name === 'submit_draft')) {
  const um = st.request.messages[0].content;
  if (!um.includes('<verified_findings>')) throw new Error('findings missing');
  return [{ json: { stop_reason: 'tool_use', usage: { input_tokens: 7000, output_tokens: 900 },
    content: [{ type: 'tool_use', id: 't3', name: 'submit_draft', input: {
      subject: 'A quick idea for your homepage',
      body: 'Hi there,\n\nYour homepage welcomes visitors warmly, and a clearer headline about what makes your care different could turn more of them into patients. I write website copy for local healthcare practices. Would you be open to a quick 15-minute call next week?',
      angle: 'content', finding_ids_used: ['not-a-real-id'], note_for_brett: 'Homepage message is the clearest gap.' } }] } }];
}
if (st.request.tools.some(t => t.name === 'submit_candidates')) {
  if (!st.request.messages[0].content.includes('Category:')) throw new Error('segment missing from request');
  return [{ json: { stop_reason: 'tool_use', usage: { input_tokens: 30000, output_tokens: 2000, server_tool_use: { web_search_requests: 5 } },
    content: [
      { type: 'web_search_tool_result', tool_use_id: 'w1', content: [{ type: 'web_search_result', url: 'https://jobs.test/marketing-coordinator', title: 'Jobs' }] },
      { type: 'tool_use', id: 't2', name: 'submit_candidates', input: { candidates: [
        { name: 'Ancient City Accounting', website: 'https://ancientcityacct.test', city: 'St. Augustine', signal_type: 'hiring',
          signal: 'Hiring a marketing coordinator', signal_status: 'verified', source_url: 'https://jobs.test/marketing-coordinator', evidence_quote: 'Marketing Coordinator' },
        { name: 'Made Up Signal LLC', website: '', city: 'Jacksonville', signal_type: 'growth',
          signal: 'Opened a second office', signal_status: 'verified', source_url: 'https://never-retrieved.test/news', evidence_quote: 'second office' },
        { name: 'Riverbend Plumbing & Drain (TEST)', website: 'https://riverbendplumbing.test', city: '', signal_type: 'other',
          signal: 'already known', signal_status: 'inferred', source_url: '', evidence_quote: '' } ] } } ] } }];
}
if (st.iter === 0) return [{ json: { stop_reason: 'pause_turn',
  usage: { input_tokens: 20000, output_tokens: 500, cache_read_input_tokens: 3000, server_tool_use: { web_search_requests: 2 } },
  content: [
    { type: 'server_tool_use', id: 's1', name: 'web_fetch', input: { url: 'https://www.flemingpt.test/' } },
    { type: 'web_fetch_tool_result', tool_use_id: 's1', content: { type: 'web_fetch_result', url: 'https://www.flemingpt.test/',
      content: { type: 'document', source: { type: 'text', data: 'Welcome to Fleming PT. Contact info@flemingpt.test' } } } } ] } }];
if (st.request.messages.length !== 2) throw new Error('pause_turn continuation did not append the assistant turn');
return [{ json: { stop_reason: 'tool_use',
  usage: { input_tokens: 25000, output_tokens: 2500, server_tool_use: { web_search_requests: 1 } },
  content: [ { type: 'text', text: 'Submitting.' }, { type: 'tool_use', id: 't1', name: 'submit_research', input: {
    business_summary: 'Physical therapy clinic in Fleming Island.', official_name: 'Official Name Co', official_website: 'https://www.official-site.test/', industry: 'Healthcare', size_estimate: 'unknown',
    findings: [
      { category: 'website_copy', statement: 'Homepage headline is generic', status: 'verified',
        source_url: 'https://flemingpt.test', evidence_quote: 'Welcome to Fleming PT' },
      { category: 'company_facts', statement: 'Has 40 employees', status: 'verified',
        source_url: 'https://made-up-source.test/about', evidence_quote: '40 employees' },
      { category: 'social_media', statement: 'Instagram activity', status: 'unknown', source_url: '', evidence_quote: '' } ],
    score_breakdown: { gap: 30, trust_driven: 8, ability_to_invest: 10, growth: 4, geography: 10, reachability: 4 },
    top_opportunity: 'Clearer homepage messaging and a patient-education blog.',
    recommended_service: 'Website copy package', secondary_service: '', disqualify_reason: '',
    public_contact: { name: '', role: '', email: 'info@flemingpt.test', source_url: 'https://www.flemingpt.test/' },
    open_questions: [] } } ] } }];
"""

def variant(fname, wf_id, fake_updates=None):
    wf = json.loads((ROOT / fname).read_text())
    wf["id"] = wf_id
    wf["name"] = "TEST " + wf["name"]
    for n in wf["nodes"]:
        fix_creds(n)
        if n["name"] == "Call Claude":
            n.update(type="n8n-nodes-base.code", typeVersion=2, parameters={"jsCode": MOCK_CLAUDE})
            n.pop("credentials", None)
        elif n["type"] == "n8n-nodes-base.telegram":
            telegram_to_set(n)
        elif n["type"] == "n8n-nodes-base.telegramTrigger":
            n.update(type="n8n-nodes-base.code", typeVersion=2, parameters={
                "jsCode": "return " + json.dumps([{"json": u} for u in fake_updates]) + ";"})
            n.pop("credentials", None)
            wf["nodes"].append({"id": "start", "name": "Start", "type": "n8n-nodes-base.manualTrigger",
                                "typeVersion": 1, "position": [-240, 0], "parameters": {}})
            wf["connections"]["Start"] = {"main": [[{"node": n["name"], "type": "main", "index": 0}]]}
    if fname.startswith("04"):
        wf["nodes"] = [n for n in wf["nodes"] if n["type"] != "n8n-nodes-base.scheduleTrigger"]
        wf["connections"].pop("Hourly 8 AM–7 PM ET", None)
    if fname.startswith("08"):
        wf["nodes"] = [n for n in wf["nodes"] if n["type"] != "n8n-nodes-base.scheduleTrigger"]
        wf["connections"].pop("Hourly 8 AM–7 PM ET", None)
    if fname.startswith("06"):
        wf["nodes"] = [n for n in wf["nodes"] if n["type"] != "n8n-nodes-base.scheduleTrigger"]
        wf["connections"].pop("Hourly 8 AM–7 PM ET", None)
    if fname.startswith("05"):
        wf["nodes"] = [n for n in wf["nodes"] if n["type"] != "n8n-nodes-base.scheduleTrigger"]
        wf["connections"].pop("Mon & Wed 9:40 AM ET", None)
    (out / fname).write_text(json.dumps(wf, indent=2, ensure_ascii=False))

OWNER, STRANGER = 111111, 999999
def msg(text, who): return {"update_id": 1, "message": {"message_id": 5, "from": {"id": who}, "chat": {"id": who}, "text": text}}
updates = [
    msg("/status", OWNER),
    msg("/pause", STRANGER),                                   # must be ignored
    msg("hello there", OWNER),                                 # not a command: ignored
    msg("/prospect Bartram Trail Dental", OWNER),
    msg("/prospect Sneaky Biz", STRANGER),                     # must be ignored
    {"update_id": 4, "message": {"message_id": 6, "from": {"id": OWNER}, "chat": {"id": OWNER}, "text": "Warmer please",
                                 "reply_to_message": {"message_id": 3, "text": "📝 Outreach draft ... Ref D-deadbeef"}}},
    {"update_id": 2, "callback_query": {"id": "cbq1", "from": {"id": OWNER}, "data": f"ap:{approval_id}:approved",
                                         "message": {"message_id": 77, "chat": {"id": OWNER}, "text": "📝 Approval needed (TEST)"}}},
    {"update_id": 3, "callback_query": {"id": "cbq2", "from": {"id": STRANGER}, "data": f"ap:{approval_id}:rejected",
                                         "message": {"message_id": 78, "chat": {"id": STRANGER}, "text": "x"}}},
]
variant("03_test_approval_card.json", "testCard")
variant("02_telegram_bot.json", "testBot", updates)
variant("01_error_alerts.json", "testErr")
variant("04_sales_research.json", "testResearch")
variant("05_weekly_discovery.json", "testDiscovery")
variant("06_outreach_drafts.json", "testDrafts")
variant("08_social_content_planner.json", "testSocial")
print("ok")
