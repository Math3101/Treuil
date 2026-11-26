-- =====================================================================
-- Suivi d'avancement · Résidence Le Treuil · GBMP
-- Script de mise en place Supabase · version 4 (entreprise + code, droits par tâche, salle de bain, affichage des codes)
-- À coller dans SQL Editor puis Run. Peut être relancé sans risque :
-- il ne supprime aucun relevé.
-- AVANT DE LANCER : remplacez 1234 par votre code administrateur à 4 chiffres
-- tout en bas du script (ligne marquée « VOTRE CODE »).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tables ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  email text,
  nom text,
  role text not null default 'attente' check (role in ('admin','saisie','cons','attente')),
  lots text[] not null default '{}',
  created_at timestamptz not null default now()
);
alter table public.profiles add column if not exists actif boolean not null default true;
alter table public.profiles add column if not exists last_login timestamptz;
alter table public.profiles add column if not exists taches text[] not null default '{}';

-- Codes et mots de passe techniques : jamais lisibles depuis l'application
create table if not exists public.entreprise_secrets (
  id uuid primary key references public.profiles(id) on delete cascade,
  code_hash text not null,
  secret text not null,
  failed int not null default 0,
  locked_until timestamptz
);
-- Copie lisible du code, consultable uniquement par l'administrateur (fonction admin_get_code)
alter table public.entreprise_secrets add column if not exists code_clair text;

-- Journal d'activité (connexions, échecs, relevés, fiches)
create table if not exists public.journal (
  id bigint generated always as identity primary key,
  profile_id uuid,
  nom text,
  action text not null,
  detail text,
  at timestamptz not null default now()
);
create index if not exists journal_at on public.journal (at desc);

create table if not exists public.invitations (
  email text primary key,
  nom text,
  role text not null default 'cons' check (role in ('admin','saisie','cons')),
  lots text[] not null default '{}',
  created_at timestamptz not null default now()
);

create table if not exists public.task_lots (
  task_id text primary key,
  lot text not null
);

create table if not exists public.zone_attrs (
  zone_id text primary key,
  data jsonb not null default '{}',
  updated_by uuid,
  updated_at timestamptz not null default now()
);

create table if not exists public.releves (
  id bigint generated always as identity primary key,
  zone_id text not null,
  task_id text not null references public.task_lots(task_id),
  lot text,
  st text not null check (st in ('v','nr','so')),
  v numeric,
  c text not null default '',
  photos text[] not null default '{}',
  am_ok boolean not null default false,
  by uuid,
  by_nom text,
  at timestamptz not null default now()
);
create index if not exists releves_zone_task_at on public.releves (zone_id, task_id, at desc);

create table if not exists public.config (
  id int primary key default 1 check (id = 1),
  data jsonb not null default '{"amCheck": false}'
);
insert into public.config (id) values (1) on conflict do nothing;

-- ---------- Tâches et lots (référentiel) ----------
insert into public.task_lots (task_id, lot) values
 ('L1','06'),('L2','01'),('L3','13A'),('L4','13A'),('L5','13B'),('L6','13B'),('L7','12'),('L8','12'),
 ('L9','08'),('L10','08'),('L11','08'),('L12','11'),('L13','GBMP'),
 ('P1','09'),('P2','11'),('P3','12'),
 ('H1','06'),('H2','10'),('H3','11'),('H4','12'),('H5','08'),
 ('E1','10'),('E2','11'),('E3','12'),
 ('S1','01'),('S2','02'),('S3','14'),('S4','14'),
 ('SS1','01'),('SS2','13A'),('SS3','13A'),('SS4','12'),
 ('T1','04'),('T2','13A'),
 ('F1','05'),('F2','06'),('F3','01'),('F4','13A'),('F5','05'),('F6','05'),
 ('X1','15'),('X2','16'),('X3','01'),
 ('SB1','10'),('SB2','11'),('SB3','10'),('SB4','13B'),('SB5','13B'),('SB6','13B'),('SB7','13B'),('SB8','09')
