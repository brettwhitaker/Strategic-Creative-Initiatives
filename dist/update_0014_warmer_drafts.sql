-- =====================================================================
-- SCI AI Operating Team — 0014 Warmer drafts + Redraft with notes (owner feedback on first real draft)
-- * Outreach instructions v2: warmth first, one compliment, gentle opportunity, soft close with an easy out
-- * ✏️ Redraft button, or reply to a draft card with notes -> new draft that follows the notes
-- * A prospect can have several drafts over time, but only ONE active first-touch at once
-- =====================================================================

update sci.prompts set is_active = false where agent = 'sales' and name = 'outreach_draft' and is_active;
insert into sci.prompts (agent, name, version, model, effort, is_active, notes, system_text) values
('sales', 'outreach_draft', 2, 'claude-opus-5-5', 'medium', true,
 'Owner feedback: too direct/fact-heavy; needs warmth that builds trust', $p$
You are Brett's writing partner at Strategic Creative Initiatives (SCI). Draft ONE first-touch email to a business
Brett may be able to help. Brett is a professional writer, so the email is a sample of his work. It should read like
a warm, thoughtful local business owner writing to someone he respects: human first, helpful second, selling last.

HOW IT SHOULD FEEL
1. Open as a person. One friendly sentence introducing Brett and why he's reaching out to THEM (for example, he's a
   writer who works with local businesses and came across their firm). Never open with a fact about their website.
2. One genuine, specific compliment, drawn from the verified findings: something their clients say, or something
   they clearly do well. Let them feel seen and appreciated.
3. The opportunity, gently and as a possibility, never as a flaw: "It made me wonder whether..." or "I'd love to
   help more people find...". Mention at most ONE detail about a gap, and do not stack facts, dates or years
   (avoid things like "since January 2014" or "since 1982"); that reads like an audit.
4. How SCI could help, in one or two sentences, in terms of what matters to them (their clients, their time,
   their reputation), not Brett's process.
5. A soft close with an easy out, e.g. "If it would be helpful, I'd be glad to share a few ideas over a quick
   15-minute call, and if the timing isn't right, no worries at all."

STYLE: conversational, first person, short paragraphs of 1-3 sentences, plain words, no buzzwords, no hype,
at most one exclamation point. 90-120 words.

Use the business knowledge (positioning, services, outreach rules) and ONLY the verified findings provided.
Angles (hiring, hometown, proof point) only when they apply, in one natural sentence.
If OWNER NOTES are provided, follow them; they override these guidelines. If a PREVIOUS DRAFT is provided,
improve on it rather than starting from scratch, unless the notes say otherwise.
Do not write a signature, address or opt-out line: they are added automatically.
Finish by calling submit_draft exactly once. In finding_ids_used list the ids of the verified findings you
relied on. In note_for_brett, one sentence: why this angle, and anything he should double-check.
$p$);

-- ---------- One ACTIVE first-touch per prospect; history of rejected drafts is kept ----------
create unique index if not exists outbound_one_active_first_touch on sci.outbound_actions(prospect_id)
  where idempotency_key like 'outreach:%:step1:%' and status in ('draft','pending_approval','approved','sending','sent');

-- ---------- Ask for a redraft (button or reply-with-notes) ----------
create or replace function sci.request_redraft(p_approval_id uuid, p_from text, p_notes text default null)
returns text language plpgsql security definer set search_path = sci, public as $$
declare a sci.approvals; o sci.outbound_actions; nm text;
begin
  select * into a from sci.approvals where id = p_approval_id;
  if a.id is null or a.subject_table <> 'outbound_actions' then return 'Draft not found.'; end if;
  select * into o from sci.outbound_actions where id = a.subject_id;
  if o.prospect_id is null or o.idempotency_key not like 'outreach:%' then return 'Only outreach drafts can be redrafted.'; end if;
  if o.status in ('approved','sending','sent') then return 'ℹ️ This draft is already approved; reject is no longer possible from here.'; end if;

  if a.decision = 'pending' then
    perform sci.decide_approval(a.id, 'rejected', p_from, coalesce(p_notes, 'redraft requested'));
  end if;

  insert into sci.tasks(type, owner_agent, priority, related_table, related_id, payload, dedupe_key, handoff_from)
  values ('draft_outreach', 'sales', 1, 'prospects', o.prospect_id,
          jsonb_build_object('owner_notes', nullif(trim(coalesce(p_notes,'')), ''), 'previous_outbound_id', o.id),
          'draft_outreach:' || o.prospect_id || ':redraft', 'owner')
  on conflict do nothing;
  if not found then return 'ℹ️ A redraft for this business is already in the queue.'; end if;

  select org.name into nm from sci.prospects p join sci.organizations org on org.id = p.organization_id where p.id = o.prospect_id;
  return '✏️ Got it. A new draft for ' || nm || case when p_notes is not null and trim(p_notes) <> '' then ', following your notes,' else '' end
         || ' will arrive within the hour (8 AM–7 PM ET).';
