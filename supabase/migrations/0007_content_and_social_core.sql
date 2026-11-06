-- =====================================================================
-- SCI AI Operating Team — 0007
-- Owner clarification: content writing/strategy AND social media management
-- are both core offers. Agent recommends whichever matches the observed gap.
-- =====================================================================

select sci.set_knowledge('positioning', $kb$
Strategic Creative Initiatives LLC (SCI) — marketing and communications agency.
Tagline: "Clarify Your Message. Strengthen Your Story. Grow Your Impact."
Owner and point of contact: Brett.
TWO CORE STRENGTHS, offered together or separately:
  1. CONTENT WRITING AND CONTENT STRATEGY — Brett's foundation as a writer and strategist.
  2. SOCIAL MEDIA MANAGEMENT — hands-on, ongoing work Brett does today, including for SCI itself
     and for a local moving concierge and resettlement company (an active client).
SCI helps businesses that know they need to communicate better — with their clients or internally —
through strong written content, consistent and strategic social media, clear messaging, and an
overarching communication strategy. Good social media starts with good writing; SCI does both.
PROOF POINT RULE: You may say Brett "currently manages social media for a Northeast Florida moving
concierge company." Do NOT name the client unless the owner has confirmed permission.
$kb$);

select sci.set_knowledge('icp', $kb$
IDEAL CLIENT PROFILE
- Small to midsize businesses: local service providers, professional services firms, and growing
  companies that lack dedicated marketing, content, social media, or communications support.
- Established (customers, reviews, or a track record) and able to invest in professional services.
- TOP PRIORITY: businesses with visible CONTENT or SOCIAL MEDIA gaps (either one qualifies):
  Content / messaging gaps:
    * Website copy that is thin, generic, outdated, jargon-heavy, or doesn't explain the value clearly
    * No blog, or a blog not updated in 6+ months; no articles, guides, FAQs, or resources
    * No email newsletter or email capture; or an irregular newsletter
    * Leaders with expertise but no thought-leadership presence (LinkedIn posts, articles)
    * No case studies, client stories, or testimonials; inconsistent voice across channels
    * Growing teams (hiring, multiple locations) likely to need internal communications
  Social media gaps:
    * Profiles inactive for 60+ days, or posting irregularly
    * Missing from platforms their customers clearly use (e.g., Facebook/Instagram for local
      consumer services, LinkedIn for professional and B2B services)
    * Profiles that are incomplete, off-brand, or inconsistent with the website
    * Posts with weak captions, no clear message or call to action, or little engagement
    * Unanswered comments or reviews
- Especially strong fit: businesses where trust and relationships drive buying decisions —
  professional services (law, accounting/CPA, financial advisory, insurance, consulting),
  healthcare and wellness practices, real estate and relocation/moving-related services,
  home services, hospitality and local retail, B2B service companies, and nonprofits.
- Growth potential (hiring, expanding, new services/locations, recent launches) increases priority.
GEOGRAPHY
- Primary: Northeast Florida — Jacksonville (Duval), Clay County, Ponte Vedra, St. Augustine (St. Johns).
- Open to clients nationwide.
LIKELY POOR FIT (lower score or disqualify)
- Businesses with an in-house marketing/social team or a clearly active agency relationship.
- Franchise locations whose marketing is controlled by corporate.
- Other marketing/communications/content/social agencies (competitors).
- Businesses with no evident ability to invest.
$kb$);

select sci.set_knowledge('services', $kb$
SCI SERVICES AND PRICING (quote only these; never invent prices or discounts)
CORE OFFER A — Content Writing and Content Strategy (custom pricing):
  blog articles, website content, newsletters/email content, LinkedIn and thought-leadership
  ghostwriting, case studies and client stories, internal communications, content calendars,
  content strategy. PRICES NOT YET SET BY OWNER: never quote a price; offer a conversation.
CORE OFFER B — Social Media:
  - Social Media Foundational Build: $999 — establishing or optimizing up to three platforms.
  - Ongoing Social Media Management: starting at $750 every four weeks.
SUPPORTING SERVICES:
  - Website Copywriting and Messaging: custom pricing.
  - Email Marketing Templates: starting at $150.
  - Communication Strategy and Consulting: custom pricing.
CHOOSING WHAT TO RECOMMEND — match the gap you actually observed:
  - Mostly social gaps (inactive, missing platforms, inconsistent profiles) -> Foundational Build
    (if profiles need setup/cleanup) or Ongoing Social Media Management (if they exist but lack
    consistency).
  - Mostly writing/messaging gaps -> Content Writing/Strategy or Website Copywriting.
  - Both -> lead with the strongest observed gap; mention that SCI can handle content and social
    together. Recommend ONE primary service per prospect, optionally one secondary.
Outreach should generally NOT lead with price; offer a conversation.
$kb$);

select sci.set_knowledge('fit_rubric', $kb$
FIT SCORE (0-100). Only VERIFIED findings may earn full points; inferred findings at most half.
1. Content OR social media gap (0-40) — the most important factor. Score the stronger of the two
   (content/messaging gaps or social media gaps), plus up to 5 bonus points (within the 40) if both
   are present. See ICP for examples of each.
2. Relationship/trust-driven buying (0-10): industries where expertise, trust, and visibility win
   clients (see ICP "especially strong fit").
3. Ability to invest (0-20): years operating, team size, multiple locations, review volume, pricing level.
4. Growth signals (0-15): hiring, new location/service, recent launch, press.
5. Geography (0-10): Northeast Florida = 10; elsewhere in Florida = 5; elsewhere in the US = 4.
6. Reachability (0-5): public business email or contact form, identifiable decision maker.
THRESHOLDS: 65+ = qualified (draft outreach). 45-64 = owner review. Under 45 = disqualified.
Apply "poor fit" rules from the ICP before scoring. Always list which findings drove the score,
name the single most compelling opportunity, and state the recommended primary service.
$kb$);
