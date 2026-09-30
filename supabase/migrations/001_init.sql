-- Ježíšek – základní schéma
-- Tabulky mají zapnuté RLS bez politik => z prohlížeče nejsou přímo čitelné.
-- Veškerý přístup jde přes funkce níže (security definer), které podle e-mailu
-- určí, kdo se ptá, a nikdy mu nevrátí stav nákupu jeho vlastních přání.

create table public.settings (
  key text primary key,
  value text not null
);
insert into public.settings values ('active_year', extract(year from now())::text);

create table public.members (
  id uuid primary key default gen_random_uuid(),
  email text not null unique check (email = lower(trim(email))),
  name text not null,
  is_admin boolean not null default false,
  notify_new_wish boolean not null default false,      -- nové přání u ostatních
  notify_wish_changed boolean not null default false,  -- změna/zrušení přání, které kupuji nebo na které se skládám
  notify_contributor boolean not null default false,   -- někdo se přidal ke skládání na dárek, který kupuji
  notify_status boolean not null default false,        -- změna stavu dárku, na který se skládám
  created_at timestamptz not null default now()
);

create table public.wishes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.members(id) on delete cascade,  -- komu je přání určeno
  author_id uuid not null references public.members(id) on delete cascade, -- kdo ho zapsal (≠ owner => tip)
  year int not null,
  title text not null check (length(trim(title)) > 0),
  description text not null default '',
  priority smallint not null default 1 check (priority between 1 and 3),
  note text not null default '',
  photo_path text,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.wishes (year, owner_id);

create table public.purchases (
  wish_id uuid primary key references public.wishes(id) on delete cascade,
  buyer_id uuid not null references public.members(id) on delete cascade,
  status text not null default 'kupuji' check (status in ('kupuji', 'objednano', 'koupeno')),
  note text not null default '',
  seen_at timestamptz not null default now(),  -- kdy kupující naposledy viděl aktuální podobu přání
  updated_at timestamptz not null default now()
);

