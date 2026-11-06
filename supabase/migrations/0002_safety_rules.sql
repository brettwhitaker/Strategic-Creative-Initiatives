-- =====================================================================
-- SCI AI Operating Team — 0002 Safety rules
-- The guarantees that must NOT depend on prompts: approvals, unsubscribe
-- enforcement, duplicate prevention, kill switch, budgets, task locking.
-- =====================================================================

-- ---------- updated_at maintenance ----------
create or replace function sci.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

do $$
declare t text;
begin
  foreach t in array array['clients','organizations','contacts','prospects','tasks','outbound_actions','content_items','system_controls']
  loop
    execute format('create trigger %I_touch before update on sci.%I for each row execute function sci.touch_updated_at()', t, t);
  end loop;
end $$;

-- ---------- Suppression check (email OR whole domain) ----------
create or replace function sci.is_suppressed(p_email citext) returns boolean
language sql stable security definer set search_path = sci, public as $$
  select p_email is not null and exists (
    select 1 from sci.suppression_list s
    where s.email = p_email
       or s.domain = split_part(p_email::text, '@', 2)::citext
  );
$$;

-- When someone is suppressed: stop sequences and cancel anything not yet sent.
create or replace function sci.on_suppression_added() returns trigger
language plpgsql security definer set search_path = sci, public as $$
begin
  update sci.outbound_actions o
     set status = 'cancelled', last_error = 'recipient suppressed: ' || new.reason
   where o.status in ('draft','pending_approval','approved')
     and o.recipient is not null
     and (o.recipient = new.email or split_part(o.recipient::text,'@',2)::citext = new.domain);

  update sci.sequence_enrollments e
     set status = 'stopped_unsubscribe', next_step_at = null
    from sci.prospects p
    left join sci.contacts c on c.id = p.primary_contact_id
    left join sci.organizations org on org.id = p.organization_id
   where e.prospect_id = p.id and e.status = 'active'
     and (c.email = new.email or org.domain = new.domain or split_part(c.email::text,'@',2)::citext = new.domain);
  return new;
end $$;
create trigger suppression_added after insert on sci.suppression_list
  for each row execute function sci.on_suppression_added();

