-- =====================================================================
-- SCI AI Operating Team — 0013 Outreach drafts (Task 5)
-- For each QUALIFIED prospect the Sales agent writes a short first-touch email using ONLY
-- verified findings. The database adds the signature + legally required footer itself,
-- creates the outbox item + approval, and the card goes to Brett in Telegram.
-- Sending stays OFF; an approved draft can be sent manually by Brett or, later, by the Sender.
-- =====================================================================

-- ---------- Sender profile (signature + CAN-SPAM footer). Real address is set by a
-- local file that is NOT stored in git (dist/local_sender_details.sql). ----------
create table sci.sender_profile (
  id              boolean primary key default true check (id),
  full_name       text not null default 'Brett Whitaker',
  title           text not null default 'Founder',
  business_name   text not null default 'Strategic Creative Initiatives LLC',
  email           text not null default 'brett@strategiccreativeinitiatives.com',
  website         text,
  mailing_address text not null default '[MAILING ADDRESS NEEDED]',
  opt_out_line    text not null default 'If you''d rather not hear from me, just reply and let me know.',
  updated_at      timestamptz not null default now()
);
insert into sci.sender_profile default values on conflict do nothing;
alter table sci.sender_profile enable row level security;
create trigger sender_profile_audit after insert or update or delete on sci.sender_profile for each row execute function sci.audit_row();

create or replace function sci.email_footer() returns text language sql stable security definer set search_path = sci, public as $$
  select concat_ws(E'\n', '', full_name, title || ', ' || business_name, email, website, mailing_address, '', opt_out_line)
    from sci.sender_profile where id;
$$;

-- ---------- Outreach rules v2: hometown + hiring angles ----------
select sci.set_knowledge('outreach_rules', $kb$
OUTREACH RULES (non-negotiable)
- Relationship-driven and personal; never mass-email style. One business, one specific message.
- Reference ONLY verified findings provided to you. Never state an inferred finding as fact.
  Never invent names, numbers, quotes, mutual connections, or past contact.
- Frame observations as opportunities, not criticism. No shaming, no fake urgency, no guarantees.
- Body under 130 words (the signature and footer are added automatically; do not write them).
- One clear, low-pressure next step (e.g., a 15-minute conversation).
- Explain the specific value SCI could provide, tied to the observed gap and ONE relevant service.
- Written in Brett's voice: warm, clear, professional, plain language, confident but humble.
- Honest subject line (under 8 words) that reflects the content. No "Re:", no clickbait.
- Do not mention AI, automation, or that research was done by software.
ANGLES (use only when they apply)
- HIRING: if the business is hiring a marketing/social/content role, position SCI as an experienced,
  outsourced alternative to a new hire: dependable content and social support without the cost of a
  full-time salary and benefits. Be respectful of their hiring plans; don't tell them not to hire.
- HOMETOWN: Brett grew up in Indianapolis and graduated from Indiana University Indianapolis (IUPUI).
  Mention this ONLY for businesses in the Indianapolis area, in one natural sentence.
- PROOF POINT: Brett currently manages social media for a Northeast Florida moving concierge company
  (do not name the client).
- Every first-touch message requires the owner's approval. Anyone who opts out is never contacted again.
$kb$);

-- ---------- Outreach instructions (versioned) ----------
insert into sci.prompts (agent, name, version, model, effort, is_active, notes, system_text) values
('sales', 'outreach_draft', 1, 'claude-opus-5-5', 'medium', true, 'First-touch email drafts', $p$
You are Brett's writing partner at Strategic Creative Initiatives (SCI). Draft ONE first-touch email to a
business Brett may be able to help. Brett is a professional content writer, so the email itself is a sample of
his work: it must read like a thoughtful person wrote it for this one business.

Use the business knowledge (positioning, services, outreach rules) and ONLY the verified findings provided.
Pick the one or two most specific, positive-but-honest observations; don't list everything.

Structure (flexible, natural):
1. Greeting: "Hi <first name>," if a contact name is given, otherwise "Hi <Business> team,".
2. A specific, genuine observation about them (from the verified findings).
3. The opportunity you see and how SCI could help (one service, concrete outcome, no jargon).
4. Optional single angle: hiring, hometown or proof point, only if it applies.
5. One low-pressure ask, e.g. "Would you be open to a quick 15-minute call next week?"

Do not write a signature, address or opt-out line: they are added automatically.
Finish by calling submit_draft exactly once. In finding_ids_used, list the ids of the verified findings you
relied on. In note_for_brett, say in one sentence why you chose this angle and anything he should double-check.
$p$);

