-- =====================================================================
-- Safety test suite. Each test tries to break a rule and must FAIL to.
-- Run against a scratch database (scripts/test_local.sh) — never production.
-- =====================================================================
\set ON_ERROR_STOP on
create schema if not exists t;

-- expect_error: run SQL (optionally as a role); pass only if it raises an error.
create or replace function t.expect_error(label text, stmt text, as_role text default null) returns void language plpgsql as $$
begin
  begin
    if as_role is not null then execute format('set local role %I', as_role); end if;
    execute stmt;
    if as_role is not null then reset role; end if;
  exception when others then
    if as_role is not null then reset role; end if;
    raise notice 'PASS  %  (blocked: %)', label, left(sqlerrm, 90);
    return;
  end;
  raise exception 'FAIL  %  — statement was allowed but should have been blocked', label;
end $$;

create or replace function t.expect_ok(label text, stmt text, as_role text default null) returns void language plpgsql as $$
begin
  if as_role is not null then execute format('set local role %I', as_role); end if;
  execute stmt;
  if as_role is not null then reset role; end if;
  raise notice 'PASS  %', label;
exception when others then
  if as_role is not null then reset role; end if;
  raise exception 'FAIL  %  — unexpected error: %', label, sqlerrm;
end $$;

create or replace function t.assert(label text, cond boolean) returns void language plpgsql as $$
begin
  if cond then raise notice 'PASS  %', label; else raise exception 'FAIL  %', label; end if;
end $$;

begin;

-- ---- Facts vs assumptions ----
select t.expect_error('verified finding without a source is rejected',
  $$insert into sci.research_findings(prospect_id, category, statement, status)
    values ('00000000-0000-0000-0000-0000000000d1','website','Has no blog','verified')$$);
select t.expect_ok('inferred finding without a source is allowed',
  $$insert into sci.research_findings(prospect_id, category, statement, status)
    values ('00000000-0000-0000-0000-0000000000d1','website','Likely small team','inferred')$$);
select t.expect_ok('verified finding WITH source+quote is allowed',
  $$insert into sci.research_findings(prospect_id, category, statement, status, source_url, evidence_quote, retrieved_at)
    values ('00000000-0000-0000-0000-0000000000d1','website','Offers 24/7 service','verified','https://riverbendplumbing.test','"Open 24/7"', now())$$);

-- ---- Outbox: unsubscribe, states, duplicates ----
select t.expect_error('draft to an unsubscribed person is rejected',
  $$insert into sci.outbound_actions(created_by, channel, recipient, body, idempotency_key, is_test)
    values ('sales','email','casey@pvwealth.test','hi','k-casey', true)$$);
select t.expect_error('domain-level suppression also blocks (other address, same domain)',
  $$insert into sci.suppression_list(domain, reason) values ('coquinalaw.test','do_not_contact');
    insert into sci.outbound_actions(created_by, channel, recipient, body, idempotency_key, is_test)
    values ('sales','email','frontdesk@coquinalaw.test','hi','k-coq', true)$$);
select t.expect_error('outbound cannot be created already "sent"',
  $$insert into sci.outbound_actions(created_by, channel, recipient, body, idempotency_key, status, is_test)
    values ('sales','email','dana@riverbendplumbing.test','hi','k-x','sent', true)$$);

insert into sci.outbound_actions(id, created_by, channel, prospect_id, recipient, subject, body, idempotency_key, status, is_test)
values ('00000000-0000-0000-0000-00000000e001','sales','email','00000000-0000-0000-0000-0000000000d1',
        'dana@riverbendplumbing.test','Hello','Draft body','outreach:d1:step1:email','pending_approval', true);

select t.expect_error('duplicate action (same idempotency key) is rejected',
  $$insert into sci.outbound_actions(created_by, channel, recipient, body, idempotency_key, is_test)
    values ('sales','email','dana@riverbendplumbing.test','again','outreach:d1:step1:email', true)$$);
select t.expect_error('cannot approve without an approval record',
  $$update sci.outbound_actions set status='approved' where id='00000000-0000-0000-0000-00000000e001'$$);

-- ---- Approvals ----
insert into sci.approvals(id, subject_table, subject_id, summary)
values ('00000000-0000-0000-0000-00000000f001','outbound_actions','00000000-0000-0000-0000-00000000e001','Intro email to Riverbend (TEST)');
update sci.system_controls set owner_telegram_chat_ids = array['111111'];

select t.expect_error('approval from a non-allowlisted Telegram user is rejected',
  $$select sci.decide_approval('00000000-0000-0000-0000-00000000f001','approved','999999')$$);
select t.expect_ok('owner (allowlisted) approves',
  $$select sci.decide_approval('00000000-0000-0000-0000-00000000f001','approved','111111')$$);
select t.assert('approved decision moved outbox item to approved',
  (select status = 'approved' from sci.outbound_actions where id='00000000-0000-0000-0000-00000000e001'));
select t.expect_error('approval decisions are final',
  $$update sci.approvals set decision='rejected' where id='00000000-0000-0000-0000-00000000f001'$$);
select t.expect_error('approved content cannot be edited afterwards',
  $$update sci.outbound_actions set body='sneaky change' where id='00000000-0000-0000-0000-00000000e001'$$);

-- ---- Sending gates ----
select t.expect_error('sending blocked while sending_enabled = false',
  $$update sci.outbound_actions set status='sending' where id='00000000-0000-0000-0000-00000000e001'$$);
update sci.system_controls set sending_enabled = true;
select t.expect_error('test records can never be sent, even with sending on',
  $$update sci.outbound_actions set status='sending' where id='00000000-0000-0000-0000-00000000e001'$$);
