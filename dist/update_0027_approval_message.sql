-- =====================================================================
-- SCI AI Operating Team — 0027 The "Approved" reply says exactly what happens next
-- (sends automatically / no email on file: send it yourself then /sent / sending is off / social post).
-- =====================================================================
create or replace function sci.approval_next_step(p_approval uuid) returns text
language sql stable security definer set search_path = sci, public as $$
  select case
    when o.created_by = 'social' then '✅ Approved. Ready to post: copy it into Meta Business Suite / LinkedIn when it suits.'
    when o.recipient is null then '✅ Approved. There''s no email address on file, so send it via their website contact form or LinkedIn, then send /sent ' || coalesce(split_part(org.name, ' ', 1), '<business>') || ' so follow-ups and reply alerts work.'
    when not c.sending_enabled then '✅ Approved. Sending is OFF: send it yourself from Gmail, then /sent ' || coalesce(split_part(org.name, ' ', 1), '<business>') || '. (Or turn sending on in Supabase.)'
    when c.global_pause then '✅ Approved. Everything is paused (/resume to restart); it will send once resumed, during business hours.'
    else '✅ Approved. It sends from your Gmail on the next run during business hours (Mon–Fri 9 AM–5 PM ET). You''ll get a 📤 message when it goes.'
  end
  from sci.approvals a join sci.outbound_actions o on o.id = a.subject_id
  cross join sci.system_controls c
  left join sci.prospects p on p.id = o.prospect_id left join sci.organizations org on org.id = p.organization_id
  where a.id = p_approval and c.id;
$$;
grant execute on function sci.approval_next_step(uuid) to sci_approver;

create or replace function sci.handle_telegram(p_kind text, p_from text, p_target uuid default null, p_decision text default null, p_arg text default null)
returns text language plpgsql set search_path = sci, public as $$
declare allowed text[]; res text; aid uuid;
begin
  select owner_telegram_chat_ids into allowed from sci.system_controls where id;
  if p_from is null or not (p_from = any(allowed)) then return null; end if;

  if p_kind = 'decision' then
    if p_decision not in ('approved','rejected') then return 'Unknown decision.'; end if;
    res := sci.decide_approval(p_target, p_decision::sci.approval_decision, p_from);
    if res = 'approved' then return sci.approval_next_step(p_target); end if;
    return case res
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