on conflict (task_id) do update set lot = excluded.lot;

-- ---------- Fonctions d'aide (droits) ----------
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as
$$ select coalesce((select case when actif then role else 'attente' end from public.profiles where id = auth.uid()), 'attente') $$;

create or replace function public.my_lots() returns text[]
language sql stable security definer set search_path = public as
$$ select coalesce((select case when actif then lots else '{}' end from public.profiles where id = auth.uid()), '{}') $$;

create or replace function public.my_taches() returns text[]
language sql stable security definer set search_path = public as
$$ select coalesce((select case when actif then taches else '{}' end from public.profiles where id = auth.uid()), '{}') $$;

create or replace function public.is_active() returns boolean
language sql stable security definer set search_path = public as
$$ select public.my_role() in ('admin','saisie','cons') $$;

-- ---------- Plus d'inscription libre : les comptes sont créés par l'administrateur ----------
drop trigger if exists on_auth_user_created on auth.users;

-- ---------- Relevé : lot, auteur et date imposés par la base ----------
create or replace function public.releves_before_insert() returns trigger
language plpgsql security definer set search_path = public as
$$
begin
  new.lot := (select lot from public.task_lots where task_id = new.task_id);
  if new.lot is null then raise exception 'Tâche inconnue %', new.task_id; end if;
  new.by := auth.uid();
  new.by_nom := (select coalesce(nom, email) from public.profiles where id = auth.uid());
  new.at := now();
  return new;
end $$;
drop trigger if exists releves_bi on public.releves;
create trigger releves_bi before insert on public.releves
  for each row execute function public.releves_before_insert();

drop function if exists public.admin_set_password(uuid, text);

-- ---------- Journal automatique des relevés et des fiches ----------
create or replace function public.journal_releve() returns trigger
language plpgsql security definer set search_path = public as
$$ begin
  insert into public.journal (profile_id, nom, action, detail)
  values (new."by", new.by_nom, 'relevé', new.zone_id || ' · ' || new.task_id || ' · ' ||
    case new.st when 'v' then coalesce(new.v::text, '') when 'so' then 'sans objet' else 'non relevé' end ||
    case when cardinality(new.photos) > 0 then ' · ' || cardinality(new.photos) || ' photo(s)' else '' end);
  return new;
end $$;
drop trigger if exists releves_journal on public.releves;
create trigger releves_journal after insert on public.releves for each row execute function public.journal_releve();

create or replace function public.journal_fiche() returns trigger
language plpgsql security definer set search_path = public as
$$ begin
  insert into public.journal (profile_id, nom, action, detail)
  values (auth.uid(), (select nom from public.profiles where id = auth.uid()), 'fiche', new.zone_id);
  return new;
end $$;
drop trigger if exists zone_attrs_journal on public.zone_attrs;
create trigger zone_attrs_journal after insert or update on public.zone_attrs for each row execute function public.journal_fiche();

-- ---------- Connexion : liste des entreprises + code à 4 chiffres ----------
create or replace function public.list_entreprises() returns table (id uuid, nom text)
language sql stable security definer set search_path = public as
$$ select p.id, p.nom from public.profiles p join public.entreprise_secrets s on s.id = p.id
   where p.actif order by (p.role = 'admin') desc, p.nom $$;

