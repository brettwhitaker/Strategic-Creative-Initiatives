-- =====================================================================
-- SCI AI Operating Team — 0001 Core schema
-- Shared knowledge, CRM, tasks, outbox, approvals, controls, logging.
-- Safe to run on a fresh Supabase project (SQL editor or `supabase db push`).
-- =====================================================================

create extension if not exists pgcrypto;   -- gen_random_uuid(), digest()
create extension if not exists citext;     -- case-insensitive emails/domains

create schema if not exists sci;
comment on schema sci is 'SCI AI Operating Team. All agent data lives here (not in public, so the Supabase REST API does not expose it).';

-- ---------- Enumerations ----------
create type sci.agent_name as enum ('sales','social','customer_service','exec_assistant','sender','owner','system');
create type sci.prospect_stage as enum ('new','researching','researched','qualified','disqualified','drafted','contacted','replied','interested','meeting_booked','won','lost','do_not_contact');
create type sci.claim_status as enum ('verified','inferred','unknown');
create type sci.task_status as enum ('queued','in_progress','waiting_approval','blocked','done','failed','cancelled');
create type sci.outbound_status as enum ('draft','pending_approval','approved','rejected','sending','sent','failed','cancelled');
create type sci.channel as enum ('email','linkedin_message','facebook_post','instagram_post','linkedin_post','calendar_invite','telegram','other');
create type sci.approval_decision as enum ('pending','approved','rejected','edited_and_approved','expired');
create type sci.run_status as enum ('started','succeeded','failed','skipped_guard','retrying','dead_letter');
create type sci.consent_basis as enum ('none','public_business_contact','inbound_inquiry','existing_relationship','explicit_opt_in');

-- ---------- Shared business knowledge (SCI itself) ----------
create table sci.business_knowledge (
  id           uuid primary key default gen_random_uuid(),
  key          text not null,                 -- e.g. 'icp', 'services', 'positioning', 'voice'
  version      int  not null default 1,
  content      text not null,
  is_active    boolean not null default true,
  approved_by  text,
  created_at   timestamptz not null default now(),
  unique (key, version)
);
create unique index business_knowledge_one_active on sci.business_knowledge(key) where is_active;

-- ---------- Clients and per-client knowledge (isolated) ----------
create table sci.clients (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  status      text not null default 'active' check (status in ('active','paused','former','test')),
  is_test     boolean not null default false,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz
);

create table sci.client_knowledge (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references sci.clients(id),
  kind        text not null check (kind in ('brand_guide','voice','content_pillars','audience','strategy','faq','offers','do_not_say','platform_access','other')),
  version     int  not null default 1,
  content     text not null,
  is_active   boolean not null default true,
  approved_by text,
  created_at  timestamptz not null default now(),
  unique (client_id, kind, version)
);
create unique index client_knowledge_one_active on sci.client_knowledge(client_id, kind) where is_active;

-- ---------- CRM ----------
create table sci.organizations (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  website       text,
  domain        citext,
  industry      text,
  city          text,
  county        text,
  state         text,
  size_estimate text,                          -- e.g. '10-50 employees (inferred)'
  social_links  jsonb not null default '{}'::jsonb,
  source        text not null,                 -- where we found them: 'manual', 'google_places', 'referral', 'inbound', 'test'
  is_test       boolean not null default false,
  client_id     uuid references sci.clients(id), -- set when the org becomes a client
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz
);
create unique index organizations_domain_uniq on sci.organizations(domain) where domain is not null and deleted_at is null;

create table sci.contacts (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid references sci.organizations(id),
  full_name       text,
  role_title      text,
  email           citext,
  phone           text,
  linkedin_url    text,
  consent_basis   sci.consent_basis not null default 'none',
  source          text not null,               -- where the contact info came from (URL or 'inbound')
  is_test         boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz
);
create unique index contacts_email_uniq on sci.contacts(email) where email is not null and deleted_at is null;

create table sci.prospects (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references sci.organizations(id),
  primary_contact_id uuid references sci.contacts(id),
  stage            sci.prospect_stage not null default 'new',
  fit_score        int check (fit_score between 0 and 100),
  fit_rationale    text,
  recommended_service text,
  owner_agent      sci.agent_name not null default 'sales',
  next_action_at   timestamptz,
  is_test          boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz,
  unique (organization_id)
);

