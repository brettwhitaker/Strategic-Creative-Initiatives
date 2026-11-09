-- =====================================================================
-- Client: Ideal Move (move management, Northeast Florida). Knowledge v1 drafted by Claude from the
-- posts Brett shared (Nov 2026). Brett: review and correct anything marked "(confirm)".
-- Public-facing SCI material never names this client; this private knowledge base does.
-- =====================================================================
do $$
declare cid uuid;
begin
  select id into cid from sci.clients where name = 'Ideal Move' and deleted_at is null;
  if cid is null then
    insert into sci.clients(name, status, notes) values ('Ideal Move', 'active', 'Social media client (Meta Business Suite + LinkedIn).')
    returning id into cid;
  end if;

  insert into sci.client_knowledge(client_id, kind, content, approved_by) values
  (cid, 'brand_guide', $k$
Ideal Move is a Northeast Florida senior move management company: "making downsizing and senior relocation a
positive experience." They help clients before, during and after a move. Brand colors: teal/green and navy
(from their graphics). Tone: warm, calm, organized, reassuring.
$k$, 'owner (draft by Claude, please review)'),

  (cid, 'offers', $k$
Services (from their posts and banner):
- Downsizing and organizing; sales, donations and trash removal; estate cleanout (confirm wording)
- Packing (protecting and preparing belongings) and unpacking (unboxing and putting everything away)
- Space planning / planning your new space (floor plans)
- Vendor coordination: arranging all necessary vendors; project management
- Move-day support
- Home setup: organizing and arranging the new space so it's "live-in ready"
Never state prices, timelines or guarantees in posts.
$k$, 'owner (draft by Claude, please review)'),

  (cid, 'audience', $k$
- Older adults downsizing or relocating, often to senior or active-adult communities (e.g., new communities
  like Fleet Landing Nocatee) and their adult children who help coordinate the move.
- Individuals and families going through a major life transition who feel overwhelmed by a move.
- Referral partners (mainly on LinkedIn): senior living communities, realtors, estate and elder-law attorneys,
  financial planners, care managers. (confirm)
Area: Northeast Florida (Jacksonville, St. Johns County, Nocatee, Ponte Vedra). (confirm exact service area)
$k$, 'owner (draft by Claude, please review)'),

  (cid, 'voice', $k$
VOICE: warm, reassuring and practical; "we" voice; speaks to the feelings behind a move, not just logistics.
- Opens with a clear hook, often a contrast or a question:
  "Moving into a new home is one thing. Feeling at home is another." /
  "Most people know what a moving company does. But what exactly does a move manager do? 🤔"
- Short paragraphs (1-3 sentences), plain words, gentle rhythm.
- Mentions services naturally inside the story, not as a sales list (a short list is fine occasionally).
- 1-3 emojis per post, from the brand's usual set: 🏡 💚 ✨ 🤔 (LinkedIn: 0-1).
- Ends with a soft, friendly call to action, e.g. "Need a little help getting settled? We'd love to make your
  next move easier!", "Curious about what professional move management could look like for you, your family,
  or someone you work with? We'd love to connect!", "You can also message us here or through our website."
- Event posts thank hosts and partners by name (only real ones) and focus on conversations and connection.
$k$, 'owner (draft by Claude, please review)'),

  (cid, 'content_pillars', $k$
1. Feeling at home: finished-home showcases and the emotional payoff of a settled home (needs real photos).
2. Explaining move management: what a move manager does, how it differs from movers, how the process works.
3. Practical tips: downsizing, packing, where to start unpacking, setting up a new space safely and comfortably.
4. Community and partners: events, senior communities, partner shout-outs (ONLY real events/partners Brett provides).
5. Team and behind the scenes: the people, the care, a day on a move (with permission and real photos).
6. Client stories and testimonials: ONLY real ones Brett provides with the client's permission.
Rotate pillars; in a 3-post week use three different pillars.
$k$, 'owner (draft by Claude, please review)'),

  (cid, 'do_not_say', $k$
- No invented stories, testimonials, reviews, numbers, events, partners or promotions.
- No prices, guarantees or specific timelines.
- Don't say "elderly"; prefer "older adults", "seniors" or simply "clients" and "families".
- Never name clients, show identifiable homes/addresses, or use photos of people without permission.
- No legal, financial or medical advice (point people to the right professional instead).
- Don't use urgency or fear ("Don't wait!", "before it's too late").
$k$, 'owner (draft by Claude, please review)'),

  (cid, 'strategy', $k$
Platforms: Facebook + Instagram via Meta Business Suite, and LinkedIn. (confirm)
Goals: build trust with families and referral partners, explain the value of move management, keep the brand
consistently visible. Calls to action: message on the platform or through their website. Hashtags: local +
topic (e.g. #JacksonvilleFL #StJohnsCounty #MoveManagement #Downsizing #SeniorLiving #HomeSetup), 3-6 per post
on Facebook/Instagram, 0-3 on LinkedIn.
$k$, 'owner (draft by Claude, please review)'),

  (cid, 'other', $k$
PAST POSTS (style examples, written by Brett for Ideal Move):

[1] Last week, the Ideal Move team had a wonderful time at the Fleet Landing Expo!
We enjoyed connecting with future Fleet Landing Nocatee residents and their families as they begin planning for
this exciting new community, coming in 2027.
With more than 100 attendees and so many great vendors in the room, it was a great opportunity to answer
questions, share resources, and talk about how thoughtful planning can make a move feel less overwhelming.
At Ideal Move, we help clients before, during, and after the move with downsizing, packing, space planning,
vendor coordination, move-day support, and full home setup.
Thank you to Fleet Landing WELLInspired Living for hosting such a great event. We were grateful to be part of
the conversation!

[2] Moving into a new home is one thing. Feeling at home is another. 🏡💚
It's the familiar furniture, favorite décor, and all those little details that make a new space feel like home.
Here's a look inside a recently settled home where everything is coming together, from the living room and
kitchen to the finishing touches that make each space feel comfortable and familiar.
At Ideal Move, we handle the unpacking, organizing, and home setup so our clients spend less time surrounded by
boxes and more time enjoying their new surroundings.
Because the best part of moving isn't getting everything through the front door. It's finally feeling at home again.
✨ Need a little help getting settled? We'd love to make your next move easier!

[3] Most people know what a moving company does. But what exactly does a move manager do? 🤔
The difference goes well beyond packing and unpacking.
Moving involves countless decisions, competing priorities, and details that can easily become overwhelming,
especially when you're balancing a career, family responsibilities, or a major life transition.
At Ideal Move, we help manage the entire process, from preparing belongings and coordinating moving-day details
to organizing and setting up a new home.
Our role is both hands-on and advisory. We're there to help clients make informed decisions, stay organized, and
navigate the process with someone experienced by their side.
Because a successful move isn't just about getting everything from one address to another. It's about making the
transition into your next chapter as smooth as possible.
🏡 Curious about what professional move management could look like for you, your family, or someone you work
with? We'd love to connect!

[4] Moving into a new home is exciting! But getting settled can feel like a project of its own.
Once the moving truck pulls away, there's still plenty to do. Boxes need unpacking, furniture needs arranging,
and everyday essentials need to find their place.
One of the best ways to make the process more manageable is to prioritize the spaces you'll use most.
Start with the kitchen and bedroom, then work your way through the living areas before focusing on the
finishing touches that make a house feel like home.
Of course, you don't have to tackle it all yourself.
At Ideal Move, we help individuals and families manage the details of moving, from packing and unpacking to
organizing and setting up their new spaces.
Our mission is to help make the transition into your new home feel more organized, manageable, and stress-free.
🏡 Swipe through for a few tips on where to start!
You can also message us here or through our website to ask any questions about our services!
$k$, 'owner (from Brett''s published posts)')
  on conflict do nothing;

  -- Default schedule (confirm): Tue Facebook+Instagram, Wed LinkedIn, Fri Facebook+Instagram.
  -- The next week's plan is drafted on Thursdays, so Brett has time to review before Tuesday.
  perform sci.set_social_schedule('Ideal Move',
    '[{"dow":2,"platforms":["facebook","instagram"]},{"dow":3,"platforms":["linkedin"]},{"dow":5,"platforms":["facebook","instagram"]}]'::jsonb, 4);
end $$;

select c.name, count(k.*) as knowledge_entries, s.posting_slots
  from sci.clients c left join sci.client_knowledge k on k.client_id = c.id and k.is_active
  left join sci.client_social_settings s on s.client_id = c.id
 where c.name = 'Ideal Move' group by c.name, s.posting_slots;
