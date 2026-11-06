-- =====================================================================
-- SCI AI Operating Team — 0003 Audit log (complete change history + rollback)
-- Every insert/update/delete on important tables is recorded with the
-- before/after row. Agents cannot write or delete audit rows directly.
-- =====================================================================

create or replace function sci.audit_row() returns trigger
language plpgsql security definer set search_path = sci, public as $$
begin
  insert into sci.audit_log(actor, table_name, row_id, action, before, after)
  values (
    session_user,                       -- the real login (agent_sales, sci_approver, ...)
    tg_table_name,
    (select case when v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then v::uuid end
       from (select (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'id' as v) x),
    tg_op,
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end
  );
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'business_knowledge','clients','client_knowledge','organizations','contacts','prospects',
    'research_findings','sequences','sequence_enrollments','tasks','approvals','outbound_actions',
    'suppression_list','content_items','system_controls','prompts','budgets']
  loop
    execute format('create trigger %I_audit after insert or update or delete on sci.%I for each row execute function sci.audit_row()', t, t);
  end loop;
end $$;

-- Rollback helper: restore a single row to how it looked at a given audit entry.
-- Owner-only (run from the Supabase SQL editor). Outbox/approval rows are
-- excluded on purpose: sent messages cannot be "un-sent".
create or replace function sci.restore_row(p_audit_id bigint) returns text
language plpgsql set search_path = sci, public as $$
declare a sci.audit_log%rowtype; cols text;
begin
  select * into a from sci.audit_log where id = p_audit_id;
  if a.id is null then raise exception 'audit entry % not found', p_audit_id; end if;
  if a.table_name in ('outbound_actions','approvals','audit_log','suppression_list') then
    raise exception 'Rows in % cannot be restored automatically', a.table_name;
  end if;
  if a.before is null then raise exception 'Entry % has no prior state (was an INSERT)', p_audit_id; end if;

  select string_agg(format('%I = r.%I', key, key), ', ') into cols
    from jsonb_object_keys(a.before) key where key <> 'id';
  execute format('update sci.%I t set %s from jsonb_populate_record(null::sci.%I, $1) r where t.id = $2',
                 a.table_name, cols, a.table_name)
    using a.before, a.row_id;
  return format('restored %s %s to state before audit entry %s', a.table_name, a.row_id, p_audit_id);
end $$;
