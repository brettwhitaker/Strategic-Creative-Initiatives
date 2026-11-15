-- =====================================================================
-- SCI AI Operating Team — 0026 "Draft an email anyway" for "your call" / "not a fit" research results
-- Button on research cards (✍️ Draft an email anyway) and /draft <business>.
-- =====================================================================
create or replace function sci.request_draft_anyway(p_prospect uuid, p_name text, p_from text)
returns text language plpgsql security definer set search_path = sci, public as $$
declare pid uuid := p_prospect; nm text; st sci.prospect_stage; cnt int; q text := trim(coalesce(p_name,''));
begin
  if pid is null then
    if length(q) < 3 then return 'Which business? e.g. /draft Glacier'; end if;
    select count(*) into cnt from sci.prospects p join sci.organizations o on o.id = p.organization_id
     where o.deleted_at is null and o.name ilike '%' || q || '%';
    if cnt = 0 then return 'I couldn''t find a business matching "' || q || '".'; end if;
    if cnt > 1 then return 'More than one business matches "' || q || '". Use more of the name.'; end if;
    select p.id into pid from sci.prospects p join sci.organizations o on o.id = p.organization_id
     where o.deleted_at is null and o.name ilike '%' || q || '%';
  end if;
  select o.name, p.stage into nm, st from sci.prospects p join sci.organizations o on o.id = p.organization_id where p.id = pid;
  if nm is null then return 'Business not found.'; end if;

  if st in ('do_not_contact') or exists (select 1 from sci.prospects p join sci.organizations o on o.id = p.organization_id
       left join sci.contacts c on c.id = p.primary_contact_id
       where p.id = pid and (sci.is_suppressed(c.email) or exists (select 1 from sci.suppression_list s where s.domain = o.domain))) then
    return '⛔ ' || nm || ' is on your do-not-contact list, so no email will be drafted.';
  end if;
  if st in ('drafted','contacted','replied','interested','meeting_booked','won') then
    return 'ℹ️ ' || nm || ' already has an email drafted or sent (stage: ' || st || ').';
  end if;
  if st in ('new','researching') then
    return 'ℹ️ ' || nm || ' hasn''t been researched yet. The draft needs the research first; it''s in the queue.';
  end if;

  update sci.prospects set stage = 'qualified',
         fit_rationale = coalesce(fit_rationale, '') || E'\nOwner chose to draft anyway (was ' || st || ').'
   where id = pid;
  insert into sci.tasks(type, owner_agent, priority, related_table, related_id, dedupe_key, handoff_from)
  values ('draft_outreach', 'sales', 1, 'prospects', pid, 'draft_outreach:' || pid, 'owner')
  on conflict do nothing;
  if not found then return 'ℹ️ A draft for ' || nm || ' is already in the queue.'; end if;
  return '✍️ Got it. An outreach email for ' || nm || ' will arrive for your approval within the hour (8 AM–7 PM ET).';
end $$;
grant execute on function sci.request_draft_anyway(uuid, text, text) to sci_approver;

create or replace function sci.handle_telegram(p_kind text, p_from text, p_target uuid default null, p_decision text default null, p_arg text default null)
returns text language plpgsql set search_path = sci, public as $$
declare allowed text[]; res text; aid uuid;
begin
  select owner_telegram_chat_ids into allowed from sci.system_controls where id;
  if p_from is null or not (p_from = any(allowed)) then return null; end if;

  if p_kind = 'decision' then
    if p_decision not in ('approved','rejected') then return 'Unknown decision.'; end if;
    res := sci.decide_approval(p_target, p_decision::sci.approval_decision, p_from);
    return case res
      when 'approved' then '✅ Approved. (Sending is OFF, so nothing goes out until you enable it.)'
      when 'rejected' then '❌ Rejected. Nothing will be sent. (Reply to the card with notes if you want a new version.)'
      else 'ℹ️ This request was already decided.' end;
  elsif p_kind = 'redraft' then
    return sci.request_redraft(p_target, p_from, null);
  elsif p_kind = 'redraft_note' then
    aid := sci.approval_by_ref(p_decision);
    if aid is null then return 'I couldn''t match that reply to a draft. Reply directly to the draft card.'; end if;
    return sci.request_redraft(aid, p_from, left(p_arg, 1500));
  elsif p_kind = 'candidate' then
    if p_decision not in ('research','skip') then return 'Unknown choice.'; end if;
    return sci.decide_candidate(p_target, p_decision);
  elsif p_kind = 'helpwanted' then
    if p_decision not in ('replied','skip') then return 'Unknown choice.'; end if;
    return sci.decide_helpwanted(p_target, p_decision);
  elsif p_kind = 'draft_anyway' then
    return sci.request_draft_anyway(p_target, null, p_from);
  elsif p_kind = 'draft' then
    return sci.request_draft_anyway(null, p_arg, p_from);
  elsif p_kind = 'sent' then
    return sci.mark_sent_manually(p_arg, p_from);
  elsif p_kind = 'post' then
    return sci.request_story_post(p_arg, p_from);
  elsif p_kind = 'prospect' then
    return sci.add_prospect(p_arg, 'telegram: added by owner');
  elsif p_kind = 'pause' then
    update sci.system_controls set global_pause = true, updated_by = 'telegram:' || p_from where id;
    return '⏸ All agents paused. Nothing will run or send. Send /resume to restart.';
  elsif p_kind = 'resume' then
    update sci.system_controls set global_pause = false, updated_by = 'telegram:' || p_from where id;
    return '▶️ Resumed. Agents will pick up work on their next scheduled run.';
  elsif p_kind = 'status' then
    return sci.status_summary();
  elsif p_kind = 'brief' then
    return sci.weekly_briefing();
  elsif p_kind in ('help','start') then
    return concat_ws(E'\n',
      'SCI Operations bot',
      '/status: what''s happening right now',
      '/brief: the weekly summary (also sent Monday mornings)',
      '/prospect <name or website>: add a business to research',
      '/draft <business>: write an outreach email for a "your call" business anyway',
      '/sent <business>: record an email you sent yourself (starts follow-ups and reply alerts)',
      '/post <story or idea>: a finished social post from your notes (add "Client name:" first if you have several clients)',
      '/pause: stop all agents immediately',
      '/resume: start them again',
      '',
      'Draft and post cards: ✅ Approve, ❌ Reject, ✏️ Redraft, or reply to a card with notes.',
      'Discovery cards: 🔎 Research or ⏭ Skip (verified signals are researched automatically).');
  end if;
  return null;
end $$;
grant execute on function sci.handle_telegram(text, text, uuid, text, text) to sci_approver;
