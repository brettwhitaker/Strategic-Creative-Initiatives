-- =====================================================================
-- SCI AI Operating Team — 0004 Roles and least-privilege access
--
-- One database login per agent. Each can touch only the tables its job
-- needs. Passwords are NOT set here (they never go in git). After running
-- this migration, set them in the Supabase SQL editor — see docs/SETUP.md.
--
-- Roles:
--   agent_sales            Sales Representative
--   agent_customer_service Customer Service Representative
--   agent_social           Social Media Manager (client data via functions only)
--   agent_exec_assistant   Executive Assistant (read-mostly, coordinates tasks)
--   agent_sender           The ONLY role that can mark messages as sending/sent
--   sci_approver           Telegram approval + /pause workflow
-- =====================================================================

set client_min_messages = warning;

do $$
declare r text;
begin
  foreach r in array array['agent_sales','agent_customer_service','agent_social','agent_exec_assistant','agent_sender','sci_approver']
  loop
    if not exists (select 1 from pg_roles where rolname = r) then
      execute format('create role %I nologin noinherit', r);
    end if;
    execute format('grant usage on schema sci to %I', r);
    execute format('revoke all on all tables in schema sci from %I', r);
  end loop;
end $$;

-- Nobody except the owner gets anything by default.
revoke all on all tables in schema sci from public;
revoke all on all functions in schema sci from public;
alter default privileges in schema sci revoke all on tables from public;
alter default privileges in schema sci revoke execute on functions from public;

-- Row-level security ON for every table. Table owner (postgres = you) bypasses it.
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'sci' loop
    execute format('alter table sci.%I enable row level security', t);
  end loop;
end $$;

-- Helper: grant a privilege AND the matching RLS policy in one line.
create or replace function sci._allow(p_role text, p_table text, p_cmd text, p_using text default 'true', p_check text default null)
returns void language plpgsql as $$
declare pol text := format('%s_%s_%s', p_role, p_table, lower(p_cmd));
begin
  execute format('grant %s on sci.%I to %I', p_cmd, p_table, p_role);
  execute format('drop policy if exists %I on sci.%I', pol, p_table);
  if p_cmd = 'INSERT' then
    execute format('create policy %I on sci.%I for insert to %I with check (%s)', pol, p_table, p_role, coalesce(p_check, p_using));
  elsif p_cmd = 'UPDATE' then
    execute format('create policy %I on sci.%I for update to %I using (%s) with check (%s)', pol, p_table, p_role, p_using, coalesce(p_check, p_using));
  else
    execute format('create policy %I on sci.%I for %s to %I using (%s)', pol, p_table, lower(p_cmd), p_role, p_using);
  end if;
end $$;

-- ---------- Common to every agent ----------
do $$
declare r text;
begin
  foreach r in array array['agent_sales','agent_customer_service','agent_social','agent_exec_assistant','agent_sender'] loop
    perform sci._allow(r, 'business_knowledge', 'SELECT', 'is_active');
    perform sci._allow(r, 'prompts', 'SELECT', 'is_active');
    perform sci._allow(r, 'system_controls', 'SELECT');
    perform sci._allow(r, 'agent_runs', 'SELECT');
    perform sci._allow(r, 'agent_runs', 'INSERT');
    perform sci._allow(r, 'agent_runs', 'UPDATE');
    execute format('grant execute on function sci.guard_check(sci.agent_name, numeric), sci.in_quiet_hours(timestamptz), sci.record_llm_usage(uuid, sci.agent_name, text, int, int, int, int, int), sci.claim_next_task(sci.agent_name, text), sci.finish_task(uuid, boolean, text), sci.is_suppressed(citext) to %I', r);
  end loop;
end $$;

-- ---------- Sales Representative ----------
select sci._allow('agent_sales', t, c)
  from unnest(array['organizations','contacts','prospects','research_findings','interactions']) t,
       unnest(array['SELECT','INSERT','UPDATE']) c;
