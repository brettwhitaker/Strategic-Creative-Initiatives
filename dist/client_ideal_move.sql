-- =====================================================================
-- Client: Ideal Move (move management, Northeast Florida). Knowledge v1 drafted by Claude from the
-- posts Brett shared (Nov 2026); second audience (busy professionals / younger families) added at Brett's request. Brett: review and correct anything marked "(confirm)".
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
Ideal Move is a Northeast Florida move management company. Known for senior move management ("making downsizing
and senior relocation a positive experience"), and growing a second focus: busy professionals and younger families
who want their move handled and their new home set up exactly how they like it. They help clients before, during
and after a move. Brand colors: teal/green and navy
(from their graphics). Tone: warm, calm, organized, reassuring.
$k$, 'owner (draft by Claude, please review)'),

  (cid, 'offers', $k$
Services (from their posts and banner):
- Downsizing and organizing; sales, donations and trash removal; estate cleanout (confirm wording)
- Packing (protecting and preparing belongings) and unpacking (unboxing and putting everything away)
- Space planning / planning your new space (floor plans)
- Vendor coordination: arranging all necessary vendors; project management
- Move-day support (can include packing, the move and complete setup in a single day)
- Home setup: organizing and arranging the new space so it's "live-in ready": beds made, kitchen organized, art
  placed, TV hung, favorite pieces displayed, balcony/patio set up, rugs vacuumed, furniture polished, and helpful
  notes left so clients can find everything
- Internal moves within a community (e.g., to a different residence in the same senior community)
Never state prices, timelines or guarantees in posts.
$k$, 'owner (draft by Claude, please review)'),

  (cid, 'audience', $k$
TWO CORE AUDIENCES (keep both; never lose the older audience they serve so well):
A. Older adults downsizing or relocating, often to senior or active-adult communities (e.g., new communities
   like Fleet Landing Nocatee), and the adult children who help coordinate the move. What they want: calm, care,
   patience, someone trustworthy handling the details and decisions.
B. Busy professionals and younger families with the means to pay for convenience: relocating for work, juggling
   careers and kids, building or buying in new communities. What they want: their time back, and to walk into a
   finished home that's unpacked and set up exactly how they like it.
Also: individuals and families going through any major life transition who feel overwhelmed by a move.
Referral partners (mainly on LinkedIn): senior living communities, elder-law and estate attorneys, financial
planners and care managers (audience A); realtors, relocation specialists, HR/corporate relocation contacts and
new-home builders (audience B).
Area: Jacksonville and North Florida (their own wording), including St. Johns County, Nocatee and Ponte Vedra.
Their own summary: "professional move management, unpacking, organizing, and home setup for seniors, families, and
busy professionals moving throughout Jacksonville and North Florida." 
$k$, 'owner (draft by Claude, please review)'),

  (cid, 'voice', $k$
VOICE: warm, reassuring and practical; "we" voice; speaks to the feelings behind a move, not just logistics.
- Same warmth for both audiences, different emphasis: posts for older adults lead with calm, care and support;
  posts for busy professionals and young families lead with time saved, convenience and coming home to a finished,
  personalized space. Never make either audience feel like an afterthought.
- Opens with a clear hook, often a contrast or a question:
  "Moving into a new home is one thing. Feeling at home is another." /
  "Most people know what a moving company does. But what exactly does a move manager do? 🤔"
- Short paragraphs (1-3 sentences), plain words, gentle rhythm.
- Mentions services naturally inside the story, not as a sales list (a short list is fine occasionally).
- 1-3 emojis per post, from the brand's usual set: 🏡 💚 ✨ 🤔 (LinkedIn: 0-1).
- Signature lines they use (reuse sparingly, at most one per week): "The movers handle the truck. We help with
  everything around it." / "Don't just arrive at your new address. Arrive home."
- Real client stories open with an emotional, concrete moment ("The tears in her eyes said it all.", "Imagine
  leaving your new home for the day and coming back to find everything in its place."), then the specific details
  the team handled, then what it meant to the client. Clients are never named.
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
7. Your time back (audience B): the move-in-ready home, set up your way, so busy professionals and families can
   focus on work and family instead of boxes (relocations, new builds, life getting busy).
Rotate pillars; in a 3-post week use three different pillars.
AUDIENCE BALANCE: every week include at least one post written for older adults and their families AND at least
one written for busy professionals / younger families. A post may speak to both. Say in note_for_brett which
audience each post is for.
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
Formats: photo sets of finished homes and the team at work; swipeable carousels/documents for tips and questions
("What room is most often underestimated during a move?", "How could your new house feel like home by bedtime?").
Early performance signal (2 posts, not proof): a real client story with real photos reached ~50 impressions vs ~3
for a recent post. Real stories come from the Ideal Move team as moves happen; Brett sends them with /post and the agent writes them up. Weekly plans are complete, ready-to-post content from the other pillars (no fill-in templates).
Communities they have worked in (mention ONLY when Brett provides a real story or event there): Fleet Landing
(WELLInspired Living) in Nocatee, Cypress Village.
Goals: build trust with families and referral partners, explain the value of move management, keep the brand
consistently visible, and grow the busy-professional / younger-family audience without losing the senior audience. Calls to action: message on the platform or through their website. Hashtags: local +
topic (e.g. #JacksonvilleFL #StJohnsCounty #Nocatee #MoveManagement #Downsizing #SeniorLiving #HomeSetup
#Relocation #NewHome #MovingToJacksonville #UnpackingServices #HomeOrganization #NorthFlorida), matched to the post's audience, 3-6 per post
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

[5] Imagine leaving your new home for the day and coming back to find everything in its place. 🏡💚
That's exactly what happened for one of our recent clients at Fleet Landing WELLInspired Living!
After relocating from out of town, he trusted the Ideal Move team to help unpack his belongings, arrange his
furniture, and get his new home ready while he was away.
And we didn't stop at the big things! From carefully arranging his favorite pieces to vacuuming rugs, polishing
furniture, and leaving helpful notes so he could find everything, our team took care of the little details, too.
When he returned, he was amazed by how beautifully everything had come together!
That's what we love most about what we do. Helping people walk into their new homes and feel like they're already home.
Planning a move? Let us help you arrive to a home that is ready for you to enjoy! 📩

[6] You've hired the movers. But who's handling everything else? 📦🏡
Moving involves so much more than getting your belongings from one place to another.
There's furniture to arrange, rooms to organize, decorations to put in place, and countless little decisions along the way.
That's where the Ideal Move team comes in!
From coordinating the details to adding those finishing touches that make a new space feel familiar, we're here to
help make the entire transition easier.
And as you can see, our team isn't afraid to roll up their sleeves and get things done! 💚
The movers handle the truck. We help with everything around it.
📩 Planning a move? Reach out to learn how we can help!

[7] The tears in her eyes said it all. Her new house already felt like her new home, all before move day was even over. 💚
For a recent internal move at Cypress Village, our team handled the packing, move, complete home setup, art
placement, and TV hanging in a single day.
By the time the person walked through the door, their bed was made. Her artwork was on the walls. Her favorite
pieces were back on display. Even the balcony was set up and ready to enjoy.
That's the value of managing the entire moving experience, not just getting belongings from one place to another.
For Northeast Florida residents who want to settle in quickly, full move management can turn what might have been
days or weeks of unpacking and setup into a home that's ready to enjoy from day one. 🏡
(This real story post reached ~50 impressions, the best of the recent posts.)

[8] How can the Ideal Move team help make your new house feel like home?
By making sure the beds are made, the kitchen is organized, and the living room is ready to enjoy, not still
buried beneath moving boxes. 🛏️
Ideal Move provides professional move management, unpacking, organizing, and home setup for seniors, families, and
busy professionals moving throughout Jacksonville and North Florida.
The movers handle the truck. We handle the details that make your new space comfortable, functional, and familiar.
Don't just arrive at your new address. Arrive home. 🏡
#MoveManagement #UnpackingServices #HomeOrganization #NorthFlorida
(Carousel: "How Could Your New House Feel Like Home by Bedtime?")

[9] What room do most people underestimate during a move?
For many families, it is the kitchen.
It is not just where the dishes, pantry items, and utensils go.
It is where morning routines start, meals come together, medications may be kept, and the everyday items you reach
for without thinking need to make sense again.
When the kitchen is set up thoughtfully, the whole home can start feeling more normal sooner.
That is why resettling support matters.
Ideal Move helps families organize the spaces they use every day, so settling into a new home feels less
overwhelming after moving day.
Planning a move in Jacksonville or the surrounding area? Message us here or connect through our website anytime. 📦🏡
(Carousel: "What room do you think is most often underestimated when move planning?", 6 pages)

[10] A move doesn't have to take over your entire life.
When the planning happens early and the right details are coordinated ahead of time, moving day becomes part of a
smooth transition instead of a disruption.
Ideal Move helps families prepare so they can arrive ready to settle in and feel at home sooner.
Follow along as we share practical ideas and insights that can make the moving process feel more manageable from the start. 📦➡️🏡
(Carousel: "Moving Doesn't Have to Take Over Your Life", 6 pages: a series opener; good fit for busy professionals.)
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
