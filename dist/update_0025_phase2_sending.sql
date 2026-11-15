-- =====================================================================
-- SCI AI Operating Team — 0025 Phase 2: sending, follow-ups, reply alerts (owner-authorized design)
--  * The Sender sends ONE approved email per hourly run, Mon–Fri 9 AM–5 PM ET, max 8/day, from Brett's Gmail.
--    Nothing sends unless Brett turns sending_enabled ON himself.
--  * Follow-up #1 (+4 days) and #2 (+7 days) are drafted for approval, sent as replies in the same thread,
--    and cancelled the moment the prospect replies or opts out.
--  * Hourly inbox check: replies → instant Telegram alert; opt-out wording → do-not-contact automatically.
--  * /sent <business>: record an email Brett sent himself (starts follow-ups and reply alerts).
-- =====================================================================
alter table sci.system_controls add column if not exists daily_send_cap int not null default 8;

create or replace function sci.claim_next_task_of_type(p_agent sci.agent_name, p_type text, p_worker text default 'n8n')
returns setof sci.tasks language plpgsql security definer set search_path = sci, public as $$
declare t sci.tasks;
begin
  update sci.tasks set status = 'queued', locked_at = null, locked_by = null
   where owner_agent = p_agent and type = p_type and status = 'in_progress' and locked_at < now() - interval '30 minutes';
  select * into t from sci.tasks
   where owner_agent = p_agent and type = p_type and status = 'queued' and attempts < max_attempts
     and (due_at is null or due_at <= now())
   order by priority, created_at for update skip locked limit 1;
  if t.id is null then return; end if;
  update sci.tasks set status = 'in_progress', locked_at = now(), locked_by = p_worker, attempts = attempts + 1
   where id = t.id returning * into t;
  return next t;
end $$;

create or replace function sci.outbound_transition_ok(old_s sci.outbound_status, new_s sci.outbound_status)
returns boolean language sql immutable as $$
  select (old_s, new_s) in (
    ('draft','pending_approval'), ('draft','cancelled'),
    ('pending_approval','approved'), ('pending_approval','rejected'), ('pending_approval','cancelled'),
    ('pending_approval','draft'),
    ('approved','sending'), ('approved','cancelled'),
    ('approved','sent'),                                -- owner recorded a manual send (/sent); checked in the trigger
    ('sending','sent'), ('sending','failed'),
    ('failed','approved'),
    ('failed','cancelled')
  );
$$;

create or replace function sci.enforce_outbound_rules() returns trigger
language plpgsql set search_path = sci, public as $$
declare
  c sci.system_controls%rowtype;
  appr sci.approvals%rowtype;
  who text := session_user;
begin
  if tg_op = 'INSERT' then
    if new.status not in ('draft','pending_approval') then
      raise exception 'Outbound actions must be created as draft or pending_approval (got %)', new.status;
    end if;
    if sci.is_suppressed(new.recipient) then
      raise exception 'Recipient % is on the suppression list', new.recipient;
    end if;
    return new;
  end if;

  -- UPDATE
  if old.status in ('sent','cancelled','rejected') then
    raise exception 'Outbound action % is final (%) and cannot be changed', old.id, old.status;
  end if;

  -- Content may only change while still a draft / awaiting approval.
  if (new.body, new.subject, new.recipient, new.channel) is distinct from (old.body, old.subject, old.recipient, old.channel)
     and old.status not in ('draft','pending_approval') then
    raise exception 'Content of an approved action cannot be edited; cancel it and create a new draft';
  end if;

  if new.status is distinct from old.status then
    if not sci.outbound_transition_ok(old.status, new.status) then
      raise exception 'Illegal outbound transition % -> %', old.status, new.status;
    end if;

    if new.status = 'approved' then
      select * into appr from sci.approvals where id = new.approval_id;
      if appr.id is null or appr.decision not in ('approved','edited_and_approved')
         or appr.subject_id <> new.id then
        raise exception 'Cannot approve outbound % without a matching approved approval record', new.id;
      end if;
    end if;

    if new.status = 'sending' then
      select * into c from sci.system_controls where id;
      if c.global_pause then raise exception 'BLOCKED: global pause is on'; end if;
      if 'sender' = any(c.paused_agents) then raise exception 'BLOCKED: sender is paused'; end if;
      if new.channel in ('facebook_post','instagram_post','linkedin_post') then
        if not c.publishing_enabled then raise exception 'BLOCKED: publishing is not enabled'; end if;
      elsif not c.sending_enabled then
        raise exception 'BLOCKED: external sending is not enabled';
      end if;
      if new.is_test then raise exception 'BLOCKED: test records can never be sent'; end if;
      if sci.is_suppressed(new.recipient) then
        raise exception 'BLOCKED: recipient % is suppressed', new.recipient;
      end if;
      if who not in ('agent_sender','postgres') then
        raise exception 'BLOCKED: only the sender may send (current: %)', who;
      end if;
      new.attempts := old.attempts + 1;
    end if;

    if old.status = 'approved' and new.status = 'sent' then
      -- Only for emails Brett sent himself (recorded with /sent); never for automatic sending.
      if not coalesce((new.payload->>'sent_manually')::boolean, false) or who not in ('sci_approver','postgres') then
        raise exception 'BLOCKED: approved items can only be marked sent manually by the owner';
      end if;
    end if;
    if new.status = 'sent' then new.sent_at := coalesce(new.sent_at, now()); end if;
  end if;
  return new;