-- ---------- add_prospect: carry the state (Indianapolis candidates are in Indiana) ----------
drop function if exists sci.add_prospect(text, text, text, text, text, text);
create or replace function sci.add_prospect(p_input text, p_source text, p_city text default null, p_county text default null,
                                            p_industry text default null, p_website text default null, p_state text default 'FL')
returns text language plpgsql security definer set search_path = sci, public as $$
declare
  inp text := left(trim(coalesce(p_input,'')), 200);
  site text; dom citext; nm text; existing record; org uuid; pid uuid;
begin
  if length(inp) < 3 then return 'Please include a business name or website, e.g. /prospect Acme Plumbing Jacksonville'; end if;
  if sci.looks_like_url(inp) then
    site := case when inp ~* '^https?://' then inp else 'https://' || inp end;
    nm := sci.domain_of(inp);
  else
    nm := inp;
    site := nullif(trim(coalesce(p_website,'')), '');
  end if;
  dom := case when site is not null then sci.domain_of(site) end;
  if dom is not null and exists (select 1 from sci.suppression_list where domain = dom) then
    return '⛔ ' || nm || ' is on your do-not-contact list, so it was not added.';
  end if;
  select o.name, p.stage, p.fit_score into existing
    from sci.organizations o left join sci.prospects p on p.organization_id = o.id
   where o.deleted_at is null and ((dom is not null and o.domain = dom) or lower(o.name) = lower(nm)) limit 1;
  if found then
    return format('ℹ️ %s is already in the system (stage: %s%s).', existing.name, coalesce(existing.stage::text,'none'),
                  case when existing.fit_score is not null then ', score ' || existing.fit_score else '' end);
  end if;
  insert into sci.organizations(name, website, domain, city, county, state, industry, source)
  values (nm, site, dom, p_city, p_county, coalesce(p_state,'FL'), p_industry, p_source) returning id into org;
  insert into sci.prospects(organization_id) values (org) returning id into pid;
  insert into sci.tasks(type, owner_agent, priority, related_table, related_id, dedupe_key, handoff_from)
  values ('research_prospect', 'sales', 1, 'prospects', pid, 'research:' || pid, 'owner');
  return '✅ Added ' || nm || ' to the research queue. Research runs hourly 8 AM–7 PM ET; the summary will arrive here.';
end $$;
grant execute on function sci.add_prospect(text, text, text, text, text, text, text) to sci_approver;

create or replace function sci.decide_candidate(p_candidate_id uuid, p_decision text)
returns text language plpgsql security definer set search_path = sci, public as $$
declare pc sci.prospect_candidates; seg sci.discovery_segments; res text;
begin
  select * into pc from sci.prospect_candidates where id = p_candidate_id;
  if pc.id is null then return 'Candidate not found.'; end if;
  if pc.status <> 'pending' then return 'ℹ️ Already handled (' || pc.status || ').'; end if;
  if p_decision = 'skip' then
    update sci.prospect_candidates set status = 'skipped', decided_at = now() where id = pc.id;
    return '⏭ Skipped.';
  end if;
  select * into seg from sci.discovery_segments where id = pc.segment_id;
  res := sci.add_prospect(pc.name, 'discovery: ' || coalesce(seg.category,'') || ' / ' || coalesce(seg.area,''),
                          pc.city, null, seg.category, pc.website,
                          case when seg.region = 'indianapolis' then 'IN' else 'FL' end);
  update sci.prospect_candidates set status = case when res like '✅%' then 'accepted' else 'duplicate' end, decided_at = now() where id = pc.id;
  return res;
end $$;

