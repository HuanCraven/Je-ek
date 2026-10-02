-- Další obdarování: lidé mimo aplikaci (babičky apod.). Vidí a upravují je všichni.

create table public.recipients (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  created_by uuid references public.members(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.recipients enable row level security;

-- přání patří buď členovi (owner_id), nebo osobě mimo aplikaci (recipient_id)
alter table public.wishes alter column owner_id drop not null;
alter table public.wishes add column recipient_id uuid references public.recipients(id) on delete cascade;
alter table public.wishes add constraint wishes_one_target check ((owner_id is null) <> (recipient_id is null));

create function public._target_name(p_wish uuid) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(m.name, r.name, '?')
  from public.wishes w
  left join public.members m on m.id = w.owner_id
  left join public.recipients r on r.id = w.recipient_id
  where w.id = p_wish
$$;

-- ---------------------------------------------------------------- stav

create or replace function public.get_state(p_email text) returns json
language plpgsql stable security definer set search_path = '' as $$
declare
  me public.members := public._me(p_email);
  y int := public._year();
begin
  return json_build_object(
    'year', y,
    'me', json_build_object(
      'id', me.id, 'name', me.name, 'email', me.email, 'is_admin', me.is_admin,
      'notify_new_wish', me.notify_new_wish, 'notify_wish_changed', me.notify_wish_changed,
      'notify_contributor', me.notify_contributor, 'notify_status', me.notify_status),
    'members', (select coalesce(json_agg(json_build_object('id', id, 'name', name) order by name), '[]')
                from public.members),
    'recipients', (select coalesce(json_agg(json_build_object('id', id, 'name', name) order by name), '[]')
                   from public.recipients),
    'my_wishes', (select coalesce(json_agg(json_build_object(
                    'id', w.id, 'title', w.title, 'description', w.description,
                    'priority', w.priority, 'note', w.note, 'photo_path', w.photo_path)
                    order by w.priority desc, w.created_at), '[]')
                  from public.wishes w
                  where w.year = y and w.owner_id = me.id and w.author_id = me.id
                    and w.cancelled_at is null),
    -- přání ostatních členů i dárky pro osoby mimo aplikaci (owner_id je null => recipient)
    'others_wishes', (select coalesce(json_agg(json_build_object(
                    'id', w.id, 'owner_id', w.owner_id, 'recipient_id', w.recipient_id,
                    'author_id', w.author_id,
                    'title', w.title, 'description', w.description, 'priority', w.priority,
                    'note', w.note, 'photo_path', w.photo_path,
                    'cancelled', w.cancelled_at is not null,
                    'updated_at', w.updated_at,
                    'purchase', (select json_build_object('buyer_id', p.buyer_id, 'status', p.status,
                                   'note', p.note, 'changed', w.updated_at > p.seen_at)
                                 from public.purchases p where p.wish_id = w.id),
                    'contributors', (select coalesce(json_agg(c.member_id order by c.created_at), '[]')
                                     from public.contributions c where c.wish_id = w.id))
                    order by w.priority desc, w.created_at), '[]')
                  from public.wishes w
                  where w.year = y and (w.owner_id <> me.id or w.recipient_id is not null))
  );
end $$;

-- ---------------------------------------------------------------- přání

create function public.save_wish(p_email text, p_id uuid, p_owner_id uuid, p_title text,
  p_description text, p_priority smallint, p_note text, p_photo_path text,
  p_recipient_id uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  me public.members := public._me(p_email);
  w public.wishes;
begin
  if p_id is null then
    insert into public.wishes (owner_id, recipient_id, author_id, year, title, description, priority, note, photo_path)
    values (case when p_recipient_id is null then coalesce(p_owner_id, me.id) end, p_recipient_id,
            me.id, public._year(), trim(p_title),
            coalesce(p_description, ''), coalesce(p_priority, 1), coalesce(p_note, ''), p_photo_path)
    returning * into w;
    perform public._notify(array(
      select id from public.members
      where notify_new_wish and id is distinct from w.owner_id and id <> me.id),
      case
        when w.recipient_id is not null then me.name || ' přidal(a) dárek pro ' || public._target_name(w.id) || ': ' || w.title
        when w.owner_id = me.id then me.name || ' si přeje: ' || w.title
        else me.name || ' přidal(a) tip pro ' || public._target_name(w.id) || ': ' || w.title end);
    return w.id;
  end if;

  select * into w from public.wishes where id = p_id;
  -- dárky pro osoby mimo aplikaci smí upravit kdokoli, ostatní jen autor
  if not found or (w.recipient_id is null and w.author_id <> me.id) then
    raise exception 'Toto přání nemůžeš upravit' using errcode = 'P0001';
  end if;
  update public.wishes set title = trim(p_title), description = coalesce(p_description, ''),
    priority = coalesce(p_priority, 1), note = coalesce(p_note, ''), photo_path = p_photo_path,
    updated_at = now()
  where id = p_id;
  perform public._notify(array(
    select m.id from public._participants(p_id) p join public.members m on m.id = p.member_id
    where m.notify_wish_changed and m.id <> me.id),
    'Přání „' || trim(p_title) || '“ (' || public._target_name(p_id) || ') bylo upraveno.');
  return p_id;
end $$;

-- stará podoba (bez p_recipient_id) jen předává dál
create or replace function public.save_wish(p_email text, p_id uuid, p_owner_id uuid, p_title text,
  p_description text, p_priority smallint, p_note text, p_photo_path text) returns uuid
language sql security definer set search_path = '' as $$
  select public.save_wish(p_email, p_id, p_owner_id, p_title, p_description, p_priority, p_note, p_photo_path, null::uuid)
$$;

create or replace function public.delete_wish(p_email text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  me public.members := public._me(p_email);
  w public.wishes;
begin
  select * into w from public.wishes where id = p_id;
  if not found or (w.recipient_id is null and w.author_id <> me.id) then
    raise exception 'Toto přání nemůžeš smazat' using errcode = 'P0001';
  end if;
  perform public._notify(array(
    select m.id from public._participants(p_id) p join public.members m on m.id = p.member_id
    where m.notify_wish_changed and m.id <> me.id),
    'Přání „' || w.title || '“ (' || public._target_name(p_id) || ') bylo zrušeno.');
  update public.wishes set cancelled_at = now(), updated_at = now() where id = p_id;
  perform public._cleanup(p_id);
end $$;

-- ---------------------------------------------------------------- nakupování

create or replace function public._check_not_owner(me public.members, p_wish uuid) returns public.wishes
language plpgsql stable security definer set search_path = '' as $$
declare w public.wishes;
begin
  select * into w from public.wishes where id = p_wish;
  if not found or w.owner_id is not distinct from me.id then
    raise exception 'Přání nenalezeno' using errcode = 'P0001';
  end if;
  return w;
end $$;

-- ---------------------------------------------------------------- osoby mimo aplikaci

-- p_id null => nová osoba; vrací id
create function public.save_recipient(p_email text, p_id uuid, p_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  me public.members := public._me(p_email);
  r_id uuid;
begin
  if p_id is null then
    insert into public.recipients (name, created_by) values (trim(p_name), me.id) returning id into r_id;
    return r_id;
  end if;
  update public.recipients set name = trim(p_name) where id = p_id;
  return p_id;
end $$;

-- ---------------------------------------------------------------- nový ročník

create or replace function public.admin_new_year(p_email text, p_carry boolean) returns int
language plpgsql security definer set search_path = '' as $$
declare
  old_y int := public._year();
  new_y int := old_y + 1;
begin
  perform public._admin(p_email);
  update public.settings set value = new_y::text where key = 'active_year';
  if p_carry then
    insert into public.wishes (owner_id, recipient_id, author_id, year, title, description, priority, note, photo_path)
    select owner_id, recipient_id, author_id, new_y, title, description, priority, note, photo_path
    from public.wishes w
    where w.year = old_y and w.cancelled_at is null
      and not exists (select 1 from public.purchases p where p.wish_id = w.id and p.status = 'koupeno');
  end if;
  return new_y;
end $$;

-- ---------------------------------------------------------------- práva

revoke all on function public._target_name(uuid) from public, anon, authenticated;
revoke all on function public.save_wish(text, uuid, uuid, text, text, smallint, text, text, uuid) from public;
revoke all on function public.save_recipient(text, uuid, text) from public;
grant execute on function
  public.save_wish(text, uuid, uuid, text, text, smallint, text, text, uuid),
  public.save_recipient(text, uuid, text)
to anon, authenticated;
