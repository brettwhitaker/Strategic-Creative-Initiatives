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