-- ---------- Outbox state machine ----------
-- Allowed transitions. Anything else is rejected.
create or replace function sci.outbound_transition_ok(old_s sci.outbound_status, new_s sci.outbound_status)
returns boolean language sql immutable as $$
  select (old_s, new_s) in (
    ('draft','pending_approval'), ('draft','cancelled'),
    ('pending_approval','approved'), ('pending_approval','rejected'), ('pending_approval','cancelled'),
    ('pending_approval','draft'),                       -- owner asked for edits
    ('approved','sending'), ('approved','cancelled'),
    ('sending','sent'), ('sending','failed'),
    ('failed','approved'),                              -- retry after failure
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

    if new.status = 'sent' then new.sent_at := coalesce(new.sent_at, now()); end if;
  end if;
  return new;
end $$;

create trigger outbound_rules before insert or update on sci.outbound_actions
  for each row execute function sci.enforce_outbound_rules();

-- Deleting outbox history is never allowed (cancel instead).
create or replace function sci.forbid_delete() returns trigger language plpgsql as $$
begin raise exception 'Deleting from % is not allowed; use status/deleted_at instead', tg_table_name; end $$;
create trigger outbound_no_delete before delete on sci.outbound_actions for each row execute function sci.forbid_delete();
create trigger approvals_no_delete before delete on sci.approvals for each row execute function sci.forbid_delete();
create trigger audit_no_delete before delete on sci.audit_log for each row execute function sci.forbid_delete();
create trigger suppression_no_delete before delete on sci.suppression_list for each row execute function sci.forbid_delete();

-- Approval decisions are final once made.
create or replace function sci.enforce_approval_rules() returns trigger language plpgsql as $$
begin
  if old.decision <> 'pending' and new.decision is distinct from old.decision then
    raise exception 'Approval % already decided (%)', old.id, old.decision;
  end if;
  if new.decision <> 'pending' and old.decision = 'pending' then
    new.decided_at := coalesce(new.decided_at, now());
  end if;
  return new;
end $$;
create trigger approval_rules before update on sci.approvals for each row execute function sci.enforce_approval_rules();

-- Owner decision in one atomic call (used by the Telegram approval workflow).
create or replace function sci.decide_approval(p_approval_id uuid, p_decision sci.approval_decision, p_decided_by text, p_notes text default null)
returns text language plpgsql set search_path = sci, public as $$
declare a sci.approvals%rowtype; allowed text[];
begin
  select owner_telegram_chat_ids into allowed from sci.system_controls where id;
  -- Telegram decisions must come from an allowlisted chat id; 'owner_console'
  -- is only accepted from the owner's own database login (Supabase dashboard).
  if not ( (p_decided_by = any(allowed) and session_user in ('sci_approver','postgres'))
        or (p_decided_by = 'owner_console' and session_user = 'postgres') ) then
    raise exception 'Not an authorized approver: %', p_decided_by;
  end if;
  update sci.approvals set decision = p_decision, decided_by = p_decided_by, edit_notes = p_notes
   where id = p_approval_id and decision = 'pending' returning * into a;
  if a.id is null then return 'already_decided_or_missing'; end if;

  if a.subject_table = 'outbound_actions' then
    update sci.outbound_actions
       set status = case when p_decision in ('approved','edited_and_approved') then 'approved'::sci.outbound_status
                         when p_decision = 'rejected' then 'rejected'::sci.outbound_status
                         else status end,
           approval_id = a.id
     where id = a.subject_id and status = 'pending_approval';
  end if;
  return p_decision::text;
end $$;

-- ---------- Kill switch + budget guard (first step of EVERY workflow) ----------
create or replace function sci.guard_check(p_agent sci.agent_name, p_estimated_usd numeric default 0.50)
returns table(ok boolean, reason text)
language plpgsql stable security definer set search_path = sci, public as $$
declare
  c sci.system_controls%rowtype;
  b sci.budgets%rowtype;
  spent_today numeric; spent_month numeric;
  tz text;
begin
  select * into c from sci.system_controls where id;
  tz := coalesce(c.timezone, 'America/New_York');
  if c.global_pause then return query select false, 'global_pause'; return; end if;
  if p_agent = any(c.paused_agents) then return query select false, 'agent_paused'; return; end if;

  select * into b from sci.budgets where agent = p_agent;
  if b.agent is null then return query select false, 'no_budget_configured'; return; end if;

  select coalesce(sum(cost_usd),0) into spent_today from sci.llm_usage
   where agent = p_agent and (created_at at time zone tz)::date = (now() at time zone tz)::date;
  select coalesce(sum(cost_usd),0) into spent_month from sci.llm_usage
   where agent = p_agent and date_trunc('month', created_at at time zone tz) = date_trunc('month', now() at time zone tz);

  if spent_today + p_estimated_usd > b.daily_usd then
    return query select false, format('daily_budget_exceeded (%s of %s)', spent_today, b.daily_usd); return; end if;
  if spent_month + p_estimated_usd > b.monthly_usd then
    return query select false, format('monthly_budget_exceeded (%s of %s)', spent_month, b.monthly_usd); return; end if;
  return query select true, 'ok';
end $$;

-- Is it currently quiet hours for the owner? (Used before non-urgent notifications.)
create or replace function sci.in_quiet_hours(p_at timestamptz default now()) returns boolean
language sql stable as $$
  select case when c.quiet_hours_start > c.quiet_hours_end
              then (p_at at time zone c.timezone)::time >= c.quiet_hours_start
                or (p_at at time zone c.timezone)::time <  c.quiet_hours_end
              else (p_at at time zone c.timezone)::time between c.quiet_hours_start and c.quiet_hours_end end
  from sci.system_controls c where c.id;
$$;

-- ---------- AI usage recording (cost computed centrally) ----------
create or replace function sci.record_llm_usage(
  p_run_id uuid, p_agent sci.agent_name, p_model text,
  p_input int, p_output int, p_cache_read int default 0, p_cache_write int default 0, p_web_searches int default 0)
returns numeric language plpgsql security definer set search_path = sci, public as $$
declare pr sci.model_prices%rowtype; cost numeric;
begin
  select * into pr from sci.model_prices where model = p_model;
  if pr.model is null then raise exception 'No price configured for model %', p_model; end if;
  cost := (p_input * pr.input_per_mtok
         + p_output * pr.output_per_mtok
         + p_cache_read * pr.cache_read_per_mtok
         + p_cache_write * pr.input_per_mtok * 1.25) / 1000000.0
         + p_web_searches * pr.web_search_per_1k / 1000.0;
  insert into sci.llm_usage(agent_run_id, agent, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, web_searches, cost_usd)
  values (p_run_id, p_agent, p_model, p_input, p_output, p_cache_read, p_cache_write, p_web_searches, round(cost, 4));
  return round(cost, 4);
end $$;

-- ---------- Task queue: claim one task safely (no double-processing) ----------
create or replace function sci.claim_next_task(p_agent sci.agent_name, p_worker text default 'n8n')
returns sci.tasks language plpgsql security definer set search_path = sci, public as $$
declare t sci.tasks;
begin
  -- release stale locks (worker crashed > 30 min ago)
  update sci.tasks set status = 'queued', locked_at = null, locked_by = null
   where owner_agent = p_agent and status = 'in_progress' and locked_at < now() - interval '30 minutes';

  select * into t from sci.tasks
   where owner_agent = p_agent and status = 'queued' and attempts < max_attempts
   order by priority, created_at
   for update skip locked limit 1;
  if t.id is null then return null; end if;

  update sci.tasks set status = 'in_progress', locked_at = now(), locked_by = p_worker, attempts = attempts + 1
   where id = t.id returning * into t;
  return t;
end $$;

create or replace function sci.finish_task(p_task_id uuid, p_ok boolean, p_error text default null)
returns void language plpgsql security definer set search_path = sci, public as $$
begin
  update sci.tasks
     set status = case when p_ok then 'done'::sci.task_status
                       when attempts >= max_attempts then 'failed'::sci.task_status
                       else 'queued'::sci.task_status end,
         last_error = p_error, locked_at = null, locked_by = null
   where id = p_task_id;
end $$;

-- ---------- Client-isolated knowledge access (one client per call) ----------
create or replace function sci.get_client_context(p_client_id uuid)
returns table(kind text, version int, content text)
language sql stable security definer set search_path = sci, public as $$
  select kind, version, content from sci.client_knowledge
   where client_id = p_client_id and is_active
   order by kind;
$$;