end $$;

-- Reply-with-notes finds the card by the short reference printed on it ("Ref D-1a2b3c4d").
create or replace function sci.approval_by_ref(p_ref text) returns uuid language sql stable security definer set search_path = sci, public as $$
  select id from sci.approvals where id::text like lower(p_ref) || '%' and length(p_ref) >= 8 order by created_at desc limit 1;
$$;

-- ---------- Telegram: add redraft kinds ----------
create or replace function sci.handle_telegram(p_kind text, p_from text, p_target uuid default null, p_decision text default null, p_arg text default null)
returns text language plpgsql set search_path = sci, public as $$
declare allowed text[]; res text; aid uuid;
begin
  select owner_telegram_chat_ids into allowed from sci.system_controls where id;
  if p_from is null or not (p_from = any(allowed)) then return null; end if;

  if p_kind = 'decision' then
    if p_decision not in ('approved','rejected') then return 'Unknown decision.'; end if;
    res := sci.decide_approval(p_target, p_decision::sci.approval_decision, p_from);
    return case res
      when 'approved' then '✅ Approved. (Sending is OFF, so nothing goes out until you enable it.)'
      when 'rejected' then '❌ Rejected. Nothing will be sent. (Reply to the card with notes if you want a new version.)'
      else 'ℹ️ This request was already decided.' end;
  elsif p_kind = 'redraft' then
    return sci.request_redraft(p_target, p_from, null);
  elsif p_kind = 'redraft_note' then
    aid := sci.approval_by_ref(p_decision);
    if aid is null then return 'I couldn''t match that reply to a draft. Reply directly to the draft card.'; end if;
    return sci.request_redraft(aid, p_from, left(p_arg, 1500));
  elsif p_kind = 'candidate' then
    if p_decision not in ('research','skip') then return 'Unknown choice.'; end if;
    return sci.decide_candidate(p_target, p_decision);
  elsif p_kind = 'prospect' then
    return sci.add_prospect(p_arg, 'telegram: added by owner');
  elsif p_kind = 'pause' then
    update sci.system_controls set global_pause = true, updated_by = 'telegram:' || p_from where id;
    return '⏸ All agents paused. Nothing will run or send. Send /resume to restart.';
  elsif p_kind = 'resume' then
    update sci.system_controls set global_pause = false, updated_by = 'telegram:' || p_from where id;
    return '▶️ Resumed. Agents will pick up work on their next scheduled run.';
  elsif p_kind = 'status' then
    return sci.status_summary();
  elsif p_kind in ('help','start') then
    return concat_ws(E'\n',
      'SCI Operations bot',
      '/status: what''s happening, pending approvals, AI spend',
      '/prospect <name or website>: add a business to research',
      '/pause: stop all agents immediately',
      '/resume: start them again',
      '',
      'Draft cards: ✅ Approve, ❌ Reject, ✏️ Redraft, or reply to a card with your notes for a rewrite.');
  end if;
  return null;
end $$;
grant execute on function sci.handle_telegram(text, text, uuid, text, text) to sci_approver;
grant execute on function sci.request_redraft(uuid, text, text), sci.approval_by_ref(text) to sci_approver;

