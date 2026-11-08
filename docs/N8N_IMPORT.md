# Importing the n8n workflows (Tasks 2–3)

Files are in `n8n/workflows/`. Do these **in order**.

## A. Database update (once)
Supabase → SQL Editor → new tab → paste all of `dist/update_0009_telegram_bot.sql` → **Run**.
Expected: "Success. No rows returned".

## B. Import a workflow (repeat for each file)
1. n8n → **Create workflow**.
2. Click the **⋯** menu (top right) → **Import from File…** → choose the file.
3. Any node with a red warning needs its credential picked: double-click it → choose the
   credential with the matching name (e.g. **SCI DB – Approver**, **SCI – Telegram Bot**) → close.
4. Click **Save**.

| File | After importing |
|---|---|
| `01_error_alerts.json` | Just save. It runs automatically whenever another workflow fails. |
| `02_telegram_bot.json` | ⋯ → **Settings** → *Error workflow* = **SCI – Error Alerts** → Save. Then **Publish / Activate** it. |
| `03_test_approval_card.json` | Save. Click **Execute workflow** to send yourself a TEST approval card. |

## C. Try it
- In Telegram, send your bot `/status` → you get a status report.
- Run the test card workflow → tap **✅ Approve** → the card updates to "Approved".
- Send `/pause`, then `/status` (shows PAUSED), then `/resume`.

Nothing here can send email: sending is OFF and test drafts can never be sent.

## D. Sales research (Task 4)
1. Supabase: run `dist/update_0010_sales_research.sql`, then `dist/first_real_prospects.sql`.
2. n8n: import `04_sales_research.json`. On **Call Claude**, the credential must be **SCI – Claude (Sales)**.
   Settings → Error workflow = **SCI – Error Alerts**.
3. Click **Execute workflow** once to research ONE prospect (~$0.20–0.50). A summary arrives in Telegram.
4. When you're happy with the quality, **Publish** it: it then runs hourly 8 AM–7 PM ET, one prospect per run,
   and stops automatically at the daily ($1.50) and monthly budgets.

## E. Prospect sourcing (/prospect + weekly discovery)
1. Supabase: run `dist/update_0011_prospect_sourcing.sql`.
2. Replace the Telegram bot: in n8n, open **SCI – Telegram Bot** → ⋯ → **Archive** (or Delete) FIRST
   (only one workflow can listen to the bot), then import the new `02_telegram_bot.json`.
3. Replace research: archive **SCI – Sales: Research Prospects**, import the new `04_sales_research.json`.
4. Import `05_weekly_discovery.json`.

**Credentials (n8n may pick the wrong one automatically; check every database step):**

| Workflow | Database steps use | Other steps |
|---|---|---|
| Telegram Bot | **SCI DB – Approver** | Telegram steps: SCI – Telegram Bot |
| Research Prospects | **SCI DB – Sales** | Call Claude: SCI – Claude (Sales); Telegram: SCI – Telegram Bot |
| Weekly Discovery | **SCI DB – Sales** | Call Claude: SCI – Claude (Sales); Telegram: SCI – Telegram Bot |

Each: ⋯ → Settings → Error workflow = **SCI – Error Alerts**, then Publish.

## F. Outreach drafts (Task 5)
1. Supabase: run `dist/update_0013_outreach_drafts.sql`, then your private `dist/local_sender_details.sql`
   (signature + mailing address; not stored in GitHub).
2. n8n: import `06_outreach_drafts.json`. Database steps → **SCI DB – Sales**; Call Claude → **SCI – Claude (Sales)**.
   Error workflow → SCI – Error Alerts. Publish. It drafts one email per hour (8 AM–7 PM ET) for qualified prospects.
3. Each draft arrives in Telegram with ✅ Approve / ❌ Reject. Approving marks it ready; sending stays OFF.

## G. Weekly Help Wanted scan (read-only)
1. Supabase: run `dist/update_0017_help_wanted.sql`.
2. Replace the Telegram bot again (archive old, import new `02_telegram_bot.json`, database step → SCI DB – Approver).
3. Import `07_help_wanted_scan.json`: database steps → SCI DB – Sales; Call Claude → SCI – Claude (Sales).
   Error workflow → SCI – Error Alerts. Publish. Runs Thursdays 9:40 AM ET.
The scan never posts anything. You reply yourself from your own account, then tap 👍 I replied.