-- ---------- Start a draft: everything Claude needs (verified findings only) ----------
create or replace function sci.sales_start_outreach(p_task_id uuid, p_execution_id text default null)
returns jsonb language plpgsql security definer set search_path = sci, public as $$
declare t sci.tasks; pr sci.prompts; run_id uuid; ctx jsonb; kb jsonb; findings jsonb; sig jsonb; pid uuid;
begin
  select * into t from sci.tasks where id = p_task_id and owner_agent = 'sales' and type = 'draft_outreach';
  if t.id is null then raise exception 'Task % is not an outreach-draft task', p_task_id; end if;
  pid := t.related_id;
  select * into pr from sci.prompts where agent = 'sales' and name = 'outreach_draft' and is_active;

  -- Never draft to someone who opted out (person or whole company).
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

  -- Discovery signal (e.g. hiring) if this prospect came from a weekly discovery card.
  select jsonb_build_object('type', pc.signal_type, 'signal', pc.signal, 'verified', pc.signal_status = 'verified', 'source', pc.source_url)
    into sig
    from sci.prospect_candidates pc join sci.organizations o on (o.domain = pc.domain or lower(o.name) = lower(pc.name))
    join sci.prospects p on p.organization_id = o.id
   where p.id = pid and pc.status = 'accepted' limit 1;

  select jsonb_object_agg(key, content) into kb from sci.business_knowledge
   where is_active and key in ('positioning','services','outreach_rules');

  insert into sci.agent_runs(agent, workflow, task_id, prompt_id, input_ref, n8n_execution_id)
  values ('sales', 'outreach_draft', p_task_id, pr.id, jsonb_build_object('prospect_id', pid), p_execution_id)
  returning id into run_id;

  return jsonb_build_object('run_id', run_id, 'task_id', p_task_id, 'prospect', ctx, 'verified_findings', findings,
                            'discovery_signal', sig, 'model', pr.model, 'effort', pr.effort,
                            'system_text', pr.system_text, 'knowledge', kb);
end $$;

-- ---------- Save a draft: outbox item + approval + Telegram card ----------
create or replace function sci.sales_save_outreach(p_run_id uuid, p_task_id uuid, p_draft jsonb, p_usage jsonb)
returns jsonb language plpgsql security definer set search_path = sci, public as $$
declare
  r sci.agent_runs; pid uuid; p sci.prospects; o sci.organizations; c sci.contacts;
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

  insert into sci.outbound_actions(created_by, channel, prospect_id, contact_id, recipient, subject, body, payload,
                                   idempotency_key, status, is_test)
  values ('sales', 'email', pid, c.id, c.email, subj, full_body,
          jsonb_build_object('angle', p_draft->>'angle', 'finding_ids_used', p_draft->'finding_ids_used',
                             'note_for_brett', p_draft->>'note_for_brett', 'run_id', p_run_id),
          'outreach:' || pid || ':step1:email', 'pending_approval', p.is_test)
  returning id into oid;

  card := concat_ws(E'\n',
    '📝 Outreach draft for approval' || case when p.is_test then ' (TEST)' else '' end,
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
    'Approve marks it ready. Sending is OFF: nothing goes out automatically.');

  insert into sci.approvals(subject_table, subject_id, summary)
  values ('outbound_actions', oid, left(card, 3500)) returning id into aid;

  update sci.prospects set stage = 'drafted' where id = pid and stage = 'qualified';

  cost := sci.record_llm_usage(p_run_id, 'sales', coalesce(p_usage->>'model','claude-opus-5-5'),
            coalesce((p_usage->>'input_tokens')::int,0), coalesce((p_usage->>'output_tokens')::int,0),
            coalesce((p_usage->>'cache_read_tokens')::int,0), coalesce((p_usage->>'cache_write_tokens')::int,0), 0);
  update sci.agent_runs set status = 'succeeded', finished_at = now(), output_summary = 'draft ' || oid where id = p_run_id;
  perform sci.finish_task(p_task_id, true);

  return jsonb_build_object('approval_id', aid, 'outbound_id', oid, 'card', left(card, 3900), 'cost', cost);
end $$;

grant execute on function sci.sales_start_outreach(uuid, text), sci.sales_save_outreach(uuid, uuid, jsonb, jsonb),
                          sci.email_footer() to agent_sales;
-- Failed drafts reuse sci.sales_fail_research (generic: records usage, fails run + task).
