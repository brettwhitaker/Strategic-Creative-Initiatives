-- =====================================================================
-- SCI AI Operating Team — 0015 Signature: phone + website (owner-approved)
-- =====================================================================
alter table sci.sender_profile add column if not exists phone text;
update sci.sender_profile set
  title   = 'Founder',
  phone   = '317-931-9830',
  website = 'https://strategiccreativeinitiatives.com',
  updated_at = now()
where id;

create or replace function sci.email_footer() returns text language sql stable security definer set search_path = sci, public as $$
  select concat_ws(E'\n', '', full_name, title || ', ' || business_name,
                   concat_ws(' · ', email, phone), website, mailing_address, '', opt_out_line)
    from sci.sender_profile where id;
$$;

-- Agents may mention the website where it helps (e.g. "you can see some of my work at ...").
select sci.set_knowledge('positioning', (select content from sci.business_knowledge where key = 'positioning' and is_active)
  || E'\nWEBSITE: https://strategiccreativeinitiatives.com (services, starting prices, about Brett, writing samples).\n');

select sci.email_footer() as your_email_footer;