end $$;

-- ---------- After any outreach email is sent: log it, update the stage, schedule the next follow-up ----------
create or replace function sci.after_outreach_sent(p_outbound uuid) returns text
language plpgsql security definer set search_path = sci, public as $$
declare o sci.outbound_actions; step int; due timestamptz; nxt int;
begin
  select * into o from sci.outbound_actions where id = p_outbound;
  if o.prospect_id is null then return null; end if;
  insert into sci.interactions(contact_id, organization_id, direction, channel, subject, body, external_id, created_by)
  select o.contact_id, p.organization_id, 'outbound', 'email', o.subject, o.body, o.external_id,
         case when coalesce((o.payload->>'sent_manually')::boolean, false) then 'owner'::sci.agent_name else 'sender'::sci.agent_name end
    from sci.prospects p where p.id = o.prospect_id
  on conflict do nothing;
  update sci.prospects set stage = 'contacted' where id = o.prospect_id and stage in ('new','researched','qualified','drafted');
  step := coalesce((o.payload->>'step')::int, 1);
  if step >= 3 then return 'This was the last follow-up.'; end if;
  nxt := step + 1;
  due := now() + case when step = 1 then interval '4 days' else interval '7 days' end;
  insert into sci.tasks(type, owner_agent, priority, related_table, related_id, payload, due_at, dedupe_key, handoff_from)
  values ('draft_followup', 'sales', 2, 'prospects', o.prospect_id,
          jsonb_build_object('step', nxt, 'previous_outbound_id', o.id), due,
          'followup:' || o.prospect_id || ':step' || nxt, 'sender')
  on conflict do nothing;
  return format('Follow-up #%s will be drafted for your approval on %s, unless they reply first.', nxt - 1,
                to_char(due at time zone 'America/New_York', 'Dy Mon DD'));
end $$;

-- ---------- /sent <business>: Brett sent it himself ----------
create or replace function sci.mark_sent_manually(p_name text, p_from text) returns text
language plpgsql security definer set search_path = sci, public as $$
declare q text := trim(coalesce(p_name,'')); o sci.outbound_actions; nm text; cnt int; nextmsg text;
begin
  if length(q) < 3 then return 'Which business? e.g. /sent Simpson'; end if;
  select count(distinct org.id) into cnt
    from sci.outbound_actions ob join sci.prospects p on p.id = ob.prospect_id join sci.organizations org on org.id = p.organization_id
   where ob.status = 'approved' and ob.idempotency_key like 'outreach:%' and org.name ilike '%' || q || '%';
  if cnt = 0 then return 'I couldn''t find an approved, unsent email for "' || q || '". Approve the draft first, or check the name.'; end if;
  if cnt > 1 then return 'More than one business matches "' || q || '". Use more of the name.'; end if;
  select ob.* into o
    from sci.outbound_actions ob join sci.prospects p on p.id = ob.prospect_id join sci.organizations org on org.id = p.organization_id
   where ob.status = 'approved' and ob.idempotency_key like 'outreach:%' and org.name ilike '%' || q || '%'
   order by ob.created_at desc limit 1;
  select org.name into nm from sci.prospects p join sci.organizations org on org.id = p.organization_id where p.id = o.prospect_id;
  update sci.outbound_actions
     set payload = payload || jsonb_build_object('sent_manually', true, 'marked_by', p_from), status = 'sent', sent_at = now()
   where id = o.id;
  nextmsg := sci.after_outreach_sent(o.id);
  return '📤 Recorded: your email to ' || nm || ' is marked as sent. ' || coalesce(nextmsg, '') || ' Reply alerts are on.';