-- 5 codes faux : blocage 15 min ; 10 codes faux : blocage 24 h.
create or replace function public.pin_login(p_id uuid, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as
$$
declare s public.entreprise_secrets%rowtype; p public.profiles%rowtype; n int;
begin
  select * into p from public.profiles where id = p_id and actif;
  select * into s from public.entreprise_secrets where id = p_id for update;
  if p.id is null or s.id is null then return json_build_object('ok', false, 'msg', 'Entreprise inconnue ou désactivée.'); end if;
  if s.locked_until is not null and s.locked_until > now() then
    return json_build_object('ok', false, 'msg', 'Trop d''essais : accès bloqué jusqu''à ' || to_char(s.locked_until at time zone 'Europe/Paris', 'HH24:MI') || '.');
  end if;
  if p_pin is null or s.code_hash <> extensions.crypt(p_pin, s.code_hash) then
    n := s.failed + 1;
    update public.entreprise_secrets set failed = n,
      locked_until = case when n >= 10 then now() + interval '24 hours' when n >= 5 then now() + interval '15 minutes' else null end
    where id = p_id;
    insert into public.journal (profile_id, nom, action) values (p_id, p.nom, 'échec code');
    return json_build_object('ok', false, 'msg', case when n >= 5 then 'Code incorrect. Accès bloqué temporairement.' else 'Code incorrect (' || (5 - n) || ' essai(s) avant blocage).' end);
  end if;
  update public.entreprise_secrets set failed = 0, locked_until = null where id = p_id;
  update public.profiles set last_login = now() where id = p_id;
  insert into public.journal (profile_id, nom, action) values (p_id, p.nom, 'connexion');
  return json_build_object('ok', true, 'email', (select email from auth.users where id = p_id), 'password', s.secret);
end $$;

-- ---------- Gestion des entreprises (administrateur) ----------
create or replace function public.assert_admin() returns void
language plpgsql stable security definer set search_path = public as
$$ begin
  -- Appel depuis l'application : compte administrateur obligatoire.
  -- Appel sans utilisateur : seulement depuis SQL Editor (postgres).
  if (auth.uid() is not null and public.my_role() <> 'admin')
     or (auth.uid() is null and session_user not in ('postgres', 'supabase_admin')) then
    raise exception 'Réservé à l''administrateur';
  end if;
end $$;

create or replace function public.check_pin(p_pin text, p_except uuid) returns void
language plpgsql stable security definer set search_path = public, extensions as
$$ begin
  if p_pin !~ '^[0-9]{4}$' then raise exception 'Le code doit comporter exactement 4 chiffres.'; end if;
  if exists (select 1 from public.entreprise_secrets where id is distinct from p_except and code_hash = extensions.crypt(p_pin, code_hash)) then
    raise exception 'Ce code est déjà attribué à une autre entreprise.';
  end if;
end $$;

drop function if exists public.admin_create_entreprise(text, text, text, text[]);
create or replace function public.admin_create_entreprise(p_nom text, p_pin text, p_role text, p_lots text[], p_taches text[] default '{}') returns uuid
language plpgsql security definer set search_path = public, extensions as
$$
declare uid uuid := gen_random_uuid(); em text; sec text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  perform public.assert_admin();
  if coalesce(trim(p_nom), '') = '' then raise exception 'Nom obligatoire.'; end if;
  if p_role not in ('admin', 'saisie', 'cons') then raise exception 'Rôle invalide.'; end if;
  if exists (select 1 from public.profiles where lower(nom) = lower(trim(p_nom))) then raise exception 'Une entreprise porte déjà ce nom.'; end if;
  perform public.check_pin(p_pin, null);
  em := 'e-' || replace(uid::text, '-', '') || '@entreprises.suivi-treuil.fr';
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em,
    extensions.crypt(sec, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true), 'email', uid::text, now(), now(), now());
  insert into public.profiles (id, email, nom, role, lots, taches) values (uid, em, trim(p_nom), p_role, coalesce(p_lots, '{}'), coalesce(p_taches, '{}'));
  insert into public.entreprise_secrets (id, code_hash, secret, code_clair) values (uid, extensions.crypt(p_pin, extensions.gen_salt('bf')), sec, p_pin);
  insert into public.journal (profile_id, nom, action, detail) values (auth.uid(), (select nom from public.profiles where id = auth.uid()), 'création entreprise', trim(p_nom));
  return uid;
