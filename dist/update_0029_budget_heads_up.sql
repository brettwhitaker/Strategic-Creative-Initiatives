-- =====================================================================
-- SCI AI Operating Team — 0029 80% monthly budget heads-up (one Telegram message per month,
-- delivered by the existing twice-daily health check). /status and the briefing use a read-only
-- check; only the health check records that the heads-up was sent.
-- =====================================================================
alter table sci.system_controls add column if not exists budget_alert_month text;

-- Read-only: is queued work stuck (or paused by a budget)?
create or replace function sci.work_warning() returns text language plpgsql stable security definer set search_path = sci, public as $$
declare r record; last_run timestamptz; wf text; agent sci.agent_name; g record;
        hr int := extract(hour from now() at time zone 'America/New_York');
begin
  for r in select type, count(*) n, min(created_at) oldest from sci.tasks
            where status = 'queued' and attempts = 0 and created_at < now() - interval '4 hours'
              and type in ('research_prospect','draft_outreach','redraft_post')
            group by type loop
    wf := case r.type when 'research_prospect' then 'research_prospect' when 'draft_outreach' then 'outreach_draft' else 'social_redraft' end;
    agent := case when r.type = 'redraft_post' then 'social' else 'sales' end;
    select max(started_at) into last_run from sci.agent_runs where workflow = wf;
    if hr between 11 and 20 and (last_run is null or last_run < now() - interval '3 hours') then
      select * into g from sci.guard_check(agent, 0.30);
      if not g.ok then
        return format('⏸ %s %s waiting: the %s agent has reached its AI budget (%s). This is a safety stop, not a fault; work resumes %s.',
          r.n, case r.type when 'research_prospect' then 'research task(s)' when 'draft_outreach' then 'outreach draft(s)' else 'social post redraft(s)' end,
          agent, replace(g.reason, '_', ' '),
          case when g.reason like 'daily%' then 'tomorrow morning' when g.reason like 'global%' or g.reason like 'agent_paused%' then 'after /resume' else 'next month (or raise the limit)' end);
      end if;
      return format('⚠️ %s %s waiting, and nothing has been picked up for %s. Check that the "%s" workflow is published in n8n and its database steps use the right login.',
        r.n, case r.type when 'research_prospect' then 'research task(s)' when 'draft_outreach' then 'outreach draft(s)' else 'social post redraft(s)' end,
        case when last_run is null then 'a long time' else extract(hour from now() - last_run)::int || '+ hours' end,
        case r.type when 'research_prospect' then 'SCI – Sales: Research Prospects' when 'draft_outreach' then 'SCI – Sales: Outreach Drafts'
                    else 'SCI – Social: Content Planner' end);
    end if;
  end loop;
  return null;
end $$;

-- Health check (writes once a month): stuck work first, otherwise the 80% heads-up.
create or replace function sci.stuck_warning() returns text language plpgsql volatile security definer set search_path = sci, public as $$
declare w text; spent numeric; c sci.system_controls; tz text := 'America/New_York';
begin
  w := sci.work_warning();
  if w is not null then return w; end if;
  select coalesce(sum(cost_usd),0) into spent from sci.llm_usage
   where date_trunc('month', created_at at time zone tz) = date_trunc('month', now() at time zone tz);
  select * into c from sci.system_controls where id;
  if spent >= 0.8 * c.monthly_total_cap_usd and c.budget_alert_month is distinct from to_char(now() at time zone tz, 'YYYY-MM') then
    update sci.system_controls set budget_alert_month = to_char(now() at time zone tz, 'YYYY-MM') where id;
    return format('💰 Heads-up: AI spending this month is $%s of your $%s cap (%s%%). Everything keeps running; at $%s all agents pause until next month. To allow more this month: update sci.system_controls set monthly_total_cap_usd = 35 where id;',
      to_char(spent, 'FM990.00'), to_char(c.monthly_total_cap_usd, 'FM990'), round(100 * spent / c.monthly_total_cap_usd), to_char(c.monthly_total_cap_usd, 'FM990'));
  end if;
  return null;
end $$;

create or replace function sci.status_summary() returns text
language plpgsql stable security definer set search_path = sci, public as $$
declare
  c sci.system_controls%rowtype;
  tz text; today numeric; month numeric; pending int; queued int; failed24 int; drafts int;
begin
  select * into c from sci.system_controls where id;
  tz := c.timezone;
  select coalesce(sum(cost_usd),0) into today from sci.llm_usage where (created_at at time zone tz)::date = (now() at time zone tz)::date;
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
    sci.work_warning(),
    '',
    format('AI spend today: $%s', to_char(today, 'FM990.00')),
    format('AI spend this month: $%s of $%s cap', to_char(month, 'FM990.00'), to_char(c.monthly_total_cap_usd, 'FM990.00')),
    '',
    'Send /brief for the weekly summary.');