end $$;

-- Remove the signature/footer from a sent email, even if the signature has changed since it was sent.
create or replace function sci.strip_footer(p_body text) returns text language sql stable security definer set search_path = sci, public as $$
  select rtrim(regexp_replace(coalesce(p_body,''), E'\n\n' || (select full_name from sci.sender_profile where id) || E'\n.*$', '', 's'));
$$;

-- ---------- Follow-up drafting ----------
insert into sci.prompts (agent, name, version, model, effort, is_active, notes, system_text) values
('sales', 'followup_draft', 1, 'claude-opus-5-5', 'medium', true, 'Follow-ups #1 and #2 (final)', $p$
You are Brett's writing partner at Strategic Creative Initiatives (SCI). Write a SHORT follow-up to an email Brett
sent that hasn't had a reply. It goes out as a reply in the same email thread, so it doesn't need to repeat the first
email. Brett is a professional writer: the follow-up is a sample of his work.

FOLLOW-UP #1 (about 4 days later): 50-90 words. Add ONE new, genuinely useful thing: a specific idea they could use
(e.g., two blog topics their clients search for, a sharper headline for their homepage, a post idea from their
reviews), based ONLY on the verified findings. Then one easy, low-pressure question.
FOLLOW-UP #2 (final, about a week later): 40-70 words. Gracious close: say you won't keep filling their inbox, leave
the door open ("if it's ever useful, I'm a quick email away"), and wish them well. No new pitch.

WRITE PLAINLY: no "just checking in", "circling back", "bumping this", "following up on my last email", no guilt,
no urgency, no decorative words (gentle, seamless, truly, etc.). Warm and human, like a neighbor in business.
Never invent facts, names, numbers or past contact. Use only verified findings. Don't write a signature, address or
opt-out line (added automatically). If OWNER NOTES are given, follow them; if a PREVIOUS DRAFT is given, improve it.
Finish by calling submit_draft exactly once (subject can be anything; it will be "Re:" the original subject).
$p$);

create or replace function sci.sales_start_followup(p_task_id uuid, p_execution_id text default null)
returns jsonb language plpgsql security definer set search_path = sci, public as $$
declare t sci.tasks; pr sci.prompts; pid uuid; prev sci.outbound_actions; first sci.outbound_actions; run_id uuid;
        ctx jsonb; findings jsonb; kb jsonb; emails jsonb; pd jsonb; nm text; step int;
