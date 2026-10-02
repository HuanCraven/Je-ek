-- Další obdarování – část 2. Spustit ručně v Supabase → SQL Editor
-- (nástroj pro migrace ji kvůli příkazům DELETE odmítá bez potvrzení).
-- Nákupní funkce berou jméno obdarovaného i z tabulky recipients.

create or replace function public.set_purchase(p_email text, p_wish uuid, p_status text, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  me public.members := public._me(p_email);
  w public.wishes := public._check_not_owner(me, p_wish);
  p public.purchases;
  target text := public._target_name(p_wish);
  label text;
begin
  select * into p from public.purchases where wish_id = p_wish;

  if p_status is null then
    if found and p.buyer_id = me.id then
      delete from public.purchases where wish_id = p_wish;
      perform public._notify(array(
        select m.id from public.contributions c join public.members m on m.id = c.member_id
        where c.wish_id = p_wish and m.notify_status),
        me.name || ' už nekupuje „' || w.title || '“ (' || target || '). Dárek je znovu volný.');
      perform public._cleanup(p_wish);
    end if;
    return;
  end if;

  if not found then
    if w.cancelled_at is not null then
      raise exception 'Přání bylo zrušeno' using errcode = 'P0001';
    end if;
    insert into public.purchases (wish_id, buyer_id, status, note)
    values (p_wish, me.id, p_status, coalesce(p_note, ''));
    delete from public.contributions where wish_id = p_wish and member_id = me.id;
  elsif p.buyer_id <> me.id then
    raise exception 'Tento dárek už kupuje někdo jiný' using errcode = 'P0001';
  else
    update public.purchases set status = p_status, note = coalesce(p_note, note),
      seen_at = now(), updated_at = now()
    where wish_id = p_wish;
    if p.status = p_status then return; end if;
  end if;

  label := case p_status when 'kupuji' then 'Kupuji' when 'objednano' then 'Objednáno' else 'Koupeno' end;
  perform public._notify(array(
    select m.id from public.contributions c join public.members m on m.id = c.member_id
    where c.wish_id = p_wish and m.notify_status and m.id <> me.id),
    '„' || w.title || '“ (' || target || '): ' || me.name || ' – ' || label || '.');
end $$;

create or replace function public.set_contribution(p_email text, p_wish uuid, p_on boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  me public.members := public._me(p_email);
  w public.wishes := public._check_not_owner(me, p_wish);
begin
  if p_on then
    if w.cancelled_at is not null then
      raise exception 'Přání bylo zrušeno' using errcode = 'P0001';
    end if;
    if exists (select 1 from public.purchases where wish_id = p_wish and buyer_id = me.id) then
      return;
    end if;
    insert into public.contributions (wish_id, member_id) values (p_wish, me.id)
    on conflict do nothing;
    if found then
      perform public._notify(array(
        select m.id from public.purchases p join public.members m on m.id = p.buyer_id
        where p.wish_id = p_wish and m.notify_contributor),
        me.name || ' se skládá na „' || w.title || '“ (' || public._target_name(p_wish) || ').');
    end if;
  else
    delete from public.contributions where wish_id = p_wish and member_id = me.id;
    perform public._cleanup(p_wish);
  end if;
end $$;

-- smaže osobu i všechny její dárky (včetně archivu)
create function public.delete_recipient(p_email text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public._me(p_email);
  delete from public.recipients where id = p_id;
end $$;

revoke all on function public.delete_recipient(text, uuid) from public;
grant execute on function public.delete_recipient(text, uuid) to anon, authenticated;
