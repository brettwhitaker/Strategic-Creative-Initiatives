-- =====================================================================
-- SCI AI Operating Team — 0009 Telegram commands
-- All Telegram logic lives here so the allowlist can't be bypassed from n8n.
-- Called by the "SCI – Telegram Bot" workflow using the sci_approver login.
-- =====================================================================

-- Plain-language status report (read-only; safe to grant to the bot).
create or replace function sci.status_summary() returns text
language plpgsql stable security definer set search_path = sci, public as $$
declare
  c sci.system_controls%rowtype;
  tz text; today numeric; month numeric; pending int; queued int; failed24 int; drafts int;
begin
  select * into c from sci.system_controls where id;
  tz := c.timezone;
  select coalesce(sum(cost_usd),0) into today from sci.llm_usage
   where (created_at at time zone tz)::date = (now() at time zone tz)::date;
  select coalesce(sum(cost_usd),0) into month from sci.llm_usage
   where date_trunc('month', created_at at time zone tz) = date_trunc('month', now() at time zone tz);
  select count(*) into pending from sci.approvals where decision = 'pending';
  select count(*) into queued  from sci.tasks where status = 'queued';
  select count(*) into drafts  from sci.outbound_actions where status = 'approved';
  select count(*) into failed24 from sci.agent_runs where status in ('failed','dead_letter') and started_at > now() - interval '24 hours';

  return concat_ws(E'\n',
    'SCI status',
    case when c.global_pause then '⏸ PAUSED (send /resume to restart)' else '▶️ Running' end,
    case when cardinality(c.paused_agents) > 0 then 'Paused agents: ' || array_to_string(c.paused_agents, ', ') end,
    'External sending: ' || case when c.sending_enabled then 'ON' else 'OFF (draft-only)' end,
    'Social publishing: ' || case when c.publishing_enabled then 'ON' else 'OFF' end,
    '',
    'Waiting for your approval: ' || pending,
    'Approved, waiting to send: ' || drafts,
    'Tasks in queue: ' || queued,
    'Failures in last 24h: ' || failed24,
    '',
    format('AI spend today: $%s', to_char(today, 'FM990.00')),
    format('AI spend this month: $%s of $%s cap', to_char(month, 'FM990.00'), to_char(c.monthly_total_cap_usd, 'FM990.00'))
  );
end $$;

-- One entry point for every Telegram update. Returns the reply text,
-- or NULL when the sender is not allowlisted (the bot then stays silent).
-- SECURITY INVOKER on purpose: runs with sci_approver's limited rights.
create or replace function sci.handle_telegram(p_kind text, p_from text, p_approval_id uuid default null, p_decision text default null)
returns text language plpgsql set search_path = sci, public as $$
declare allowed text[]; res text;
begin
  select owner_telegram_chat_ids into allowed from sci.system_controls where id;
  if p_from is null or not (p_from = any(allowed)) then
    return null;
  end if;

  if p_kind = 'decision' then
    if p_decision not in ('approved','rejected') then return 'Unknown decision.'; end if;
    res := sci.decide_approval(p_approval_id, p_decision::sci.approval_decision, p_from);
    return case res
      when 'approved' then '✅ Approved. (Sending is OFF, so nothing goes out until you enable it.)'
      when 'rejected' then '❌ Rejected. Nothing will be sent.'
      else 'ℹ️ This request was already decided.' end;

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
      '/pause: stop all agents immediately',
      '/resume: start them again',
      '',
      'Approval requests arrive here with Approve / Reject buttons.');
  end if;
  return null;
end $$;

grant execute on function sci.status_summary() to sci_approver, agent_exec_assistant;
grant execute on function sci.handle_telegram(text, text, uuid, text) to sci_approver;
