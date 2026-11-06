-- =====================================================================
-- SCI AI Operating Team — 0006
-- 1) Owner's core strength = content writing + content strategy: knowledge v2.
-- 2) Total monthly AI cost cap across ALL agents (owner budget: ~$100/mo all-in,
--    of which roughly $20-25 is available for AI usage).
-- =====================================================================

-- ---------- Safe knowledge versioning helper (owner uses this to edit knowledge) ----------
create or replace function sci.set_knowledge(p_key text, p_content text, p_approved_by text default 'owner')
returns int language plpgsql as $$
declare v int;
begin
  select coalesce(max(version), 0) + 1 into v from sci.business_knowledge where key = p_key;
  update sci.business_knowledge set is_active = false where key = p_key and is_active;
  insert into sci.business_knowledge(key, version, content, approved_by) values (p_key, v, p_content, p_approved_by);
  return v;
end $$;
revoke all on function sci.set_knowledge(text, text, text) from public;

-- ---------- Total AI spend cap (all agents combined) ----------
alter table sci.system_controls add column if not exists monthly_total_cap_usd numeric(10,2) not null default 25.00;

create or replace function sci.guard_check(p_agent sci.agent_name, p_estimated_usd numeric default 0.50)
returns table(ok boolean, reason text)
language plpgsql stable security definer set search_path = sci, public as $$
declare
  c sci.system_controls%rowtype;
  b sci.budgets%rowtype;
  spent_today numeric; spent_month numeric; spent_total_month numeric;
  tz text;
begin
  select * into c from sci.system_controls where id;
  tz := coalesce(c.timezone, 'America/New_York');
  if c.global_pause then return query select false, 'global_pause'; return; end if;
  if p_agent = any(c.paused_agents) then return query select false, 'agent_paused'; return; end if;

  select * into b from sci.budgets where agent = p_agent;
  if b.agent is null then return query select false, 'no_budget_configured'; return; end if;

  select coalesce(sum(cost_usd),0) into spent_today from sci.llm_usage
   where agent = p_agent and (created_at at time zone tz)::date = (now() at time zone tz)::date;
  select coalesce(sum(cost_usd),0) into spent_month from sci.llm_usage
   where agent = p_agent and date_trunc('month', created_at at time zone tz) = date_trunc('month', now() at time zone tz);
  select coalesce(sum(cost_usd),0) into spent_total_month from sci.llm_usage
   where date_trunc('month', created_at at time zone tz) = date_trunc('month', now() at time zone tz);

  if spent_total_month + p_estimated_usd > c.monthly_total_cap_usd then
    return query select false, format('TOTAL_monthly_cap_reached (%s of %s)', spent_total_month, c.monthly_total_cap_usd); return; end if;
  if spent_today + p_estimated_usd > b.daily_usd then
    return query select false, format('daily_budget_exceeded (%s of %s)', spent_today, b.daily_usd); return; end if;
  if spent_month + p_estimated_usd > b.monthly_usd then
    return query select false, format('monthly_budget_exceeded (%s of %s)', spent_month, b.monthly_usd); return; end if;
  return query select true, 'ok';
end $$;

-- Lean per-agent budgets for the trial period (sum stays under the $25 total cap).
-- Agents not yet built get small placeholder budgets.
update sci.budgets set daily_usd = 1.50, monthly_usd = 15.00 where agent = 'sales';
update sci.budgets set daily_usd = 0.50, monthly_usd =  3.00 where agent in ('customer_service','social','exec_assistant');
update sci.budgets set daily_usd = 0.25, monthly_usd =  1.00 where agent = 'system';

-- ---------- Knowledge v2: content writing + strategy as the lead offer ----------
select sci.set_knowledge('positioning', $kb$
Strategic Creative Initiatives LLC (SCI) — marketing and communications agency.
Tagline: "Clarify Your Message. Strengthen Your Story. Grow Your Impact."
Owner and point of contact: Brett.
CORE STRENGTH: Brett is first and foremost a CONTENT WRITER AND CONTENT STRATEGIST. Lead with this.
SCI helps businesses that know they need to communicate better — with their clients or internally —
through strong written content, clear messaging, content strategy, consistent social media, and
overarching communication strategy. Social media and branding work are built on that writing foundation.
$kb$);

