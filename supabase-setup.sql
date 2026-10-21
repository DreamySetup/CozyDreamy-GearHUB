-- Run this once in Supabase Dashboard > SQL Editor for the GearHub project.
create table if not exists public.gear_posts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  author text not null default 'Anonymous' check (char_length(author) <= 40),
  title text not null default '' check (char_length(title) <= 120),
  image text not null default '',
  body text not null default '' check (char_length(body) <= 5000),
  score integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.gear_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.gear_posts(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  author text not null default 'Anonymous' check (char_length(author) <= 40),
  text text not null check (char_length(text) between 1 and 800),
  created_at timestamptz not null default now()
);

create table if not exists public.gear_votes (
  post_id uuid not null references public.gear_posts(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  value smallint not null check (value in (-1, 1)),
  primary key (post_id, owner_id)
);

create index if not exists gear_posts_created_at_idx on public.gear_posts (created_at desc);
create index if not exists gear_comments_post_id_created_at_idx on public.gear_comments (post_id, created_at);

alter table public.gear_posts enable row level security;
alter table public.gear_comments enable row level security;
alter table public.gear_votes enable row level security;

drop policy if exists "Anyone can read gear posts" on public.gear_posts;
create policy "Anyone can read gear posts"
  on public.gear_posts for select to anon, authenticated using (true);

drop policy if exists "Visitors can create their own gear posts" on public.gear_posts;
create policy "Visitors can create their own gear posts"
  on public.gear_posts for insert to authenticated with check (owner_id = (select auth.uid()));

drop policy if exists "Post owners can delete within five hours" on public.gear_posts;
create policy "Post owners can delete within five hours"
  on public.gear_posts for delete to authenticated
  using (owner_id = (select auth.uid()) and created_at >= now() - interval '5 hours');

drop policy if exists "Anyone can read gear comments" on public.gear_comments;
create policy "Anyone can read gear comments"
  on public.gear_comments for select to anon, authenticated using (true);

drop policy if exists "Visitors can add comments" on public.gear_comments;
create policy "Visitors can add comments"
  on public.gear_comments for insert to authenticated with check (owner_id = (select auth.uid()));

drop policy if exists "Anyone can read gear votes" on public.gear_votes;
create policy "Anyone can read gear votes"
  on public.gear_votes for select to anon, authenticated using (true);

drop policy if exists "Visitors can cast their own votes" on public.gear_votes;
create policy "Visitors can cast their own votes"
  on public.gear_votes for insert to authenticated with check (owner_id = (select auth.uid()));

drop policy if exists "Visitors can change their own votes" on public.gear_votes;
create policy "Visitors can change their own votes"
  on public.gear_votes for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));

drop policy if exists "Visitors can remove their own votes" on public.gear_votes;
create policy "Visitors can remove their own votes"
  on public.gear_votes for delete to authenticated using (owner_id = (select auth.uid()));

grant select, insert, delete on public.gear_posts to anon, authenticated;
grant select, insert on public.gear_comments to anon, authenticated;
grant select, insert, update, delete on public.gear_votes to anon, authenticated;

create or replace function public.set_gear_post_score()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if TG_OP = 'INSERT' then
    update public.gear_posts
      set score = score + NEW.value
      where id = NEW.post_id;
    return NEW;
  elsif TG_OP = 'DELETE' then
    update public.gear_posts
      set score = score - OLD.value
      where id = OLD.post_id;
    return OLD;
  else
    update public.gear_posts
      set score = score - OLD.value + NEW.value
      where id = NEW.post_id;
    return NEW;
  end if;
end;
$$;

drop trigger if exists gear_votes_update_score on public.gear_votes;
create trigger gear_votes_update_score
  after insert or update or delete on public.gear_votes
  for each row execute function public.set_gear_post_score();

create or replace function public.cast_gear_vote(p_post_id uuid, p_value smallint)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign-in is required to vote.';
  end if;

  if p_value is null then
    delete from public.gear_votes
      where post_id = p_post_id and owner_id = (select auth.uid());
  elsif p_value in (-1, 1) then
    insert into public.gear_votes (post_id, owner_id, value)
      values (p_post_id, (select auth.uid()), p_value)
      on conflict (post_id, owner_id)
      do update set value = excluded.value;
  else
    raise exception 'Vote value must be -1, 1, or null.';
  end if;
end;
$$;

grant execute on function public.cast_gear_vote(uuid, smallint) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'gear_posts'
  ) then
    alter publication supabase_realtime add table public.gear_posts;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'gear_comments'
  ) then
    alter publication supabase_realtime add table public.gear_comments;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'gear_votes'
  ) then
    alter publication supabase_realtime add table public.gear_votes;
  end if;
end;
$$;