create table sci.research_findings (
  id            uuid primary key default gen_random_uuid(),
  prospect_id   uuid not null references sci.prospects(id),
  agent_run_id  uuid,
  category      text not null,                 -- 'website','social','reviews','messaging_gap','company_facts', ...
  statement     text not null,
  status        sci.claim_status not null,
  source_url    text,
  evidence_quote text,                         -- short excerpt from the source supporting the claim
  retrieved_at  timestamptz,
  created_at    timestamptz not null default now(),
  -- The anti-fabrication rule, enforced by the database:
  constraint verified_needs_source check (
    status <> 'verified' or (source_url is not null and retrieved_at is not null and evidence_quote is not null)
  )
);

create table sci.interactions (
  id            uuid primary key default gen_random_uuid(),
  contact_id    uuid references sci.contacts(id),
  organization_id uuid references sci.organizations(id),
  direction     text not null check (direction in ('inbound','outbound','internal_note')),
  channel       sci.channel not null,
  subject       text,
  body          text,
  external_id   text,                          -- Gmail message id, etc.
  occurred_at   timestamptz not null default now(),
  created_by    sci.agent_name not null,
  created_at    timestamptz not null default now()
);
create unique index interactions_external_uniq on sci.interactions(channel, external_id) where external_id is not null;

-- ---------- Follow-up sequences ----------
create table sci.sequences (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  steps       jsonb not null,                  -- [{step:1, delay_days:0, purpose:'intro'}, ...]
  is_approved boolean not null default false,  -- owner must approve a sequence before it can run
  approved_at timestamptz,
  created_at  timestamptz not null default now()
);

create table sci.sequence_enrollments (
  id           uuid primary key default gen_random_uuid(),
  prospect_id  uuid not null references sci.prospects(id),
  sequence_id  uuid not null references sci.sequences(id),
  current_step int not null default 0,
  status       text not null default 'active' check (status in ('active','paused','completed','stopped_reply','stopped_unsubscribe')),
  next_step_at timestamptz,
  created_at   timestamptz not null default now(),
  unique (prospect_id, sequence_id)
);