begin
  select * into t from sci.tasks where id = p_task_id and type = 'draft_followup';
  pid := t.related_id; step := coalesce((t.payload->>'step')::int, 2);
  select org.name into nm from sci.prospects p join sci.organizations org on org.id = p.organization_id where p.id = pid;
  select * into prev from sci.outbound_actions where id = (t.payload->>'previous_outbound_id')::uuid;

  -- Stop conditions: they replied, opted out, or the previous email never went out.
  if exists (select 1 from sci.prospects where id = pid and stage in ('replied','interested','meeting_booked','won','lost','do_not_contact'))
     or sci.is_suppressed(prev.recipient)
     or prev.status is distinct from 'sent' then
    update sci.tasks set status = 'cancelled', last_error = 'stopped: reply, opt-out or previous email not sent', locked_at = null where id = p_task_id;
    return jsonb_build_object('skip', true, 'reason', 'No follow-up for ' || nm || ': they replied, opted out, or the previous email wasn''t sent.');
  end if;

  select * into pr from sci.prompts where agent = 'sales' and name = 'followup_draft' and is_active;
  select * into first from sci.outbound_actions where prospect_id = pid and status = 'sent' and idempotency_key like 'outreach:%:step1:%'
   order by sent_at limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('sent', to_char(sent_at at time zone 'America/New_York', 'Mon DD'), 'subject', subject,
                                               'body', sci.strip_footer(body)) order by sent_at), '[]'::jsonb)
    into emails from sci.outbound_actions where prospect_id = pid and status = 'sent' and idempotency_key like 'outreach:%';
  select jsonb_build_object('prospect_id', p.id, 'business_name', o.name, 'website', o.website, 'city', o.city, 'state', o.state,
                            'industry', o.industry, 'recommended_service', p.recommended_service, 'is_test', p.is_test,
                            'contact', case when c.id is null then null else jsonb_build_object('name', c.full_name) end)
    into ctx from sci.prospects p join sci.organizations o on o.id = p.organization_id
    left join sci.contacts c on c.id = p.primary_contact_id where p.id = pid;
  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'category', f.category, 'statement', f.statement, 'quote', f.evidence_quote)), '[]'::jsonb)
    into findings from sci.research_findings f where f.prospect_id = pid and f.status = 'verified';
  select jsonb_object_agg(key, content) into kb from sci.business_knowledge where is_active and key in ('positioning','services','outreach_rules');
  select jsonb_build_object('subject', ob.subject, 'body', sci.strip_footer(ob.body))
    into pd from sci.outbound_actions ob where ob.id = nullif(t.payload->>'previous_draft_id','')::uuid;

  insert into sci.agent_runs(agent, workflow, task_id, prompt_id, input_ref, n8n_execution_id)
  values ('sales', 'outreach_draft', p_task_id, pr.id,
          jsonb_build_object('prospect_id', pid, 'step', step, 'previous_outbound_id', prev.id, 'original_subject', first.subject),
          p_execution_id)
  returning id into run_id;

  return jsonb_build_object('run_id', run_id, 'task_id', p_task_id, 'mode', 'followup', 'step', step,
    'prospect', ctx, 'verified_findings', findings, 'discovery_signal', null, 'previous_emails', emails,
    'previous_draft', pd, 'owner_notes', t.payload->>'owner_notes',
    'model', pr.model, 'effort', pr.effort, 'system_text', pr.system_text, 'knowledge', kb);
end $$;

-- Drafting picks due follow-ups first, then first-touch drafts.
create or replace function sci.claim_next_sales_draft(p_worker text default 'n8n') returns setof sci.tasks
language plpgsql security definer set search_path = sci, public as $$
declare t sci.tasks;
begin
  select * into t from sci.claim_next_task_of_type('sales', 'draft_followup', p_worker);
  if t.id is null then select * into t from sci.claim_next_task_of_type('sales', 'draft_outreach', p_worker); end if;
  if t.id is not null then return next t; end if;
end $$;

create or replace function sci.sales_start_outreach(p_task_id uuid, p_execution_id text default null)
returns jsonb language plpgsql security definer set search_path = sci, public as $$
declare t sci.tasks; pr sci.prompts; run_id uuid; ctx jsonb; kb jsonb; findings jsonb; sig jsonb; pid uuid; prev jsonb;
begin
  select * into t from sci.tasks where id = p_task_id and owner_agent = 'sales' and type in ('draft_outreach','draft_followup');
  if t.id is null then raise exception 'Task % is not an outreach-draft task', p_task_id; end if;
  if t.type = 'draft_followup' then return sci.sales_start_followup(p_task_id, p_execution_id); end if;
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

  select jsonb_build_object('subject', ob.subject, 'body', sci.strip_footer(ob.body))
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
  r sci.agent_runs; pid uuid; p sci.prospects; o sci.organizations; c sci.contacts; n int; step int; prev sci.outbound_actions;
  body text; full_body text; subj text; oid uuid; aid uuid; cost numeric; words int; card text; addr_missing boolean;
