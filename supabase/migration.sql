-- ============================================================
-- 家庭伙伴「家」v0.2 · 云端迁移
-- 在 Supabase Dashboard → SQL Editor 中运行
--
-- 客户端两条硬约定（写代码前必读，详见仓库 AGENTS.md）：
-- 1. 子表（members/dishes/inventory/reservations/shopping）INSERT
--    必须显式带 family_id —— 策略 with check 对 NULL 永远不成立
-- 2. families INSERT 必须 Prefer: return=minimal（representation 会
--    被 SELECT 策略拒绝 42501），fid 靠 rpc/join_family 凭码取回
-- ============================================================

-- ---------- 表 ----------
create table public.families (
  id          uuid primary key default gen_random_uuid(),
  name        text not null default '我们的家',
  invite_code text not null unique,
  created_at  timestamptz not null default now()
);

create table public.members (
  id        bigint generated always as identity primary key,
  family_id uuid not null references public.families(id) on delete cascade,
  name      text not null,
  color     text not null default '#D0832F',
  sort      int  not null default 0
);

create table public.dishes (
  id           bigint generated always as identity primary key,
  family_id    uuid not null references public.families(id) on delete cascade,
  name         text not null,
  servings     int  not null default 2,
  ingredients  jsonb not null default '[]',
  nutri        jsonb,
  est          boolean not null default true,
  cooks        bigint[] not null default '{}',
  times_cooked int not null default 0,
  created_by   bigint,
  created_at   timestamptz not null default now()
);

create table public.inventory (
  id         bigint generated always as identity primary key,
  family_id  uuid not null references public.families(id) on delete cascade,
  name       text not null,
  cat        text not null default 'food' check (cat in ('food','daily','cat')),
  qty        numeric not null default 0,
  unit       text not null default '个',
  low        numeric not null default 0,
  updated_at timestamptz not null default now()
);

create table public.reservations (
  id         bigint generated always as identity primary key,
  family_id  uuid not null references public.families(id) on delete cascade,
  dish_id    bigint not null references public.dishes(id) on delete cascade,
  date       date not null,
  time       text not null default '18:30',
  cook_id    bigint,
  created_by bigint,
  created_at timestamptz not null default now()
);

create table public.shopping (
  id         bigint generated always as identity primary key,
  family_id  uuid not null references public.families(id) on delete cascade,
  name       text not null,
  note       text not null default '',
  done       boolean not null default false,
  created_by bigint,
  created_at timestamptz not null default now()
);

-- ---------- 家庭口令校验：请求头 x-family-id + x-family-code ----------
create or replace function public.current_family_id() returns uuid
language sql stable security definer set search_path = public as $$
  select f.id
  from public.families f
  where f.id::text = coalesce(current_setting('request.headers', true)::json ->> 'x-family-id', '')
    and f.invite_code = current_setting('request.headers', true)::json ->> 'x-family-code'
$$;

-- 加入家庭：凭邀请码查家（只暴露 id 和名字，凭码进门）
create or replace function public.join_family(p_code text)
returns table (id uuid, name text)
language sql stable security definer set search_path = public as $$
  select f.id, f.name from public.families f where f.invite_code = p_code
$$;

-- ---------- RLS ----------
alter table public.families     enable row level security;
alter table public.members      enable row level security;
alter table public.dishes       enable row level security;
alter table public.inventory    enable row level security;
alter table public.reservations enable row level security;
alter table public.shopping     enable row level security;

-- 家：凭码读写自己的行；创建新家允许匿名插入（邀请码至少 8 位）
create policy "family read"  on public.families for select using (id = public.current_family_id());
create policy "family insert" on public.families for insert with check (char_length(invite_code) >= 8);

create policy "member all"      on public.members      for all using (family_id = public.current_family_id()) with check (family_id = public.current_family_id());
create policy "dish all"        on public.dishes       for all using (family_id = public.current_family_id()) with check (family_id = public.current_family_id());
create policy "inventory all"   on public.inventory    for all using (family_id = public.current_family_id()) with check (family_id = public.current_family_id());
create policy "reservation all" on public.reservations for all using (family_id = public.current_family_id()) with check (family_id = public.current_family_id());
create policy "shopping all"    on public.shopping     for all using (family_id = public.current_family_id()) with check (family_id = public.current_family_id());

-- ---------- 索引 ----------
create index on public.members      (family_id);
create index on public.dishes       (family_id);
create index on public.inventory    (family_id);
create index on public.reservations (family_id);
create index on public.shopping     (family_id);

-- ============================================================
-- ▼▼▼ v0.3 · 卧室：生理期记录（追加段，2026-11-06）▼▼▼
-- 已运行过上面 v0.2 的库：只需复制本标记以下的内容到 SQL Editor 运行
--
-- 客户端约定（写代码前必读）：
-- 3. periods 写入用 upsert —— POST periods?on_conflict=family_id,member_id,start_date
--    并带 Prefer: resolution=merge-duplicates,return=minimal，
--    同一人同一天重复记/补录不会报错，只会更新备注
-- ============================================================

create table public.periods (
  id         bigint generated always as identity primary key,
  family_id  uuid not null references public.families(id) on delete cascade,
  member_id  bigint not null references public.members(id) on delete cascade,
  start_date date not null,
  note       text not null default '',
  created_by bigint,
  created_at timestamptz not null default now()
);

alter table public.periods enable row level security;
create policy "period all" on public.periods for all
  using (family_id = public.current_family_id())
  with check (family_id = public.current_family_id());

create unique index on public.periods (family_id, member_id, start_date);
create index on public.periods (family_id);

-- 家庭删除：凭码可删自己的家（级联清空子表）—— 也用于清理冒烟测试残留
create policy "family delete" on public.families for delete
  using (id = public.current_family_id());