update sci.system_controls set sending_enabled = false;
select t.expect_error('outbox history cannot be deleted',
  $$delete from sci.outbound_actions where id='00000000-0000-0000-0000-00000000e001'$$);

-- ---- Unsubscribe cancels pending work ----
insert into sci.outbound_actions(id, created_by, channel, recipient, body, idempotency_key, status, is_test)
values ('00000000-0000-0000-0000-00000000e002','sales','email','jordan@flemingpt.test','Draft','outreach:d3:step1:email','pending_approval', true);
insert into sci.suppression_list(email, reason) values ('jordan@flemingpt.test','unsubscribed');
select t.assert('new unsubscribe cancels that person''s pending drafts',
  (select status = 'cancelled' from sci.outbound_actions where id='00000000-0000-0000-0000-00000000e002'));

-- ---- Kill switch and budgets ----
update sci.system_controls set global_pause = true;
select t.assert('global pause stops every agent', (select not ok from sci.guard_check('sales')));
update sci.system_controls set global_pause = false, paused_agents = array['sales']::sci.agent_name[];
select t.assert('single-agent pause stops only that agent',
  (select not ok from sci.guard_check('sales')) and (select ok from sci.guard_check('customer_service')));
update sci.system_controls set paused_agents = '{}';
select t.assert('guard passes normally', (select ok from sci.guard_check('sales')));
select sci.record_llm_usage(null, 'sales', 'claude-opus-5-5', 500000, 40000);  -- ~$2.80
select t.assert('cost computed from price table ($2.80)',
  (select cost_usd = 2.8000 from sci.llm_usage order by created_at desc limit 1));
select t.assert('daily budget stops the agent before overspending', (select not ok from sci.guard_check('sales', 0.50)));

-- ---- Task queue ----
select t.assert('two workers never claim the same task',
  (select (sci.claim_next_task('sales')).id is distinct from (sci.claim_next_task('sales')).id));

-- ---- Least privilege (per-agent logins) ----
select t.expect_error('Sales cannot read client data',           $$select * from sci.clients$$, 'agent_sales');
select t.expect_error('Sales cannot read the audit log',         $$select * from sci.audit_log$$, 'agent_sales');
select t.expect_error('Sales cannot approve its own drafts',     $$update sci.approvals set decision='approved'$$, 'agent_sales');
select t.expect_error('Sales cannot turn on sending',            $$update sci.system_controls set sending_enabled=true$$, 'agent_sales');
select t.expect_error('Sales cannot read the unsubscribe list',  $$select * from sci.suppression_list$$, 'agent_sales');
select t.expect_ok   ('Sales can check suppression via function', $$select sci.is_suppressed('x@y.test')$$, 'agent_sales');
select t.expect_ok   ('Sales can create a draft',
  $$insert into sci.outbound_actions(created_by, channel, recipient, body, idempotency_key, is_test)
    values ('sales','email','dana@riverbendplumbing.test','v2','outreach:d1:step2:email', true)$$, 'agent_sales');
select t.expect_error('Sales cannot create drafts pretending to be another agent',
  $$insert into sci.outbound_actions(created_by, channel, recipient, body, idempotency_key, is_test)
    values ('customer_service','email','dana@riverbendplumbing.test','v3','k-imp', true)$$, 'agent_sales');
select t.expect_error('Social agent cannot read client tables directly', $$select * from sci.client_knowledge$$, 'agent_social');
select t.expect_ok   ('Social agent reads ONE client via function',
  $$select * from sci.get_client_context('00000000-0000-0000-0000-0000000000c1')$$, 'agent_social');
select t.expect_error('Approver bot cannot turn on sending',     $$update sci.system_controls set sending_enabled=true$$, 'sci_approver');
select t.expect_ok   ('Approver bot can pause everything',       $$update sci.system_controls set global_pause=true, updated_by='telegram'$$, 'sci_approver');
update sci.system_controls set global_pause = false;
select t.expect_error('Customer Service cannot touch sales outbox items',
  $$update sci.outbound_actions set body='x' where created_by='sales'$$, 'agent_customer_service');

-- ---- Audit + rollback ----
update sci.prospects set fit_score = 10 where id = '00000000-0000-0000-0000-0000000000d2';
update sci.prospects set fit_score = 99 where id = '00000000-0000-0000-0000-0000000000d2';
select sci.restore_row((select id from sci.audit_log where table_name='prospects'
                         and row_id='00000000-0000-0000-0000-0000000000d2' and action='UPDATE' order by id desc limit 1));
select t.assert('rollback restores the previous value',
  (select fit_score = 10 from sci.prospects where id='00000000-0000-0000-0000-0000000000d2'));
select t.assert('every change is in the audit log', (select count(*) > 20 from sci.audit_log));

-- ---- Total monthly AI cap across ALL agents ----
update sci.system_controls set monthly_total_cap_usd = 3.00;
select t.assert('total cap blocks a DIFFERENT agent once combined spend hits the limit',
  (select not ok and reason like 'TOTAL_monthly_cap_reached%' from sci.guard_check('exec_assistant', 0.50)));
update sci.system_controls set monthly_total_cap_usd = 25.00;
select t.assert('default total cap is $25/month', (select ok from sci.guard_check('exec_assistant', 0.10)));

-- ---- Knowledge versioning ----
select sci.set_knowledge('icp', 'v-test');
select t.assert('editing knowledge keeps exactly one active version and preserves history',
  (select count(*) = 1 from sci.business_knowledge where key='icp' and is_active)
  and (select count(*) >= 3 from sci.business_knowledge where key='icp'));
select t.assert('content writing AND social media are both core offers',
  (select content like '%CORE OFFER A — Content Writing%' and content like '%CORE OFFER B — Social Media%' from sci.business_knowledge where key='services' and is_active));

rollback;
\echo
\echo ALL SAFETY TESTS PASSED