end $$;

create or replace function public.admin_set_pin(p_id uuid, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as
$$ begin
  perform public.assert_admin();
  perform public.check_pin(p_pin, p_id);
  update public.entreprise_secrets set code_hash = extensions.crypt(p_pin, extensions.gen_salt('bf')), code_clair = p_pin, failed = 0, locked_until = null where id = p_id;
  if not found then raise exception 'Entreprise inconnue.'; end if;
  insert into public.journal (profile_id, nom, action, detail) values (auth.uid(), (select nom from public.profiles where id = auth.uid()), 'changement de code', (select nom from public.profiles where id = p_id));
end $$;

drop function if exists public.admin_update_entreprise(uuid, text, text, text[], boolean);
create or replace function public.admin_update_entreprise(p_id uuid, p_nom text, p_role text, p_lots text[], p_actif boolean, p_taches text[] default '{}') returns void
language plpgsql security definer set search_path = public as
$$ begin
  perform public.assert_admin();
  if p_id = auth.uid() and (p_role <> 'admin' or not p_actif) then raise exception 'Vous ne pouvez pas retirer vos propres droits d''administrateur.'; end if;
  if p_role not in ('admin', 'saisie', 'cons') then raise exception 'Rôle invalide.'; end if;
  update public.profiles set nom = trim(p_nom), role = p_role, lots = coalesce(p_lots, '{}'), taches = coalesce(p_taches, '{}'), actif = p_actif where id = p_id;
  if not p_actif then
    begin delete from auth.sessions where user_id = p_id; exception when others then null; end;
  end if;
  insert into public.journal (profile_id, nom, action, detail) values (auth.uid(), (select nom from public.profiles where id = auth.uid()), 'modification entreprise', trim(p_nom));
end $$;

create or replace function public.admin_get_code(p_id uuid) returns text
language plpgsql security definer set search_path = public as
$$ declare c text; begin
  perform public.assert_admin();
  select code_clair into c from public.entreprise_secrets where id = p_id;
  insert into public.journal (profile_id, nom, action, detail) values (auth.uid(), (select nom from public.profiles where id = auth.uid()), 'code affiché', (select nom from public.profiles where id = p_id));
  return c;
end $$;

-- ---------- Activité (administrateur) ----------
create or replace function public.admin_activite() returns table (
  id uuid, nom text, role text, actif boolean, last_login timestamptz,
  nb_connexions bigint, nb_connexions_7j bigint, nb_echecs_7j bigint,
  nb_releves bigint, nb_releves_7j bigint, dernier_releve timestamptz, nb_photos bigint, nb_fiches bigint, bloque_jusqua timestamptz)
language plpgsql stable security definer set search_path = public as
$$ begin
  perform public.assert_admin();
  return query
  select p.id, p.nom, p.role, p.actif, p.last_login,
    (select count(*) from public.journal j where j.profile_id = p.id and j.action = 'connexion'),
    (select count(*) from public.journal j where j.profile_id = p.id and j.action = 'connexion' and j.at > now() - interval '7 days'),
    (select count(*) from public.journal j where j.profile_id = p.id and j.action = 'échec code' and j.at > now() - interval '7 days'),
    (select count(*) from public.releves r where r.by = p.id),
    (select count(*) from public.releves r where r.by = p.id and r.at > now() - interval '7 days'),
    (select max(r.at) from public.releves r where r.by = p.id),
    (select coalesce(sum(cardinality(r.photos)), 0) from public.releves r where r.by = p.id),
    (select count(*) from public.journal j where j.profile_id = p.id and j.action = 'fiche'),
    (select s.locked_until from public.entreprise_secrets s where s.id = p.id and s.locked_until > now())
  from public.profiles p order by p.nom;
end $$;

revoke all on function public.list_entreprises() from public;
revoke all on function public.pin_login(uuid, text) from public;
grant execute on function public.list_entreprises() to anon, authenticated;
grant execute on function public.pin_login(uuid, text) to anon, authenticated;
do $g$ declare f text; begin
  foreach f in array array['public.admin_create_entreprise(text,text,text,text[],text[])','public.admin_set_pin(uuid,text)',
    'public.admin_update_entreprise(uuid,text,text,text[],boolean,text[])','public.admin_activite()','public.admin_get_code(uuid)','public.assert_admin()','public.check_pin(text,uuid)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $g$;

-- ---------- Règles d'accès (RLS) ----------
alter table public.profiles    enable row level security;
alter table public.invitations enable row level security;
alter table public.task_lots   enable row level security;
alter table public.zone_attrs  enable row level security;
alter table public.releves     enable row level security;
alter table public.config      enable row level security;
alter table public.entreprise_secrets enable row level security;
alter table public.journal     enable row level security;

drop policy if exists p_journal_admin on public.journal;
create policy p_journal_admin on public.journal for select to authenticated using (public.my_role() = 'admin');

drop policy if exists p_profiles_read  on public.profiles;
drop policy if exists p_profiles_admin on public.profiles;
create policy p_profiles_read  on public.profiles for select to authenticated using (id = auth.uid() or public.is_active());
create policy p_profiles_admin on public.profiles for update to authenticated using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

drop policy if exists p_inv_admin on public.invitations;
create policy p_inv_admin on public.invitations for all to authenticated using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

drop policy if exists p_tl_read on public.task_lots;
create policy p_tl_read on public.task_lots for select to authenticated using (true);

drop policy if exists p_za_read  on public.zone_attrs;
drop policy if exists p_za_write on public.zone_attrs;
create policy p_za_read  on public.zone_attrs for select to authenticated using (public.is_active());
create policy p_za_write on public.zone_attrs for all to authenticated using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

drop policy if exists p_rel_read   on public.releves;
drop policy if exists p_rel_insert on public.releves;
drop policy if exists p_rel_delete on public.releves;
create policy p_rel_read   on public.releves for select to authenticated using (public.is_active());
create policy p_rel_insert on public.releves for insert to authenticated
  with check (public.my_role() = 'admin' or (public.my_role() = 'saisie' and (lot = any(public.my_lots()) or task_id = any(public.my_taches()))));
create policy p_rel_delete on public.releves for delete to authenticated using (public.my_role() = 'admin');

drop policy if exists p_cfg_read  on public.config;
drop policy if exists p_cfg_write on public.config;
create policy p_cfg_read  on public.config for select to authenticated using (public.is_active());
create policy p_cfg_write on public.config for update to authenticated using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- ---------- Photos (stockage privé) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', false, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists p_photos_read   on storage.objects;
drop policy if exists p_photos_insert on storage.objects;
drop policy if exists p_photos_delete on storage.objects;
create policy p_photos_read   on storage.objects for select to authenticated using (bucket_id = 'photos' and public.is_active());
create policy p_photos_insert on storage.objects for insert to authenticated with check (bucket_id = 'photos' and public.my_role() in ('admin','saisie'));
create policy p_photos_delete on storage.objects for delete to authenticated using (bucket_id = 'photos' and public.my_role() = 'admin');

-- =====================================================================
-- Compte administrateur GBMP : remplacez 1234 par VOTRE CODE à 4 chiffres
-- (créé une seule fois ; ensuite, changez les codes depuis l'application)
-- =====================================================================
do $$ begin
  if not exists (select 1 from public.profiles p join public.entreprise_secrets s on s.id = p.id where p.role = 'admin') then
    perform public.admin_create_entreprise('GBMP', '1234', 'admin', '{}');   -- ← VOTRE CODE
  end if;
end $$;

-- Vérification : 51 tâches et au moins 1 entreprise.
select (select count(*) from public.task_lots) as nb_taches, (select count(*) from public.list_entreprises()) as nb_entreprises;
