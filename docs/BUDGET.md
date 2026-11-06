# Budget Plan: Start Lean, Grow With Results

**Rule:** limits are never raised automatically. When a milestone is reached, the Executive Assistant's weekly briefing will *suggest* the next tier. You decide, and you raise it with one command.

| Tier | When | AI usage cap / month | All-in target / month | What it unlocks |
|---|---|---|---|---|
| **0: Trial (now)** | Starting out | **$25** | **≤ $100** | ~50–60 researched prospects a month, outreach drafts, approvals |
| **1: Traction** | 3+ interested replies **or** first meeting booked from the system | $40 | ~$115 | More prospects; Customer Service inbox triage |
| **2: First win** | First signed client sourced by the system | $60 | ~$135 | Social Media Manager for Ideal Move + new client; follow-up sequences |
| **3: Paying for itself** | System-sourced revenue ≥ 5× monthly cost for 2 months | $100+ | owner's choice | Executive Assistant briefings, Replit dashboard, higher volume |

## How we know if it's working (tracked automatically from Phase 2)
- Prospects researched → qualified → contacted → replied → meeting → won
- Cost per qualified prospect and cost per meeting booked
- Revenue from clients the system found, compared with total system cost

## To raise a limit (owner only, Supabase SQL editor)
```sql
update sci.system_controls set monthly_total_cap_usd = 40;
update sci.budgets set monthly_usd = 25, daily_usd = 2.50 where agent = 'sales';
```
Then raise the Anthropic console spend limit to match (about $5 above the new cap).

## Ways to stay under $100 during the trial
- **Replit:** not needed until Tier 3. Cancelling saves ~$20–25 a month.
- **Supabase:** Pro ($25) includes daily backups. The free plan would work while we only have test data, but upgrade before real prospect data builds up.
- **n8n:** schedules run hourly, not every minute, to stay inside the Starter plan's monthly run allowance.
- **AI:** research runs overnight in batch mode where supported (about half price), shared knowledge is cached, and web searches are capped per prospect.