end $$;

create or replace function sci.weekly_briefing() returns text
language plpgsql stable security definer set search_path = sci, public as $$
declare
  tz text := 'America/New_York'; since timestamptz := now() - interval '7 days';
  researched int; q int; rv int; dq int; drafts int; approved int; sent int; cand int; cand_auto int; cand_you int; cand_skip int;
  added int; posts int; posts_ok int; pending int; waiting_send int; queued int; fails int;
  wk numeric; mo numeric; cap numeric; top text;
begin
  select count(*) into researched from sci.agent_runs where workflow = 'research_prospect' and status = 'succeeded' and started_at > since;
  select count(*) filter (where p.stage in ('qualified','drafted','contacted','replied','interested','meeting_booked','won')),
         count(*) filter (where p.stage = 'researched'),
         count(*) filter (where p.stage = 'disqualified')
    into q, rv, dq
    from sci.prospects p where p.id in (select (input_ref->>'prospect_id')::uuid from sci.agent_runs
                                        where workflow = 'research_prospect' and status = 'succeeded' and started_at > since);
  select count(*) into drafts from sci.outbound_actions where created_by = 'sales' and idempotency_key like 'outreach:%' and created_at > since;
  select count(*) into approved from sci.approvals a join sci.outbound_actions o on o.id = a.subject_id
   where o.created_by = 'sales' and a.decision in ('approved','edited_and_approved') and a.decided_at > since;
  select count(*) into sent from sci.outbound_actions where created_by = 'sales' and status = 'sent' and sent_at > since;
  select count(*), count(*) filter (where status = 'accepted' and decided_at - created_at < interval '1 minute'),
         count(*) filter (where status = 'accepted' and decided_at - created_at >= interval '1 minute'),
         count(*) filter (where status = 'skipped')
    into cand, cand_auto, cand_you, cand_skip from sci.prospect_candidates where created_at > since;
  select count(*) into added from sci.organizations where source like 'telegram%' and created_at > since;
  select count(*), count(*) filter (where o.status = 'approved') into posts, posts_ok
    from sci.outbound_actions o where o.created_by = 'social' and o.created_at > since;
  select count(*) into pending from sci.approvals where decision = 'pending';
  select count(*) into waiting_send from sci.outbound_actions where status = 'approved';
  select count(*) into queued from sci.tasks where status = 'queued';
  select count(*) into fails from sci.agent_runs where status in ('failed','dead_letter') and started_at > since;
  select coalesce(sum(cost_usd),0) into wk from sci.llm_usage where created_at > since;
  select coalesce(sum(cost_usd),0) into mo from sci.llm_usage
   where date_trunc('month', created_at at time zone tz) = date_trunc('month', now() at time zone tz);
  select monthly_total_cap_usd into cap from sci.system_controls where id;
  select string_agg(format('• %s (%s): %s', o.name, p.fit_score, sci.prospect_next_step(p.id)), E'\n' order by p.fit_score desc)
    into top
    from (select * from sci.prospects where stage in ('qualified','drafted','researched','contacted','replied','interested') and not is_test and fit_score >= 55
           order by fit_score desc nulls last limit 3) p
    join sci.organizations o on o.id = p.organization_id;

  return concat_ws(E'\n',
    format('📊 SCI weekly briefing (%s – %s)', to_char((since at time zone tz)::date, 'Mon DD'), to_char((now() at time zone tz)::date, 'Mon DD')),
    '',
    'PIPELINE (last 7 days)',
    format('• Researched: %s (%s qualified, %s your call, %s not a fit)', researched, q, rv, dq),
    format('• Outreach drafts: %s · approved: %s · sent: %s', drafts, approved, sent),
    format('• Discovery: %s candidates (%s researched automatically, %s you picked, %s skipped)', cand, cand_auto, cand_you, cand_skip),
    format('• Businesses you added with /prospect: %s', added),
    case when posts > 0 then format('• Social posts drafted: %s · approved: %s', posts, posts_ok) end,
    '',
    'WAITING ON YOU',
    format('• Approvals pending: %s', pending),
    case when waiting_send > 0 then format('• Approved but not sent: %s (copy from Telegram into Gmail for now)', waiting_send) end,
    '',
    'HEALTH',
    format('• Queue: %s · failures this week: %s', queued, fails),
    sci.work_warning(),
    format('• AI spend: $%s this week · $%s this month of $%s', to_char(wk, 'FM990.00'), to_char(mo, 'FM990.00'), to_char(cap, 'FM990.00')),
    case when top is not null then E'\nTOP PROSPECTS\n' || top end);
end $$;

grant execute on function sci.work_warning(), sci.stuck_warning(), sci.status_summary(), sci.weekly_briefing() to sci_approver, agent_exec_assistant;