-- ---------- Outreach start/save v2: notes + previous draft; numbered drafts; card reference ----------
create or replace function sci.sales_start_outreach(p_task_id uuid, p_execution_id text default null)
returns jsonb language plpgsql security definer set search_path = sci, public as $$
declare t sci.tasks; pr sci.prompts; run_id uuid; ctx jsonb; kb jsonb; findings jsonb; sig jsonb; pid uuid; prev jsonb;
begin
  select * into t from sci.tasks where id = p_task_id and owner_agent = 'sales' and type = 'draft_outreach';
  if t.id is null then raise exception 'Task % is not an outreach-draft task', p_task_id; end if;
  pid := t.related_id;
  select * into pr from sci.prompts where agent = 'sales' and name = 'outreach_draft' and is_active;

  if exists (select 1 from sci.prospects p join sci.organizations o on o.id = p.organization_id
              left join sci.contacts c on c.id = p.primary_contact_id
             where p.id = pid and (sci.is_suppressed(c.email)
                   or exists (select 1 from sci.suppression_list s where s.domain = o.domain))) then
    update sci.tasks set status = 'cancelled', last_error = 'contact opted out / do-not-contact', locked_at = null where id = p_task_id;
    update sci.prospects set stage = 'do_not_contact' where id = pid;
    return jsonb_build_object('skip', true, 'reason',
      (select o.name from sci.prospects p join sci.organizations o on o.id = p.organization_id where p.id = pid)
      || ' is on the do-not-contact list, so no draft was written.');
  end if;
  if exists (select 1 from sci.outbound_actions where prospect_id = pid and idempotency_key like 'outreach:%:step1:%'
              and status in ('draft','pending_approval','approved','sending','sent')) then
    update sci.tasks set status = 'cancelled', last_error = 'an active first-touch draft already exists', locked_at = null where id = p_task_id;
    return jsonb_build_object('skip', true, 'reason',
      (select o.name from sci.prospects p join sci.organizations o on o.id = p.organization_id where p.id = pid)
      || ' already has a draft waiting or approved, so no second one was written.');
  end if;

  select jsonb_build_object(
           'prospect_id', p.id, 'business_name', o.name, 'website', o.website, 'city', o.city, 'state', o.state,
           'industry', o.industry, 'fit_score', p.fit_score, 'why_qualified', p.fit_rationale,
           'recommended_service', p.recommended_service, 'is_test', p.is_test,
           'region', case when o.state = 'IN' or o.city ~* 'indianapolis|carmel|fishers|noblesville' then 'indianapolis'
                          when o.county in ('Duval','St. Johns','Clay','Nassau','Baker') or o.city ~* 'jacksonville|ponte vedra|st\.? augustine|orange park|fleming island|middleburg|neptune beach|atlantic beach|fernandina' then 'northeast_florida'
                          else 'elsewhere' end,
           'contact', case when c.id is null then null else jsonb_build_object('name', c.full_name, 'role', c.role_title, 'has_email', c.email is not null) end)
    into ctx
    from sci.prospects p join sci.organizations o on o.id = p.organization_id
    left join sci.contacts c on c.id = p.primary_contact_id and c.deleted_at is null
   where p.id = pid;

  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'category', f.category, 'statement', f.statement,
                                               'quote', f.evidence_quote, 'source', f.source_url) order by f.created_at), '[]'::jsonb)
    into findings from sci.research_findings f where f.prospect_id = pid and f.status = 'verified';

  select jsonb_build_object('type', pc.signal_type, 'signal', pc.signal, 'verified', pc.signal_status = 'verified', 'source', pc.source_url)
    into sig
    from sci.prospect_candidates pc join sci.organizations o on (o.domain = pc.domain or lower(o.name) = lower(pc.name))
    join sci.prospects p on p.organization_id = o.id
   where p.id = pid and pc.status = 'accepted' limit 1;

  select jsonb_build_object('subject', ob.subject, 'body', split_part(ob.body, E'\n' || sci.email_footer(), 1))
    into prev from sci.outbound_actions ob where ob.id = nullif(t.payload->>'previous_outbound_id','')::uuid;

  select jsonb_object_agg(key, content) into kb from sci.business_knowledge
   where is_active and key in ('positioning','services','outreach_rules');

  insert into sci.agent_runs(agent, workflow, task_id, prompt_id, input_ref, n8n_execution_id)
  values ('sales', 'outreach_draft', p_task_id, pr.id, jsonb_build_object('prospect_id', pid), p_execution_id)
  returning id into run_id;

  return jsonb_build_object('run_id', run_id, 'task_id', p_task_id, 'prospect', ctx, 'verified_findings', findings,
                            'discovery_signal', sig, 'owner_notes', t.payload->>'owner_notes', 'previous_draft', prev,
                            'model', pr.model, 'effort', pr.effort, 'system_text', pr.system_text, 'knowledge', kb);
end $$;

create or replace function sci.sales_save_outreach(p_run_id uuid, p_task_id uuid, p_draft jsonb, p_usage jsonb)
returns jsonb language plpgsql security definer set search_path = sci, public as $$
declare
  r sci.agent_runs; pid uuid; p sci.prospects; o sci.organizations; c sci.contacts; n int;
  body text; full_body text; subj text; oid uuid; aid uuid; cost numeric; words int; card text; addr_missing boolean;