select sci.set_knowledge('icp', $kb$
IDEAL CLIENT PROFILE
- Small to midsize businesses: local service providers, professional services firms, and growing
  companies that lack dedicated marketing, content, or communications support.
- Established (customers, reviews, or a track record) and able to invest in professional services.
- TOP PRIORITY: businesses with CONTENT and MESSAGING gaps, where Brett's writing and content strategy
  would make a visible difference, in any of these forms:
    * Website copy that is thin, generic, outdated, jargon-heavy, or doesn't explain the value clearly
    * No blog, or a blog not updated in 6+ months; no articles, guides, FAQs, or resources
    * No email newsletter or email capture; or a newsletter that is irregular
    * Leaders with expertise but no thought-leadership presence (LinkedIn posts, articles)
    * No case studies, client stories, or testimonials that tell their story
    * Inconsistent voice across website, social, and email
    * Growing teams (hiring, multiple locations) likely to need internal communications
    * Social media that exists but has weak or inconsistent written content
- Especially strong fit: businesses where trust and expertise drive buying decisions and content
  directly helps win clients — professional services (law, accounting/CPA, financial advisory,
  insurance, consulting), healthcare and wellness practices, real estate and relocation-related
  services, home services with premium positioning, B2B service companies, and nonprofits.
- Growth potential (hiring, expanding, new services/locations, recent launches) increases priority.
GEOGRAPHY
- Primary: Northeast Florida — Jacksonville (Duval), Clay County, Ponte Vedra, St. Augustine (St. Johns).
- Open to clients nationwide (content work is easily delivered remotely).
LIKELY POOR FIT (lower score or disqualify)
- Businesses with an in-house marketing/content team or a clearly active agency relationship.
- Franchise locations whose marketing is controlled by corporate.
- Other marketing/communications/content agencies (competitors).
- Businesses with no evident ability to invest.
$kb$);

select sci.set_knowledge('services', $kb$
SCI SERVICES AND PRICING (quote only these; never invent prices or discounts)
LEAD OFFER — Content Writing and Content Strategy (custom pricing):
  blog articles, website content, newsletters/email content, LinkedIn and thought-leadership
  ghostwriting, case studies and client stories, internal communications, content calendars and
  content strategy. PRICES NOT YET SET BY OWNER: never quote a price for these; offer a conversation.
- Website Copywriting and Messaging: custom pricing.
- Communication Strategy and Consulting: custom pricing.
- Email Marketing Templates: starting at $150.
- Social Media Foundational Build: $999 — establishing or optimizing up to three platforms.
- Ongoing Social Media Management: starting at $750 every four weeks.
Choose the recommended service from the gap you actually observed. When the gap is about writing,
messaging, or content, recommend content writing/strategy or website copywriting first.
Outreach should generally NOT lead with price; offer a conversation.
$kb$);

select sci.set_knowledge('fit_rubric', $kb$
FIT SCORE (0-100). Only VERIFIED findings may earn full points; inferred findings at most half.
1. Content and messaging gap (0-40) — the most important factor. Examples: generic or unclear
   website copy, no clear value proposition, blog absent or stale 6+ months, no newsletter or email
   capture, no case studies/testimonials, leaders' expertise not visible on LinkedIn, inconsistent
   voice across channels, weak written content on social.
2. Content-driven buying (0-10): industries where expertise and trust content wins clients
   (professional services, healthcare, financial, real estate/relocation, B2B, premium home services).
3. Ability to invest (0-20): years operating, team size, multiple locations, review volume, pricing level.
4. Growth signals (0-15): hiring, new location/service, recent launch, press.
5. Geography (0-10): Northeast Florida = 10; elsewhere in Florida = 5; elsewhere in the US = 4.
6. Reachability (0-5): public business email or contact form, identifiable decision maker.
THRESHOLDS: 65+ = qualified (draft outreach). 45-64 = owner review. Under 45 = disqualified.
Apply "poor fit" rules from the ICP before scoring. Always list which findings drove the score and
name the single most compelling content opportunity.
$kb$);
