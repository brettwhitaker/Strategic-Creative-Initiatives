# Setup Guide: Database (Task 1)

About 15 minutes. You'll copy and paste three things into Supabase. Nothing here sends anything outside the system.

## Step 1: Install the database

1. Open your Supabase project → **SQL Editor** (left sidebar) → **New query**.
2. Open `dist/install.sql`, copy **all** of it, paste it in, and click **Run**.
   You should see "Success. No rows returned". If you see an error, stop and send it to me. The install is all-or-nothing, so a failed run leaves nothing half-done.
3. New query → paste all of `dist/test_data.sql` → **Run**. This loads 5 **fictional** test prospects. They use made-up `.test` email addresses that can't receive mail, and the database refuses to ever send them.

> Leave **Settings → API → Exposed schemas** as it is. The agent data lives in a private `sci` schema that isn't reachable from the public internet API.

## Step 2: Create the agent logins

Each agent gets its own login, so a mistake or a compromise in one can't touch another's data. Make up a **long random password** for each (a password manager can generate them) and save them in your password manager. Never put them in a chat or a document.

In a new SQL query, replace each `CHANGE_ME_...` and run:

```sql
alter role agent_sales            login password 'CHANGE_ME_1';
alter role agent_customer_service login password 'CHANGE_ME_2';
alter role agent_social           login password 'CHANGE_ME_3';
alter role agent_exec_assistant   login password 'CHANGE_ME_4';
alter role agent_sender           login password 'CHANGE_ME_5';
alter role sci_approver           login password 'CHANGE_ME_6';
```

For Phase 1 you only need **agent_sales** and **sci_approver** connected to n8n. Leave the others without logins until their phase if you prefer.

## Step 3: Allow your Telegram account to approve

1. In Telegram, message **@userinfobot**. It replies with your numeric ID (for example `123456789`).
2. Run (with your number):

```sql
update sci.system_controls set owner_telegram_chat_ids = array['123456789'];
```

Later, if your partner should be able to approve too, add their ID: `array['123456789','987654321']`.

## Step 4: Connect n8n to the database (one credential per agent)

In Supabase, click **Connect** (top of the project page) → **Session pooler**. Note the host (looks like `aws-0-us-east-1.pooler.supabase.com`) and your project reference (the `xxxx` in `postgres.xxxx`).

In n8n → **Credentials → Add credential → Postgres**:

| Field | Value |
|---|---|
| Host | the pooler host from above |
| Database | `postgres` |
| User | `agent_sales.<your-project-ref>` |
| Password | agent_sales password |
| Port | `5432` |
| SSL | `require` |

Name it **"SCI DB – Sales"**. Repeat with `sci_approver.<project-ref>` and name it **"SCI DB – Approver"**.

## Step 5: Set a hard spending limit at Anthropic (backup safety net)

The database already stops all agents once **$25 of AI usage** is reached in a month. As a second, independent safety net:

1. Go to **console.anthropic.com → Settings → Limits** (or Billing).
2. Set a **monthly spend limit of $30**.
3. Turn **off auto-reload** of credits. Then if anything ever went wrong, the most you could lose is your remaining credit balance.

> Already installed `install.sql` before this update? Run `dist/upgrade_if_already_installed.sql` instead of reinstalling.

## Step 6: Check it worked

Run in the SQL editor:

```sql
select * from sci.system_controls;                 -- sending_enabled and publishing_enabled must be FALSE
select key from sci.business_knowledge;            -- 7 rows: positioning, icp, services, ...
select o.name, p.stage from sci.prospects p join sci.organizations o on o.id = p.organization_id;  -- 5 TEST rows
select * from sci.guard_check('sales');            -- ok = true
```

## Everyday controls (owner only, from the SQL editor)

| Want to… | Run |
|---|---|
| Stop everything immediately | `update sci.system_controls set global_pause = true;` |
| Resume | `update sci.system_controls set global_pause = false;` |
| Pause one agent | `update sci.system_controls set paused_agents = array['sales']::sci.agent_name[];` |
| Block someone forever | `insert into sci.suppression_list(email, reason) values ('x@y.com','do_not_contact');` |
| Block a whole company | `insert into sci.suppression_list(domain, reason) values ('company.com','do_not_contact');` |
| Change the total monthly AI limit | `update sci.system_controls set monthly_total_cap_usd = 25;` |
| Change a budget | `update sci.budgets set daily_usd = 5 where agent = 'sales';` |
| See today's AI spend | `select agent, sum(cost_usd) from sci.llm_usage where created_at > current_date group by 1;` |
| Update SCI knowledge (keeps old versions) | `select sci.set_knowledge('services', 'new text…');` |
| Undo a change | find it in `sci.audit_log`, then `select sci.restore_row(<audit id>);` |
| Remove test data | `select sci.purge_test_data();` |

`/pause` and `/resume` from Telegram arrive in Task 3. **Turning on real sending is deliberately not available from Telegram.** It's a SQL command only you can run, and we'll do it together in Phase 2.