select sci._allow('agent_sales', 'sequences', 'SELECT', 'is_approved');
select sci._allow('agent_sales', 'sequence_enrollments', c) from unnest(array['SELECT','INSERT','UPDATE']) c;
select sci._allow('agent_sales', 'tasks', c) from unnest(array['SELECT','INSERT','UPDATE']) c;
-- Outbox: may create drafts and see/edit only its own, never approve or send (trigger enforces states).
select sci._allow('agent_sales', 'outbound_actions', 'SELECT', $$created_by = 'sales'$$);
select sci._allow('agent_sales', 'outbound_actions', 'INSERT', $$created_by = 'sales' and client_id is null$$);
select sci._allow('agent_sales', 'outbound_actions', 'UPDATE', $$created_by = 'sales' and status in ('draft','pending_approval')$$,
                                                     $$created_by = 'sales' and status in ('draft','pending_approval','cancelled')$$);
select sci._allow('agent_sales', 'approvals', 'INSERT', $$decision = 'pending'$$);
select sci._allow('agent_sales', 'approvals', 'SELECT');

-- ---------- Customer Service Representative ----------
select sci._allow('agent_customer_service', t, c)
  from unnest(array['organizations','contacts','prospects','interactions']) t,
       unnest(array['SELECT','INSERT','UPDATE']) c;
select sci._allow('agent_customer_service', 'tasks', c) from unnest(array['SELECT','INSERT','UPDATE']) c;
select sci._allow('agent_customer_service', 'suppression_list', 'INSERT');   -- record unsubscribe requests
select sci._allow('agent_customer_service', 'outbound_actions', 'SELECT', $$created_by = 'customer_service'$$);
select sci._allow('agent_customer_service', 'outbound_actions', 'INSERT', $$created_by = 'customer_service' and client_id is null$$);
select sci._allow('agent_customer_service', 'approvals', 'INSERT', $$decision = 'pending'$$);
select sci._allow('agent_customer_service', 'approvals', 'SELECT');

-- ---------- Social Media Manager ----------
-- No direct access to client tables: client knowledge is read ONE CLIENT PER CALL
-- through sci.get_client_context(client_id). Write functions arrive in Phase 4.
select sci._allow('agent_social', 'tasks', c) from unnest(array['SELECT','UPDATE']) c;
grant execute on function sci.get_client_context(uuid) to agent_social;

-- ---------- Executive Assistant (coordination + briefings) ----------
select sci._allow('agent_exec_assistant', t, 'SELECT')
  from unnest(array['clients','organizations','prospects','tasks','approvals','outbound_actions','agent_runs','llm_usage','budgets','sequence_enrollments','interactions']) t;
select sci._allow('agent_exec_assistant', 'tasks', c) from unnest(array['INSERT','UPDATE']) c;

-- ---------- Sender (the single door to the outside world) ----------
select sci._allow('agent_sender', 'outbound_actions', 'SELECT', $$status in ('approved','sending','failed')$$);
select sci._allow('agent_sender', 'outbound_actions', 'UPDATE', $$status in ('approved','sending','failed')$$,
                                                      $$status in ('sending','sent','failed')$$);
select sci._allow('agent_sender', 'approvals', 'SELECT');
select sci._allow('agent_sender', 'interactions', 'INSERT');
select sci._allow('agent_sender', 'prospects', 'SELECT');
select sci._allow('agent_sender', 'prospects', 'UPDATE');

-- ---------- Approver (Telegram buttons, /pause, /resume, unsubscribe) ----------
select sci._allow('sci_approver', 'approvals', c) from unnest(array['SELECT','UPDATE']) c;
select sci._allow('sci_approver', 'outbound_actions', 'SELECT');
select sci._allow('sci_approver', 'outbound_actions', 'UPDATE', $$status = 'pending_approval'$$,
                                                     $$status in ('approved','rejected','draft','pending_approval')$$);
select sci._allow('sci_approver', 'system_controls', 'SELECT');
-- /pause and /resume may flip pause flags only; enabling sending/publishing stays owner-only (column grant).
revoke update on sci.system_controls from sci_approver;
grant update (global_pause, paused_agents, updated_by) on sci.system_controls to sci_approver;
drop policy if exists sci_approver_system_controls_update on sci.system_controls;
create policy sci_approver_system_controls_update on sci.system_controls for update to sci_approver using (true) with check (true);
select sci._allow('sci_approver', 'suppression_list', 'INSERT');
select sci._allow('sci_approver', 'tasks', 'SELECT');
grant execute on function sci.decide_approval(uuid, sci.approval_decision, text, text) to sci_approver;

-- Agents never see the audit log or each other's cost settings beyond the EA.
-- (Owner reads everything from the Supabase dashboard as postgres.)

drop function sci._allow(text, text, text, text, text);