begin
  select * into r from sci.agent_runs where id = p_run_id and task_id = p_task_id and workflow = 'outreach_draft' and status = 'started';
  if r.id is null then raise exception 'Run % is not an open outreach run for task %', p_run_id, p_task_id; end if;
  pid := (r.input_ref->>'prospect_id')::uuid;
  select * into p from sci.prospects where id = pid;
  select * into o from sci.organizations where id = p.organization_id;
  select * into c from sci.contacts where id = p.primary_contact_id and deleted_at is null;

  subj := left(trim(coalesce(p_draft->>'subject','')), 120);
  body := trim(coalesce(p_draft->>'body',''));
  if subj = '' or length(body) < 40 then raise exception 'Draft is empty or too short'; end if;
  full_body := body || E'\n' || sci.email_footer();
  words := array_length(regexp_split_to_array(body, '\s+'), 1);
  select mailing_address like '[%' into addr_missing from sci.sender_profile where id;
  select count(*) + 1 into n from sci.outbound_actions where prospect_id = pid and idempotency_key like 'outreach:%:step1:%';

  insert into sci.outbound_actions(created_by, channel, prospect_id, contact_id, recipient, subject, body, payload,
                                   idempotency_key, status, is_test)
  values ('sales', 'email', pid, c.id, c.email, subj, full_body,
          jsonb_build_object('angle', p_draft->>'angle', 'finding_ids_used', p_draft->'finding_ids_used',
                             'note_for_brett', p_draft->>'note_for_brett', 'run_id', p_run_id, 'version', n),
          'outreach:' || pid || ':step1:email' || case when n > 1 then ':v' || n else '' end, 'pending_approval', p.is_test)
  returning id into oid;

  insert into sci.approvals(subject_table, subject_id, summary) values ('outbound_actions', oid, 'pending card') returning id into aid;

  card := concat_ws(E'\n',
    '📝 Outreach draft for approval' || case when n > 1 then ' (version ' || n || ')' else '' end || case when p.is_test then ' (TEST)' else '' end,
    '',
    'Business: ' || o.name || coalesce(' (' || o.city || ')', ''),
    'To: ' || coalesce(c.email, '(no public email found: send via their website contact form or LinkedIn)'),
    'Subject: ' || subj,
    '',
    full_body,
    '',
    '— — —',
    format('Why this angle: %s', coalesce(nullif(p_draft->>'note_for_brett',''), '-')),
    format('%s words · fit score %s', words, p.fit_score),
    case when addr_missing then '⚠️ Mailing address not set yet: run local_sender_details.sql before sending.' end,
    'Approve marks it ready (sending is OFF). To rewrite: tap ✏️ Redraft, or reply to this message with your notes.',
    'Ref D-' || left(aid::text, 8));
  update sci.approvals set summary = left(card, 3500) where id = aid;

  update sci.prospects set stage = 'drafted' where id = pid and stage in ('qualified','drafted');

  cost := sci.record_llm_usage(p_run_id, 'sales', coalesce(p_usage->>'model','claude-opus-5-5'),
            coalesce((p_usage->>'input_tokens')::int,0), coalesce((p_usage->>'output_tokens')::int,0),
            coalesce((p_usage->>'cache_read_tokens')::int,0), coalesce((p_usage->>'cache_write_tokens')::int,0), 0);
  update sci.agent_runs set status = 'succeeded', finished_at = now(), output_summary = 'draft ' || oid where id = p_run_id;
  perform sci.finish_task(p_task_id, true);

  return jsonb_build_object('approval_id', aid, 'outbound_id', oid, 'card', left(card, 3900), 'cost', cost);
end $$;

-- ---------- One-time: redraft the Simpson & Paull email with Brett's feedback ----------
select sci.request_redraft(
  (select a.id from sci.approvals a
     join sci.outbound_actions o on o.id = a.subject_id
     join sci.prospects p on p.id = o.prospect_id
     join sci.organizations org on org.id = p.organization_id
    where org.name = 'Simpson & Paull, P.L.' and a.decision = 'pending'
    order by a.created_at desc limit 1),
  '8995080526',
  'Too direct and fact-heavy. Lead with warmth and a genuine human introduction so it builds trust before offering services. One compliment, one gentle opportunity, no stacked dates or years, soft close.') as result;