begin
  select * into r from sci.agent_runs where id = p_run_id and task_id = p_task_id and workflow = 'outreach_draft' and status = 'started';
  if r.id is null then raise exception 'Run % is not an open outreach run for task %', p_run_id, p_task_id; end if;
  pid := (r.input_ref->>'prospect_id')::uuid;
  select * into p from sci.prospects where id = pid;
  select * into o from sci.organizations where id = p.organization_id;
  select * into c from sci.contacts where id = p.primary_contact_id and deleted_at is null;
  step := coalesce((r.input_ref->>'step')::int, 1);
  if step > 1 then select * into prev from sci.outbound_actions where id = (r.input_ref->>'previous_outbound_id')::uuid; end if;

  subj := left(trim(coalesce(p_draft->>'subject','')), 120);
  body := trim(coalesce(p_draft->>'body',''));
  if step > 1 then subj := 'Re: ' || regexp_replace(coalesce(r.input_ref->>'original_subject', prev.subject, subj), '^(Re:\s*)+', '', 'i'); end if;
  if subj = '' or length(body) < 40 then raise exception 'Draft is empty or too short'; end if;
  full_body := body || E'\n' || sci.email_footer();
  words := array_length(regexp_split_to_array(body, '\s+'), 1);
  select mailing_address like '[%' into addr_missing from sci.sender_profile where id;
  select count(*) + 1 into n from sci.outbound_actions where prospect_id = pid and idempotency_key like 'outreach:' || pid || ':step' || step || ':%';

  insert into sci.outbound_actions(created_by, channel, prospect_id, contact_id, recipient, subject, body, payload,
                                   idempotency_key, status, is_test)
  values ('sales', 'email', pid, c.id, coalesce(prev.recipient, c.email), subj, full_body,
          jsonb_strip_nulls(jsonb_build_object('angle', p_draft->>'angle', 'finding_ids_used', p_draft->'finding_ids_used',
                             'note_for_brett', p_draft->>'note_for_brett', 'run_id', p_run_id, 'version', n, 'step', step,
                             'previous_sent_id', prev.id, 'reply_to_message_id', prev.external_id,
                             'thread_id', prev.payload->>'thread_id')),
          'outreach:' || pid || ':step' || step || ':email' || case when n > 1 then ':v' || n else '' end, 'pending_approval', p.is_test)
  returning id into oid;

  insert into sci.approvals(subject_table, subject_id, summary) values ('outbound_actions', oid, 'pending card') returning id into aid;

  card := concat_ws(E'\n',
    case when step > 1 then '📝 Follow-up #' || (step - 1) || ' for approval (sent as a reply in the same thread)' else '📝 Outreach draft for approval' end
      || case when n > 1 then ' (version ' || n || ')' else '' end || case when p.is_test then ' (TEST)' else '' end,
    '',
    'Business: ' || o.name || coalesce(' (' || o.city || ')', ''),
    'To: ' || coalesce(prev.recipient, c.email, '(no public email found: send via their website contact form or LinkedIn)'),
    'Subject: ' || subj,
    '',
    full_body,
    '',
    '— — —',
    format('Why this angle: %s', coalesce(nullif(p_draft->>'note_for_brett',''), '-')),
    format('%s words · fit score %s', words, p.fit_score),
    case when addr_missing then '⚠️ Mailing address not set yet: run local_sender_details.sql before sending.' end,
    case when (select sending_enabled from sci.system_controls where id)
         then 'Approve = it sends from your Gmail during business hours (Mon–Fri 9–5 ET). To rewrite: ✏️ Redraft, or reply with notes.'
         else 'Approve marks it ready (sending is OFF: send it yourself, then /sent <business>). To rewrite: ✏️ Redraft, or reply with notes.' end,
    'Ref D-' || left(aid::text, 8));
  update sci.approvals set summary = left(card, 3500) where id = aid;

  if step = 1 then update sci.prospects set stage = 'drafted' where id = pid and stage in ('qualified','drafted'); end if;

  cost := sci.record_llm_usage(p_run_id, 'sales', coalesce(p_usage->>'model','claude-opus-5-5'),
            coalesce((p_usage->>'input_tokens')::int,0), coalesce((p_usage->>'output_tokens')::int,0),
            coalesce((p_usage->>'cache_read_tokens')::int,0), coalesce((p_usage->>'cache_write_tokens')::int,0), 0);
  update sci.agent_runs set status = 'succeeded', finished_at = now(), output_summary = 'draft ' || oid where id = p_run_id;
  perform sci.finish_task(p_task_id, true);

  return jsonb_build_object('approval_id', aid, 'outbound_id', oid, 'card', left(card, 3900), 'cost', cost);
