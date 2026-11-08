# SCI AI Operating Team

The operating system behind Strategic Creative Initiatives' AI team: the Sales Representative, Social Media Manager, Customer Service Representative, and Executive Assistant.

**How it fits together:** n8n runs the workflows → Claude does the thinking → Supabase stores everything and enforces the rules → Telegram is where Brett approves things and gets alerts.

## Safety rules enforced by the database (not by AI instructions)

- Nothing goes out without an approval from an allowlisted Telegram account.
- External sending and publishing are **OFF** until Brett explicitly turns them on.
- Anyone who unsubscribes is blocked forever (by person or by whole company), and their pending drafts are cancelled automatically.
- The same message can't be sent twice (duplicate keys).
- Test records can never be sent.
- A research finding can't be marked "verified" without a source link, a quote, and a time it was retrieved.
- Each agent has its own login and sees only what its job needs. Client data is read one client at a time.
- Daily and monthly AI budgets per agent, checked before every AI call.
- One switch pauses everything. Every change is logged and can be undone.

Run `scripts/test_local.sh` to prove all of the above (53 database tests + end-to-end n8n workflow tests).

## Folders

| Path | What it is |
|---|---|
| `dist/install.sql` | The one file to paste into Supabase (built by `scripts/build_install.sh`) |
| `supabase/migrations/` | The database design, in readable pieces |
| `supabase/seed/test_data.sql` | Fictional test prospects |
| `supabase/tests/` | Safety tests |
| `docs/SETUP.md` | Step-by-step setup for a non-technical owner |

## Status

- [x] **Task 1**: Database schema, security, audit, SCI knowledge, test data
- [x] **Task 2**: n8n guard step, error alerts, cost logging
- [x] **Task 3**: Telegram bot: approvals, /pause, /status
- [ ] **Task 4**: Sales: prospect research + qualification
- [ ] **Task 5**: Sales: outreach drafts → approval card (draft only)
