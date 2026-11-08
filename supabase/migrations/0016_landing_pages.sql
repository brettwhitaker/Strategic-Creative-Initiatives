-- =====================================================================
-- SCI AI Operating Team — 0016 New service: landing pages (owner delegated pricing; market-based)
-- =====================================================================
select sci.set_knowledge('services', replace(
  (select content from sci.business_knowledge where key = 'services' and is_active),
  'SUPPORTING SERVICES:',
  'CORE OFFER C — Websites:
  - Landing page (one-page website: design, build AND copywriting included): from $650; typically
    $650-$1,200 depending on sections and writing scope. Mobile-friendly, fast, contact links.
  - Hosting & care plan: $29/month (hosting, security certificate, up to 30 minutes of small edits per
    month). The client always owns their own domain name.
SUPPORTING SERVICES:') || E'\nWEBSITE RULE: recommend a landing page when a business has no website, only a social page, or a site that is\nbroken, clearly outdated or hard to use on a phone, AND the business seems able to invest. Lead with the words:\nclear copy is what SCI is best at.\n');

select left(content, 400) as services_preview from sci.business_knowledge where key = 'services' and is_active;