end $$;

create or replace function sci.request_redraft(p_approval_id uuid, p_from text, p_notes text default null)
returns text language plpgsql security definer set search_path = sci, public as $$
declare a sci.approvals; o sci.outbound_actions; nm text;
begin
  select * into a from sci.approvals where id = p_approval_id;
  if a.id is null or a.subject_table <> 'outbound_actions' then return 'Draft not found.'; end if;
  select * into o from sci.outbound_actions where id = a.subject_id;
  if o.status in ('approved','sending','sent') then return 'ℹ️ This draft is already approved; reject is no longer possible from here.'; end if;

  if o.created_by = 'social' and o.client_id is not null then
    if a.decision = 'pending' then
      perform sci.decide_approval(a.id, 'rejected', p_from, coalesce(p_notes, 'redraft requested'));
    end if;
    insert into sci.tasks(type, owner_agent, priority, related_table, related_id, payload, dedupe_key, handoff_from)
    values ('redraft_post', 'social', 1, 'outbound_actions', o.id,
            jsonb_build_object('owner_notes', nullif(trim(coalesce(p_notes,'')), '')), 'redraft_post:' || o.id, 'owner')
    on conflict do nothing;
    if not found then return 'ℹ️ A new version of this post is already in the queue.'; end if;
    return '✏️ Got it. A new version of this post' || case when coalesce(trim(p_notes),'') <> '' then ', following your notes,' else '' end
           || ' will arrive within the hour (8 AM–7 PM ET).';
  end if;

  if o.prospect_id is null or o.idempotency_key not like 'outreach:%' then return 'Only outreach drafts and social posts can be redrafted.'; end if;
  if coalesce((o.payload->>'step')::int, 1) > 1 then
    if a.decision = 'pending' then
      perform sci.decide_approval(a.id, 'rejected', p_from, coalesce(p_notes, 'redraft requested'));
    end if;
    insert into sci.tasks(type, owner_agent, priority, related_table, related_id, payload, dedupe_key, handoff_from)
    values ('draft_followup', 'sales', 1, 'prospects', o.prospect_id,
            jsonb_build_object('step', (o.payload->>'step')::int, 'previous_outbound_id', o.payload->>'previous_sent_id',
                               'owner_notes', nullif(trim(coalesce(p_notes,'')), ''), 'previous_draft_id', o.id),
            'followup:' || o.prospect_id || ':step' || (o.payload->>'step') || ':redraft', 'owner')
    on conflict do nothing;
    if not found then return 'ℹ️ A new version of this follow-up is already in the queue.'; end if;
    return '✏️ Got it. A new version of this follow-up' || case when coalesce(trim(p_notes),'') <> '' then ', following your notes,' else '' end || ' will arrive within the hour.';
  end if;
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
  return '✏️ Got it. A new draft for ' || nm || case when coalesce(trim(p_notes),'') <> '' then ', following your notes,' else '' end
         || ' will arrive within the hour (8 AM–7 PM ET).';
end $$;