-- ---------- Cross-agent task queue (clear ownership) ----------
create table sci.tasks (
  id             uuid primary key default gen_random_uuid(),
  type           text not null,                -- 'research_prospect','draft_outreach','triage_inbound','daily_brief', ...
  owner_agent    sci.agent_name not null,
  status         sci.task_status not null default 'queued',
  priority       int not null default 3 check (priority between 1 and 5),  -- 1 = urgent
  payload        jsonb not null default '{}'::jsonb,
  related_table  text,
  related_id     uuid,
  parent_task_id uuid references sci.tasks(id),
  handoff_from   sci.agent_name,
  due_at         timestamptz,
  attempts       int not null default 0,
  max_attempts   int not null default 3,
  locked_at      timestamptz,
  locked_by      text,
  last_error     text,
  dedupe_key     text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index tasks_dedupe_open on sci.tasks(dedupe_key) where dedupe_key is not null and status in ('queued','in_progress','waiting_approval','blocked');
create index tasks_queue on sci.tasks(owner_agent, status, priority, created_at);

-- ---------- Approvals and the OUTBOX ----------
create table sci.approvals (
  id                  uuid primary key default gen_random_uuid(),
  subject_table       text not null,
  subject_id          uuid not null,
  summary             text not null,          -- what the owner sees in Telegram
  decision            sci.approval_decision not null default 'pending',
  decided_by          text,
  decided_at          timestamptz,
  edit_notes          text,
  telegram_chat_id    text,
  telegram_message_id text,
  expires_at          timestamptz,
  created_at          timestamptz not null default now()
);

create table sci.outbound_actions (
  id              uuid primary key default gen_random_uuid(),
  created_by      sci.agent_name not null,
  channel         sci.channel not null,
  client_id       uuid references sci.clients(id),  -- set for client work (social posts)
  prospect_id     uuid references sci.prospects(id),
  contact_id      uuid references sci.contacts(id),
  recipient       citext,                      -- email address / handle
  subject         text,
  body            text not null,
  payload         jsonb not null default '{}'::jsonb,
  idempotency_key text not null unique,        -- duplicate prevention
  status          sci.outbound_status not null default 'draft',
  approval_id     uuid references sci.approvals(id),
  scheduled_for   timestamptz,
  sent_at         timestamptz,
  external_id     text,
  last_error      text,
  attempts        int not null default 0,
  is_test         boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index outbound_status_idx on sci.outbound_actions(status, scheduled_for);

-- ---------- Suppression (unsubscribe / do-not-contact) ----------
create table sci.suppression_list (
  id         uuid primary key default gen_random_uuid(),
  email      citext,
  domain     citext,
  reason     text not null check (reason in ('unsubscribed','bounced','complained','do_not_contact','owner_request')),
  source     text,
  added_at   timestamptz not null default now(),
  constraint one_target check ((email is not null) <> (domain is not null))
);
create unique index suppression_email_uniq on sci.suppression_list(email) where email is not null;
create unique index suppression_domain_uniq on sci.suppression_list(domain) where domain is not null;

-- ---------- Social content (Phase 4, defined now so client isolation is designed in) ----------
create table sci.content_items (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references sci.clients(id),
  platform     sci.channel not null,
  pillar       text,
  draft        text not null,
  creative_brief text,
  status       text not null default 'idea' check (status in ('idea','draft','pending_owner','pending_client','approved','scheduled','published','rejected')),
  metrics      jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ---------- Control plane ----------
create table sci.system_controls (
  id                 boolean primary key default true check (id),   -- exactly one row
  global_pause       boolean not null default false,
  sending_enabled    boolean not null default false,   -- external email etc. OFF until owner authorizes
  publishing_enabled boolean not null default false,   -- social publishing OFF until owner authorizes
  paused_agents      sci.agent_name[] not null default '{}',
  quiet_hours_start  time not null default '20:00',    -- Eastern; no notifications/sends after this
  quiet_hours_end    time not null default '08:00',
  timezone           text not null default 'America/New_York',
  owner_telegram_chat_ids text[] not null default '{}', -- allowlist for approvals and /pause
  updated_at         timestamptz not null default now(),
  updated_by         text
);

create table sci.prompts (
  id          uuid primary key default gen_random_uuid(),
  agent       sci.agent_name not null,
  name        text not null,                   -- 'prospect_research', 'outreach_draft', ...
  version     int not null,
  model       text not null default 'claude-opus-5-5',
  effort      text not null default 'medium' check (effort in ('low','medium','high','xhigh','max')),
  system_text text not null,
  output_schema jsonb,
  is_active   boolean not null default false,
  notes       text,
  created_at  timestamptz not null default now(),
  unique (agent, name, version)
);
create unique index prompts_one_active on sci.prompts(agent, name) where is_active;

-- ---------- Observability: runs, AI usage, budgets ----------
create table sci.agent_runs (
  id             uuid primary key default gen_random_uuid(),
  agent          sci.agent_name not null,
  workflow       text not null,
  task_id        uuid references sci.tasks(id),
  prompt_id      uuid references sci.prompts(id),
  status         sci.run_status not null default 'started',
  guard_reason   text,
  input_ref      jsonb not null default '{}'::jsonb,
  output_summary text,
  error          text,
  attempt        int not null default 1,
  n8n_execution_id text,
  started_at     timestamptz not null default now(),
  finished_at    timestamptz
);
create index agent_runs_recent on sci.agent_runs(agent, started_at desc);

create table sci.llm_usage (
  id                 uuid primary key default gen_random_uuid(),
  agent_run_id       uuid references sci.agent_runs(id),
  agent              sci.agent_name not null,
  model              text not null,
  input_tokens       int not null default 0,
  output_tokens      int not null default 0,
  cache_read_tokens  int not null default 0,
  cache_write_tokens int not null default 0,
  web_searches       int not null default 0,
  cost_usd           numeric(10,4) not null,
  created_at         timestamptz not null default now()
);
create index llm_usage_agent_day on sci.llm_usage(agent, created_at);

create table sci.budgets (
  agent           sci.agent_name primary key,
  daily_usd       numeric(10,2) not null,
  monthly_usd     numeric(10,2) not null,
  alert_at_pct    int not null default 80
);

-- Model price list (USD per million tokens) so cost is computed in one place.
create table sci.model_prices (
  model              text primary key,
  input_per_mtok     numeric(10,4) not null,
  output_per_mtok    numeric(10,4) not null,
  cache_read_per_mtok numeric(10,4) not null,
  web_search_per_1k  numeric(10,4) not null default 10,
  verified_on        date not null
);

-- ---------- Audit log (filled by triggers in 0003) ----------
create table sci.audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor       text not null default current_user,
  table_name  text not null,
  row_id      uuid,
  action      text not null,                   -- INSERT / UPDATE / DELETE
  before      jsonb,
  after       jsonb
);
create index audit_row on sci.audit_log(table_name, row_id, at desc);