create table public.contributions (
  wish_id uuid not null references public.wishes(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (wish_id, member_id)
);

create table public.outbox (
  id bigint generated always as identity primary key,
  member_id uuid not null references public.members(id) on delete cascade,
  message text not null,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index on public.outbox (sent_at) where sent_at is null;

alter table public.settings enable row level security;
alter table public.members enable row level security;
alter table public.wishes enable row level security;
alter table public.purchases enable row level security;
alter table public.contributions enable row level security;
alter table public.outbox enable row level security;

-- ---------------------------------------------------------------- pomocné

create function public._me(p_email text) returns public.members
language plpgsql stable security definer set search_path = '' as $$
declare m public.members;
begin
  select * into m from public.members where email = lower(trim(p_email));
  if not found then raise exception 'Neznámý e-mail' using errcode = 'P0001'; end if;
  return m;
end $$;

create function public._year() returns int
language sql stable security definer set search_path = '' as $$
  select value::int from public.settings where key = 'active_year'
$$;

create function public._notify(p_members uuid[], p_message text) returns void
language sql security definer set search_path = '' as $$
  insert into public.outbox (member_id, message)
  select unnest(p_members), p_message
$$;

-- Smaže zrušené přání, pokud už ho nikdo nekupuje ani se na něj neskládá.
create function public._cleanup(p_wish uuid) returns void
language sql security definer set search_path = '' as $$
  delete from public.wishes w
  where w.id = p_wish and w.cancelled_at is not null
    and not exists (select 1 from public.purchases where wish_id = w.id)
    and not exists (select 1 from public.contributions where wish_id = w.id)
$$;

-- Kdo se nákupu účastní (kupující + skládající), volitelně jen s daným typem upozornění.
create function public._participants(p_wish uuid) returns table (member_id uuid, is_buyer boolean)
language sql stable security definer set search_path = '' as $$
  select buyer_id, true from public.purchases where wish_id = p_wish
  union
  select member_id, false from public.contributions where wish_id = p_wish
$$;

-- ---------------------------------------------------------------- přihlášení a stav

create function public.login(p_email text) returns json
language plpgsql stable security definer set search_path = '' as $$
declare m public.members;
begin
  select * into m from public.members where email = lower(trim(p_email));
  if not found then return null; end if;
  return json_build_object('id', m.id, 'name', m.name, 'email', m.email, 'is_admin', m.is_admin);
end $$;

create function public.get_state(p_email text) returns json
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
    -- vlastní přání: jen to, co jsem si zapsal sám, bez jakékoli informace o nákupu
    'my_wishes', (select coalesce(json_agg(json_build_object(
                    'id', w.id, 'title', w.title, 'description', w.description,
                    'priority', w.priority, 'note', w.note, 'photo_path', w.photo_path)
                    order by w.priority desc, w.created_at), '[]')
                  from public.wishes w
                  where w.year = y and w.owner_id = me.id and w.author_id = me.id
                    and w.cancelled_at is null),
    -- přání ostatních včetně stavu nákupu
    'others_wishes', (select coalesce(json_agg(json_build_object(
                    'id', w.id, 'owner_id', w.owner_id, 'author_id', w.author_id,
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
                  where w.year = y and w.owner_id <> me.id)
  );
end $$;

-- ---------------------------------------------------------------- přání

create function public.save_wish(p_email text, p_id uuid, p_owner_id uuid, p_title text,
  p_description text, p_priority smallint, p_note text, p_photo_path text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  me public.members := public._me(p_email);
  w public.wishes;
  owner_name text;
  new_id uuid;
begin
  if p_id is null then
    insert into public.wishes (owner_id, author_id, year, title, description, priority, note, photo_path)
    values (coalesce(p_owner_id, me.id), me.id, public._year(), trim(p_title),
            coalesce(p_description, ''), coalesce(p_priority, 1), coalesce(p_note, ''), p_photo_path)
    returning * into w;
    select name into owner_name from public.members where id = w.owner_id;
    -- upozornění „nové přání“: všem kromě obdarovaného a autora
    perform public._notify(array(
      select id from public.members
      where notify_new_wish and id <> w.owner_id and id <> me.id),
      case when w.owner_id = me.id
        then me.name || ' si přeje: ' || w.title
        else me.name || ' přidal(a) tip pro ' || owner_name || ': ' || w.title end);
    return w.id;
  end if;

  select * into w from public.wishes where id = p_id;
  if not found or w.author_id <> me.id then
    raise exception 'Toto přání nemůžeš upravit' using errcode = 'P0001';
  end if;
  update public.wishes set title = trim(p_title), description = coalesce(p_description, ''),
    priority = coalesce(p_priority, 1), note = coalesce(p_note, ''), photo_path = p_photo_path,
    updated_at = now()
  where id = p_id;
  select name into owner_name from public.members where id = w.owner_id;
  perform public._notify(array(
    select m.id from public._participants(p_id) p join public.members m on m.id = p.member_id
    where m.notify_wish_changed and m.id <> me.id),
    'Přání „' || trim(p_title) || '“ (' || owner_name || ') bylo upraveno.');
  return p_id;
end $$;

create function public.delete_wish(p_email text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  me public.members := public._me(p_email);
  w public.wishes;
  owner_name text;
begin
  select * into w from public.wishes where id = p_id;
  if not found or w.author_id <> me.id then
    raise exception 'Toto přání nemůžeš smazat' using errcode = 'P0001';
  end if;
  select name into owner_name from public.members where id = w.owner_id;
  perform public._notify(array(
    select m.id from public._participants(p_id) p join public.members m on m.id = p.member_id
    where m.notify_wish_changed and m.id <> me.id),
    'Přání „' || w.title || '“ (' || owner_name || ') bylo zrušeno.');
  update public.wishes set cancelled_at = now(), updated_at = now() where id = p_id;
  perform public._cleanup(p_id);
end $$;

-- ---------------------------------------------------------------- nakupování

create function public._check_not_owner(me public.members, p_wish uuid) returns public.wishes
language plpgsql stable security definer set search_path = '' as $$
declare w public.wishes;
begin
  select * into w from public.wishes where id = p_wish;
  if not found or w.owner_id = me.id then
    raise exception 'Přání nenalezeno' using errcode = 'P0001';
  end if;
  return w;
end $$;

-- p_status null => přestávám kupovat
create function public.set_purchase(p_email text, p_wish uuid, p_status text, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  me public.members := public._me(p_email);
  w public.wishes := public._check_not_owner(me, p_wish);
  p public.purchases;
  owner_name text;
  label text;
begin
  select name into owner_name from public.members where id = w.owner_id;
  select * into p from public.purchases where wish_id = p_wish;

  if p_status is null then
    if found and p.buyer_id = me.id then
      delete from public.purchases where wish_id = p_wish;
      perform public._notify(array(
        select m.id from public.contributions c join public.members m on m.id = c.member_id
        where c.wish_id = p_wish and m.notify_status),
        me.name || ' už nekupuje „' || w.title || '“ (' || owner_name || '). Dárek je znovu volný.');
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
    -- kupující se nemá zároveň skládat
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
    '„' || w.title || '“ (' || owner_name || '): ' || me.name || ' – ' || label || '.');
end $$;

create function public.mark_seen(p_email text, p_wish uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare me public.members := public._me(p_email);
begin
  update public.purchases set seen_at = now() where wish_id = p_wish and buyer_id = me.id;
end $$;

create function public.set_contribution(p_email text, p_wish uuid, p_on boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  me public.members := public._me(p_email);
  w public.wishes := public._check_not_owner(me, p_wish);
  owner_name text;
begin
  select name into owner_name from public.members where id = w.owner_id;
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
        me.name || ' se skládá na „' || w.title || '“ (' || owner_name || ').');
    end if;
  else
    delete from public.contributions where wish_id = p_wish and member_id = me.id;
    perform public._cleanup(p_wish);
  end if;
end $$;

-- ---------------------------------------------------------------- nastavení

create function public.set_notifications(p_email text, p_new_wish boolean, p_wish_changed boolean,
  p_contributor boolean, p_status boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare me public.members := public._me(p_email);
begin
  update public.members set notify_new_wish = p_new_wish, notify_wish_changed = p_wish_changed,
    notify_contributor = p_contributor, notify_status = p_status
  where id = me.id;
end $$;

-- ---------------------------------------------------------------- správa (jen admin)

create function public._admin(p_email text) returns public.members
language plpgsql stable security definer set search_path = '' as $$
declare me public.members := public._me(p_email);
begin
  if not me.is_admin then raise exception 'Jen pro správce' using errcode = 'P0001'; end if;
  return me;
end $$;

create function public.admin_list_members(p_email text) returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public._admin(p_email);
  return (select coalesce(json_agg(json_build_object('id', id, 'name', name, 'email', email,
            'is_admin', is_admin) order by name), '[]') from public.members);
end $$;

create function public.admin_save_member(p_email text, p_id uuid, p_member_email text,
  p_name text, p_is_admin boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare me public.members := public._admin(p_email);
begin
  if p_id is null then
    insert into public.members (email, name, is_admin)
    values (lower(trim(p_member_email)), trim(p_name), coalesce(p_is_admin, false));
  else
    if p_id = me.id and not p_is_admin then
      raise exception 'Nemůžeš odebrat práva správce sám sobě' using errcode = 'P0001';
    end if;
    update public.members set email = lower(trim(p_member_email)), name = trim(p_name),
      is_admin = coalesce(p_is_admin, false)
    where id = p_id;
  end if;
end $$;

create function public.admin_delete_member(p_email text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare me public.members := public._admin(p_email);
begin
  if p_id = me.id then raise exception 'Nemůžeš smazat sám sebe' using errcode = 'P0001'; end if;
  delete from public.members where id = p_id;
end $$;

-- Nový ročník: stará přání zůstanou v databázi jako archiv.
-- p_carry => nesplněná přání (nezrušená, nekoupená) se zkopírují do nového roku.
create function public.admin_new_year(p_email text, p_carry boolean) returns int
language plpgsql security definer set search_path = '' as $$
declare
  old_y int := public._year();
  new_y int := old_y + 1;
begin
  perform public._admin(p_email);
  update public.settings set value = new_y::text where key = 'active_year';
  if p_carry then
    insert into public.wishes (owner_id, author_id, year, title, description, priority, note, photo_path)
    select owner_id, author_id, new_y, title, description, priority, note, photo_path
    from public.wishes w
    where w.year = old_y and w.cancelled_at is null
      and not exists (select 1 from public.purchases p where p.wish_id = w.id and p.status = 'koupeno');
  end if;
  return new_y;
end $$;

-- ---------------------------------------------------------------- práva

revoke all on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.login(text), public.get_state(text),
  public.save_wish(text, uuid, uuid, text, text, smallint, text, text),
  public.delete_wish(text, uuid), public.set_purchase(text, uuid, text, text),
  public.mark_seen(text, uuid), public.set_contribution(text, uuid, boolean),
  public.set_notifications(text, boolean, boolean, boolean, boolean),
  public.admin_list_members(text), public.admin_save_member(text, uuid, text, text, boolean),
  public.admin_delete_member(text, uuid), public.admin_new_year(text, boolean)
to anon, authenticated;

-- ---------------------------------------------------------------- fotky

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']);

create policy "photos upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'photos');
