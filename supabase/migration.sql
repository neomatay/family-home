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

-- ============================================================
-- v0.4 猫角桥接（2026-11-08）
-- cat_link：把猫猫健康的家庭 UUID 挂在「家」名下，实现
-- 「全家凭邀请码进家 → 猫角 iframe 自动登录」。
-- 前端逻辑（index.html 猫角块）：进猫角先 GET 本表取钥匙写入
-- localStorage（同域 iframe 共享）再加载；本机若已持有钥匙则
-- POST upsert 上云。写入用 upsert —— POST cat_link?on_conflict=family_id
-- 并带 Prefer: resolution=merge-duplicates,return=minimal。
-- ⚠️ 知情决策：cat_health_family_id 是 cat-health 的唯一口令，
-- 入库后邀请码即同时解锁猫猫健康数据（一把钥匙开全家，有意为之）。
-- ============================================================

create table public.cat_link (
  family_id     uuid primary key references public.families(id) on delete cascade,
  cat_family_id text not null,
  updated_at    timestamptz not null default now()
);

alter table public.cat_link enable row level security;
create policy "cat_link all" on public.cat_link for all
  using (family_id = public.current_family_id())
  with check (family_id = public.current_family_id());

-- ============================================================
-- v0.5 书房：周末新鲜事（2026-11-09）
-- weekend_events：两个人的周末手账 —— 记下想干的事、定日子、
-- 做完打个回味，攒够数据书房长出「回顾」（频次 × 回味分析）。
-- 前端逻辑（index.html 书房块）：
--   status   'idea' 想做（event_date 为空，泡在想做池）
--            'plan' 定了（有日子）
--            'done' 做了（rating 可打：1 不值 / 2 一般 / 3 值得）
--            'skip' 没去成
--   kind     固定枚举（前端 KINDS 12 项 + other），具体内容在
--            title —— kind 收敛成有限集是「回顾」能做分析的前提
--   time_seg 上午/下午/晚上/全天（可空）
--   member_id 谁提的（可空，为分析预埋）
-- 普通写操作（insert / patch / delete），无唯一约束，不需要 upsert。
-- ============================================================

create table public.weekend_events (
  id          bigint generated always as identity primary key,
  family_id   uuid not null references public.families(id) on delete cascade,
  title       text not null,
  kind        text not null default 'other',
  event_date  date,
  time_seg    text,
  status      text not null default 'idea' check (status in ('idea','plan','done','skip')),
  rating      int check (rating between 1 and 3),
  member_id   bigint references public.members(id) on delete set null,
  note        text not null default '',
  created_by  bigint,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table public.weekend_events enable row level security;
create policy "weekend_event all" on public.weekend_events for all
  using (family_id = public.current_family_id())
  with check (family_id = public.current_family_id());

create index on public.weekend_events (family_id);
create index on public.weekend_events (family_id, event_date);

-- ============================================================
-- v0.5.1（2026-11-10）：weekend_kinds —— 家庭自定义「新鲜事类型」
-- 内置 12 类不够用时，家庭可自建类型（两人共享同一套词表）。
-- weekend_events.kind 直接存类型名（label 文本）：
--   · 内置类型存枚举 key（out/expo/...）
--   · 自定义类型存 label 本身
-- 前端 kindLabel() 找不到内置 key 时原样显示 —— 所以删表前的
-- 旧数据、甚至类型被删后遗留的 kind 值都能显示，不会丢字。
-- 约束：label 1–12 字，家庭内唯一（unique）；有事件在用的类型
-- 前端禁止删除（先改事件）；改名会连带 PATCH 事件一起改。
-- 普通写操作，无 upsert。RLS 同其他家庭表。
-- ============================================================

create table public.weekend_kinds (
  id          bigint generated always as identity primary key,
  family_id   uuid not null references public.families(id) on delete cascade,
  label       text not null check (char_length(label) between 1 and 12),
  created_by  bigint,
  created_at  timestamptz not null default now(),
  unique (family_id, label)
);

alter table public.weekend_kinds enable row level security;
create policy "weekend_kind all" on public.weekend_kinds for all
  using (family_id = public.current_family_id())
  with check (family_id = public.current_family_id());

create index on public.weekend_kinds (family_id);

-- ============================================================
-- v0.6（2026-11-11）：birthdays —— 玄关「生日挂念」
-- 记朋友和孩子们的生日，农历/公历都有，每年自动对准公历日期。
--   cal   'lunar' 农历（大多数）/ 'solar' 公历
--   bm/bd 生日月、日。农历：bm 1–12（只存正常月，遇闰月年按
--         正常月过），bd 1–30（腊月三十在无三十的年自动过廿九，
--         前端 clamp）；公历：bm 1–12，bd 1–31（前端按月校验）
--   birth_year 可空：出生年（算周岁用）
--   relation  自由短文本（朋友/孩子/侄女…）
--   note      礼物想法、备注
-- 农历→公历换算在前端完成（index.html 内嵌 1900–2100 压缩历表，
-- 已用春节/中秋/端午/重阳/腊八/除夕/闰月等 38+ 锚点验证），云端
-- 不存换算结果 —— 生日是「每年重复的规则」，不是一次性日期。
-- 普通写操作，无 upsert。RLS 同其他家庭表。
-- ============================================================

create table public.birthdays (
  id          bigint generated always as identity primary key,
  family_id   uuid not null references public.families(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 24),
  cal         text not null default 'lunar' check (cal in ('lunar','solar')),
  bm          int not null check (bm between 1 and 12),
  bd          int not null check (bd between 1 and 31),
  birth_year  int,
  relation    text not null default '',
  note        text not null default '',
  created_by  bigint,
  created_at  timestamptz not null default now()
);

alter table public.birthdays enable row level security;
create policy "birthday all" on public.birthdays for all
  using (family_id = public.current_family_id())
  with check (family_id = public.current_family_id());

create index on public.birthdays (family_id);

-- ============================================================
-- v0.6.1（2026-11-12）：reservations —— 预定改「任意日期 + 餐段」
-- 原来只能选今天/明天/后天，且记具体时间（18:30）；现在日期随便
-- 选，时间改成餐段 meal（早餐/午餐/晚餐/夜宵）。time 列删除。
-- 已有行（如果将来有人带着旧数据跑这段）：按"几点算哪顿"归到
-- 餐段 —— <05:00 夜宵（凌晨） / <10:00 早餐 / <15:00 午餐 /
-- <21:00 晚餐 / 其余 夜宵。
-- ============================================================

alter table public.reservations add column if not exists meal text not null default '晚餐'
  check (meal in ('早餐','午餐','晚餐','夜宵'));

update public.reservations set meal = case
  when time < '05:00' then '夜宵'
  when time < '10:00' then '早餐'
  when time < '15:00' then '午餐'
  when time < '21:00' then '晚餐'
  else '夜宵'
end
where time is not null;

alter table public.reservations drop column if exists time;