-- ---------- The Sender ----------
create or replace function sci.sender_next(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = sci, public as $$
declare c sci.system_controls; o sci.outbound_actions; prev sci.outbound_actions; sent_today int; tz text := 'America/New_York';
        lt timestamp := p_now at time zone 'America/New_York';
begin
  select * into c from sci.system_controls where id;
  if c.global_pause or 'sender' = any(c.paused_agents) then return jsonb_build_object('none', true, 'reason', 'paused'); end if;
  if not c.sending_enabled then return jsonb_build_object('none', true, 'reason', 'sending is off'); end if;
  if extract(isodow from lt) > 5 or extract(hour from lt) < 9 or extract(hour from lt) >= 17 then
    return jsonb_build_object('none', true, 'reason', 'outside business hours');
  end if;
  select count(*) into sent_today from sci.outbound_actions
   where created_by = 'sales' and status = 'sent' and (sent_at at time zone tz)::date = lt::date
     and not coalesce((payload->>'sent_manually')::boolean, false);
  if sent_today >= c.daily_send_cap then return jsonb_build_object('none', true, 'reason', 'daily cap reached'); end if;

  select * into o from sci.outbound_actions
   where status = 'approved' and channel = 'email' and recipient is not null and not is_test
     and created_by = 'sales' and (scheduled_for is null or scheduled_for <= now())
   order by created_at limit 1 for update skip locked;
  if o.id is null then return jsonb_build_object('none', true, 'reason', 'nothing approved to send'); end if;

  update sci.outbound_actions set status = 'sending' where id = o.id;   -- the safety trigger re-checks everything here
  select * into prev from sci.outbound_actions where id = nullif(o.payload->>'previous_sent_id','')::uuid;
  return jsonb_build_object('outbound_id', o.id, 'to', o.recipient::text, 'subject', o.subject, 'body', o.body,
                            'reply_to_message_id', nullif(coalesce(o.payload->>'reply_to_message_id', prev.external_id), ''),
                            'mode', case when nullif(coalesce(o.payload->>'reply_to_message_id', prev.external_id), '') is not null then 'reply' else 'new' end);
end $$;

create or replace function sci.sender_done(p_outbound uuid, p_ok boolean, p_gmail_id text, p_thread_id text, p_error text default null)
returns text language plpgsql security definer set search_path = sci, public as $$
declare o sci.outbound_actions; nm text; nxt text;
begin
  select * into o from sci.outbound_actions where id = p_outbound and status = 'sending';
  if o.id is null then return null; end if;
  select org.name into nm from sci.prospects p join sci.organizations org on org.id = p.organization_id where p.id = o.prospect_id;
  if not p_ok then
    update sci.outbound_actions set status = 'failed', last_error = left(coalesce(p_error,'unknown'), 1000) where id = o.id;
    return '⚠️ Email to ' || coalesce(nm, o.recipient::text) || ' could not be sent: ' || left(coalesce(p_error,'unknown'), 200) || E'\nIt was NOT sent. Check Gmail is connected in n8n.';
  end if;
  update sci.outbound_actions set status = 'sent', external_id = p_gmail_id,
         payload = payload || jsonb_strip_nulls(jsonb_build_object('thread_id', p_thread_id)) where id = o.id;
  nxt := sci.after_outreach_sent(o.id);
  return '📤 Sent: "' || o.subject || '" to ' || coalesce(nm || ' ', '') || '<' || o.recipient || '>. ' || coalesce(nxt, '');
end $$;

-- ---------- Inbox check: replies and opt-outs ----------
create or replace function sci.process_inbox(p_messages jsonb) returns table(alert text)
language plpgsql security definer set search_path = sci, public as $$
declare m jsonb; fromaddr citext; o sci.outbound_actions; nm text; optout boolean; body text;
begin
  for m in select * from jsonb_array_elements(coalesce(p_messages, '[]'::jsonb)) loop
    fromaddr := lower(coalesce(substring(m->>'from' from '<([^>]+)>'), trim(m->>'from')))::citext;
    continue when fromaddr is null or fromaddr = (select email from sci.sender_profile where id)::citext;
    select * into o from sci.outbound_actions
     where status = 'sent' and created_by = 'sales' and channel = 'email'
       and (recipient = fromaddr or (nullif(m->>'thread_id','') is not null and payload->>'thread_id' = m->>'thread_id'))
     order by sent_at desc limit 1;
    continue when o.id is null;
    -- log once per Gmail message
    insert into sci.interactions(contact_id, organization_id, direction, channel, subject, body, external_id, created_by)
    select o.contact_id, p.organization_id, 'inbound', 'email', left(m->>'subject', 300), left(m->>'snippet', 2000), m->>'id', 'sender'
      from sci.prospects p where p.id = o.prospect_id
    on conflict do nothing;
    continue when not found;

    body := lower(coalesce(m->>'snippet','') || ' ' || coalesce(m->>'subject',''));
    optout := body ~ '(unsubscribe|remove me|take me off|stop (emailing|contacting)|do not (email|contact)|don''t (email|contact)|not interested|no thank)';
    select org.name into nm from sci.prospects p join sci.organizations org on org.id = p.organization_id where p.id = o.prospect_id;

    -- stop every pending follow-up for this business
    update sci.tasks set status = 'cancelled', last_error = 'prospect replied'
     where related_id = o.prospect_id and type = 'draft_followup' and status in ('queued','in_progress');
    update sci.outbound_actions set status = 'cancelled', last_error = 'prospect replied'
     where prospect_id = o.prospect_id and status in ('draft','pending_approval','approved') and idempotency_key like 'outreach:%';

    if optout then
      insert into sci.suppression_list(email, reason, source) values (fromaddr, 'unsubscribed', 'reply: ' || left(m->>'snippet', 120))
      on conflict do nothing;
      update sci.prospects set stage = 'do_not_contact' where id = o.prospect_id;
    else
      update sci.prospects set stage = 'replied' where id = o.prospect_id and stage in ('contacted','drafted','qualified','researched');
    end if;

    alert := concat_ws(E'\n',
      case when optout then '🚫 ' || coalesce(nm, fromaddr::text) || ' replied and asked not to be contacted.'
           else '📬 REPLY from ' || coalesce(nm, '') || ' (' || fromaddr || ')' end,
      'Subject: ' || coalesce(m->>'subject', ''),
      '"' || left(coalesce(m->>'snippet', ''), 300) || '"',
      '',
      case when optout then 'They''re on your do-not-contact list now; all follow-ups are cancelled. A short, polite acknowledgement is a nice touch.'
           else 'Follow-ups are cancelled. Open Gmail and reply personally.' end);
    return next;
  end loop;
end $$;

-- ---------- Owner-only: queue a test email to yourself (run in the Supabase SQL editor) ----------
create or replace function sci.queue_self_test_email() returns text
language plpgsql set search_path = sci, public as $$
declare me text; oid uuid; aid uuid;
begin
  select email into me from sci.sender_profile where id;
  insert into sci.outbound_actions(created_by, channel, recipient, subject, body, payload, idempotency_key, status, is_test)
  values ('sales', 'email', me, 'SCI test email: sending works',
          'This is a test from your SCI operating system. If you can read this, approved emails will send from your Gmail.' || E'\n' || sci.email_footer(),
          '{"self_test": true}'::jsonb, 'selftest:' || now()::text, 'pending_approval', false)
  returning id into oid;
  insert into sci.approvals(subject_table, subject_id, summary) values ('outbound_actions', oid, 'Self test') returning id into aid;
  perform sci.decide_approval(aid, 'approved', 'owner_console');
  return 'Test email to ' || me || ' queued. It sends on the next hourly run during business hours (Mon–Fri 9–5 ET) once sending is ON.';
end $$;
revoke all on function sci.queue_self_test_email() from public;

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
  elsif p_kind = 'helpwanted' then
    if p_decision not in ('replied','skip') then return 'Unknown choice.'; end if;
    return sci.decide_helpwanted(p_target, p_decision);
  elsif p_kind = 'sent' then
    return sci.mark_sent_manually(p_arg, p_from);
  elsif p_kind = 'post' then
    return sci.request_story_post(p_arg, p_from);
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
  elsif p_kind = 'brief' then
    return sci.weekly_briefing();
  elsif p_kind in ('help','start') then
    return concat_ws(E'\n',
      'SCI Operations bot',
      '/status: what''s happening right now',
      '/brief: the weekly summary (also sent Monday mornings)',
      '/prospect <name or website>: add a business to research',
      '/sent <business>: record an email you sent yourself (starts follow-ups and reply alerts)',
      '/post <story or idea>: a finished social post from your notes (add "Client name:" first if you have several clients)',
      '/pause: stop all agents immediately',
      '/resume: start them again',
      '',
      'Draft and post cards: ✅ Approve, ❌ Reject, ✏️ Redraft, or reply to a card with notes.',
      'Discovery cards: 🔎 Research or ⏭ Skip (verified signals are researched automatically).');
  end if;
  return null;
end $$;

grant execute on function sci.sender_next(timestamptz), sci.sender_done(uuid, boolean, text, text, text), sci.process_inbox(jsonb) to agent_sender;
grant execute on function sci.claim_next_sales_draft(text), sci.sales_start_followup(uuid, text) to agent_sales;
grant execute on function sci.mark_sent_manually(text, text), sci.request_redraft(uuid, text, text),
                          sci.handle_telegram(text, text, uuid, text, text) to sci_approver;
