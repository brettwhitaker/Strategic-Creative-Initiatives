-- =====================================================================
-- FICTIONAL test data for Phase 1. All businesses, people and emails are
-- made up and use the reserved ".test" domain, which can never receive
-- email. Every row is is_test = true; the database refuses to send test rows.
-- Remove later with:  select sci.purge_test_data();   (defined below)
-- =====================================================================

insert into sci.clients (id, name, status, is_test, notes) values
  ('00000000-0000-0000-0000-0000000000c1', 'TEST Client — Harbor Coffee Co.', 'test', true, 'Fictional client for testing isolation');

insert into sci.client_knowledge (client_id, kind, content, approved_by) values
  ('00000000-0000-0000-0000-0000000000c1', 'voice', 'Friendly, neighborhood, a little playful. (TEST)', 'owner');

insert into sci.organizations (id, name, website, domain, industry, city, county, state, source, is_test) values
  ('00000000-0000-0000-0000-0000000000a1', 'Riverbend Plumbing & Drain (TEST)', 'https://riverbendplumbing.test', 'riverbendplumbing.test', 'Home services', 'Jacksonville', 'Duval', 'FL', 'test', true),
  ('00000000-0000-0000-0000-0000000000a2', 'Coquina Family Law (TEST)',        'https://coquinalaw.test',       'coquinalaw.test',       'Legal services', 'St. Augustine', 'St. Johns', 'FL', 'test', true),
  ('00000000-0000-0000-0000-0000000000a3', 'Fleming Island Physical Therapy (TEST)', 'https://flemingpt.test',  'flemingpt.test',        'Healthcare',     'Fleming Island', 'Clay', 'FL', 'test', true),
  ('00000000-0000-0000-0000-0000000000a4', 'Ponte Vedra Wealth Partners (TEST)', 'https://pvwealth.test',      'pvwealth.test',         'Financial advisory', 'Ponte Vedra Beach', 'St. Johns', 'FL', 'test', true),
  ('00000000-0000-0000-0000-0000000000a5', 'Brightline Marketing Group (TEST)', 'https://brightlinemg.test',   'brightlinemg.test',     'Marketing agency', 'Jacksonville', 'Duval', 'FL', 'test', true);

insert into sci.contacts (id, organization_id, full_name, role_title, email, consent_basis, source, is_test) values
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', 'Dana Testperson', 'Owner',            'dana@riverbendplumbing.test', 'public_business_contact', 'test', true),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a2', 'Morgan Example',  'Managing Partner', 'morgan@coquinalaw.test',      'public_business_contact', 'test', true),
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000a3', 'Jordan Sample',   'Clinic Director',  'jordan@flemingpt.test',       'public_business_contact', 'test', true),
  ('00000000-0000-0000-0000-0000000000b4', '00000000-0000-0000-0000-0000000000a4', 'Casey Fictional', 'Principal',        'casey@pvwealth.test',         'public_business_contact', 'test', true);

insert into sci.prospects (id, organization_id, primary_contact_id, stage, is_test) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', 'new', true),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000b2', 'new', true),
  ('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000b3', 'new', true),
  ('00000000-0000-0000-0000-0000000000d4', '00000000-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000b4', 'new', true),
  ('00000000-0000-0000-0000-0000000000d5', '00000000-0000-0000-0000-0000000000a5', null,                                    'new', true);  -- competitor: should be disqualified

-- One opted-out contact so we can prove unsubscribe enforcement works.
insert into sci.suppression_list (email, reason, source) values ('casey@pvwealth.test', 'unsubscribed', 'test');

-- Research tasks queued for the Sales agent (dedupe_key prevents double-queuing).
insert into sci.tasks (type, owner_agent, priority, related_table, related_id, dedupe_key)
select 'research_prospect', 'sales', 3, 'prospects', p.id, 'research:' || p.id
  from sci.prospects p where p.is_test;

-- Helper to remove all test data later (owner runs it from the SQL editor).
create or replace function sci.purge_test_data() returns text language plpgsql as $$
begin
  -- audit + outbox history is permanent; test outbox rows are cancelled, not deleted
  update sci.outbound_actions set status = 'cancelled' where is_test and status in ('draft','pending_approval','approved','failed');
  update sci.tasks set status = 'cancelled' where related_id in (select id from sci.prospects where is_test) and status not in ('done','failed','cancelled');
  update sci.prospects set deleted_at = now() where is_test;
  update sci.contacts set deleted_at = now() where is_test;
  update sci.organizations set deleted_at = now() where is_test;
  update sci.clients set deleted_at = now(), status = 'former' where is_test;
  return 'test data soft-deleted';
end $$;
