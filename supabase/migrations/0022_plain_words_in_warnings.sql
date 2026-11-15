-- =====================================================================
-- SCI AI Operating Team — 0022 Stuck-work warning in plain words (no underscores: Telegram treats
-- "_" as formatting in its default Markdown mode, which made /brief fail).
-- =====================================================================
create or replace function sci.stuck_warning() returns text language sql stable security definer set search_path = sci, public as $$
  select case when count(*) > 0 then
    format('⚠️ %s %s waiting %s+ hours without being picked up. Check that the "%s" workflow is published in n8n and its database steps use the right login.',
           count(*),
           case min(type) when 'research_prospect' then 'research task(s)' when 'draft_outreach' then 'outreach draft(s)' else 'social post redraft(s)' end,
           extract(hour from now() - min(created_at))::int,
           case min(type) when 'research_prospect' then 'SCI – Sales: Research Prospects'
                          when 'draft_outreach' then 'SCI – Sales: Outreach Drafts'
                          else 'SCI – Social: Content Planner' end)
  end
  from sci.tasks
  where status = 'queued' and attempts = 0 and created_at < now() - interval '4 hours'
    and type in ('research_prospect','draft_outreach','redraft_post')
  group by type order by count(*) desc limit 1;
$$;
select sci.weekly_briefing() as preview;
