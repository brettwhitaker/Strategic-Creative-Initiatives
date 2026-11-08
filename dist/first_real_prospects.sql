-- First REAL prospects for a live research test (chosen by Claude from public listings, Nov 2026).
-- Research only READS their public web pages. Nothing is ever sent without Brett's approval.
do $$
declare r record; org uuid; pid uuid;
begin
  for r in select * from (values
    ('Simpson & Paull, P.L.',              'Legal services (family law)', 'Jacksonville Beach', 'Duval',     'FL'),
    ('Revival Physical Therapy',           'Healthcare (physical therapy)', 'Fleming Island',   'Clay',      'FL'),
    ('Glacier Heating & Air Conditioning', 'Home services (HVAC)',        'St. Augustine',      'St. Johns', 'FL')
  ) v(name, industry, city, county, state)
  loop
    if exists (select 1 from sci.organizations where name = r.name and deleted_at is null) then continue; end if;
    insert into sci.organizations(name, industry, city, county, state, source)
    values (r.name, r.industry, r.city, r.county, r.state, 'manual: public directory listing') returning id into org;
    insert into sci.prospects(organization_id) values (org) returning id into pid;
    insert into sci.tasks(type, owner_agent, priority, related_table, related_id, dedupe_key)
    values ('research_prospect', 'sales', 1, 'prospects', pid, 'research:' || pid);
  end loop;
end $$;

-- Keep ONE fictional test (the "competitor" agency) to check the agent says "unknown" instead of guessing;
-- cancel the other test research tasks so they don't use budget.
update sci.tasks set status = 'cancelled'
 where type = 'research_prospect' and status = 'queued'
   and related_id in (select id from sci.prospects where is_test and id <> '00000000-0000-0000-0000-0000000000d5');
update sci.tasks set priority = 5 where dedupe_key = 'research:00000000-0000-0000-0000-0000000000d5';

select o.name, t.priority, t.status from sci.tasks t join sci.prospects p on p.id = t.related_id
  join sci.organizations o on o.id = p.organization_id where t.type = 'research_prospect' order by t.status desc, t.priority;
