-- =====================================================================
-- SCI AI Operating Team — 0028 Sales daily budget $1.50 -> $3.00 (monthly $15 -> $20).
-- The $25/month cap across ALL agents is unchanged and still stops everything.
-- The stuck-work warning now recognizes "paused for today: budget reached" instead of calling it stuck.
-- =====================================================================
update sci.budgets set daily_usd = 3.00, monthly_usd = 20.00 where agent = 'sales';

create or replace function sci.stuck_warning() returns text language plpgsql stable security definer set search_path = sci, public as $$
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
grant execute on function sci.stuck_warning() to sci_approver, agent_exec_assistant;

select agent, daily_usd, monthly_usd from sci.budgets order by agent;
