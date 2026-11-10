# AGENTS.md · 家庭伙伴「家」开发指南

> 任何开发者（人或 AI Agent）在动手改这个仓库之前，请先通读本文。产品定义见 [docs/PRD-v0.1.md](docs/PRD-v0.1.md)。

## 项目是什么

两个人的家（和三只猫）的家庭协作应用：**手机网页，首页是一栋可点击的矢量剖面小房子（room tour），点房间进功能**。v0.1–v0.5 已点亮：厨房（家庭餐厅：上架菜/预定/接单）、冰箱与库存、购物清单（玄关）、卧室（生理期记录：每月开始日格子/间隔趋势/折叠历史）、猫角（猫猫管家，嵌入 cat-health）、书房（周末新鲜事：记想做的事/定日子/做完打回味）。**整栋小家已无灰房间**；账本退回二期池（书房的位置让给了新鲜事）。

- 线上：https://neomatay.github.io/family-home/
- 仓库：https://github.com/neomatay/family-home
- 用户：两个女生 + 三只猫；数据是**家庭隐私**

## 技术形态（刻意的，别"升级"它）

- **单文件 `index.html`**（~1200 行），无构建、无依赖、无框架。这是产品决策：先以最直接的手机网页形式落地，未来可平移微信小程序/App。加构建工具链之前先和维护者讨论。
- 字体走 Google Fonts（Noto Sans SC + ZCOOL XiaoWei），其余全内联。
- 图标是仓库根目录的三个静态文件（`icon.svg` / `favicon.png` / `apple-touch-icon.png`），`<link>` 在 index.html 头部 —— 静态资产，不算"依赖"。改图标三份一起换（SVG 是矢量源，PNG 由脚本光栅化，色值取自首页小家的 SVG token）。
- JS 是 ES5 风格（`var` / `function` / 字符串拼 HTML）——**保持风格一致**，不要局部引入 ES Module / JSX。
- 渲染：状态 → `render()` 全量重画（数据量小，够用）。事件用委托：`[data-act]` / `[data-nav]`。**`el.dataset.*` 拿到的永远是字符串**——与数字 id 比对前必须 `parseInt`（曾因 `2==="2"` 让「编辑菜品」打开永远是空白新建态）。

## 架构分层

```
index.html
├── CSS tokens（明暗三态主题）
├── <svg> 矢量小家（交互层：.hot 热区 + 状态圆点）
├── 视图 section（#v-join 进门 / #v-home / #v-kitchen / #v-fridge / #v-list / #v-cycle / #v-study）
└── <script>（AUTH/D/UI 状态 + api() REST 层 + render + 事件）
supabase/migration.sql  十张表 + RLS + 校验函数（v0.2 段之后是追加段）
docs/PRD-v0.1.md        产品定义
```

美术方案是「分层皮肤」：交互层（代码画的 SVG，热区固定）+ 背景层（未来可换 AI 整图皮肤），**换皮不许动热区坐标**。

## 数据与安全模型（最重要的部分）

**家庭 = 租户，邀请码 = 唯一口令。** 没有用户系统、没有邮箱注册：创建家时生成 10 位邀请码（无易混淆字符），另一台手机输码加入。前端持 publishable key（公开放入仓库是**设计而非事故**，安全靠服务端 RLS）。

RLS 校验：每个请求带 `x-family-id` + `x-family-code` 两个头，服务端 `public.current_family_id()` 比对 `families.invite_code`；`rpc/join_family(code)` 只暴露 id/name。**service_role / secret key 永远不许出现在前端。**

### 两条硬约定（都是实测 42501 踩出来的坑）

1. **子表 INSERT 必须显式带 `family_id`**。members/dishes/inventory/reservations/shopping/periods 的策略是 `with check (family_id = current_family_id())`，NULL 永远不成立 → 42501。
2. **families INSERT 必须 `Prefer: return=minimal`**。`return=representation` 要求新行同时过 SELECT 策略（此时还没有 fid）→ 42501。fid 用 `rpc/join_family` 凭码取回。应用里 `createGo()` 就是这两步的参考实现。
3. **periods 写入用 upsert**：`POST periods?on_conflict=family_id,member_id,start_date` + `Prefer: resolution=merge-duplicates,return=minimal`。同人同一天重复记/批量导入不会报错，只更新备注（表上有对应唯一索引）。编辑一条记录 = 先 upsert 到新位置，若人/日期变了再 `DELETE periods?id=eq.<旧id>`（挪动；目标日已有记录时两条合并）。

## 同步策略

- **server-truth**：每次写操作 → 全量 refetch → 重画。不做乐观更新，不做 diff，两人并发以服务端为准。
- 触发：启动（先画 localStorage 缓存再拉）、`visibilitychange` 回前台、60s 轮询、每次写后。`busy` 标志防并发。
- realtime 未启用（二期池）。**不要悄悄加轮询频率**，Supabase 免费档有请求量限制。

## 前端约定

- **375px 移动端优先**，safe-area 全覆盖，无 hover 依赖（为小程序迁移留路）。
- 主题三态 token：`:root`（亮）+ `@media (prefers-color-scheme: dark)` + `:root[data-theme="dark"]`，所有颜色走 `var(--*)`，组件规则里**不许出现字面色**。
- **状态呈现只用小圆点/角标**，不用彩色左边条（产品品味，参考 yetone/magpie 的克制风格）。
- 新房间上线 = SVG 加一个 `<rect class="hot" data-nav="...">` + 一个 `<section class="view" id="v-...">` + `TITLES` 注册；没上线的房间保持置灰 +「还没有整理好」。
- localStorage 只存三样：`jia-auth-v2`（口令）、`jia-cache-v2`（首屏缓存）、`jia-theme`。**业务数据一律在云端**。
- toast 只做轻提示；破坏性操作用两段式按钮（`data-armed`），不用 confirm()。待确认状态在点击页面任何其他地方时自动解除（`disarmAll`），不允许把用户困在「确认」里。
- 生理期列表行的删除不在行上，而是点行进编辑弹层，删除按钮在弹层里（点遮罩/✕ 即无害退出）。

## 嵌入式房间（猫角 = cat-health）

猫角**不是本仓库实现的功能**：它是一个同源 iframe，加载 `https://neomatay.github.io/cat-health/`（独立仓库 neomatay/cat-health，Vue3 + ECharts + supabase-js，数据在它**自己的** Supabase 项目 pvprdtfkqqxkwxvstzuo，家庭 UUID 即口令；另有 iOS 原生 App 共用该库）。

- **两个应用同域**（neomatay.github.io），共用 localStorage —— `cat_health_family_id` 登录态直接带进 iframe，无需二次进门。
- **钥匙桥接（v0.4，第 8 张表 `cat_link`）**：把猫猫健康的家庭 UUID 存进「家」的云端，`catPull()` 进猫角先取钥匙写 localStorage 再加载 iframe（自动分发）；`catPush()` 本机持有钥匙时 upsert 上云（自动捕获，`on_conflict=family_id` + merge-duplicates）。**⚠️ 安全边界：桥接后邀请码同时解锁猫猫健康数据 —— 用户知情并拍板过的决策，别"修"它。** 桥接所有请求静默失败（不 toast 不阻塞），表未建/网络问题都退回「手动进门」旧行为。
- **代码不搬**：cat-health 的功能永远不移植进本仓库单文件（会破坏零依赖纪律）；本仓库也不碰它的数据层。
- **iframe 常驻**：`renderCat()` 用 `dataset.booted` 保证只加载一次，切走视图只是隐藏，猫猫健康的滚动/弹层状态不丢。
- **主题桥接**：`catTheme()` 把「家」的三态主题写进 iframe 的 `documentElement.dataset.theme`（无值=跟随系统）；cat-health 侧 v2.7+ 的皮肤已按同一套暖色 token 对齐（见其 style.css 头注）。跨源（本地调试）时 try/catch 静默跳过。
- 本地调试 `http://<Mac IP>:8924` 时 iframe 指向线上 URL，跨源属预期，只有主题桥接不可用。

## 书房 · 周末新鲜事（weekend_events）

记录两个人每个周末做的事，攒数据给将来的「回顾」分析。**分析靠字段收敛，这是设计核心**：

- `kind` = **内置枚举 key**（前端 `KINDS`，12 项 + other）或**家庭自定义类型名**（第 10 张表 `weekend_kinds.label` 原文，两人共享一套词表，v0.5.1）。**不是每件事的自由文本** —— 分析按 kind 值分组，自定义类型天然成组。约束：label 1–12 字、家庭内唯一；改名会连带 PATCH `weekend_events?kind=eq.旧名`；有事件在用的类型前端禁止删除。`kindLabel()` 找不到内置 key 时原样返回（遗留值不丢字）。具体内容写 `title`。
- 状态生命周期：`idea`（想做，`event_date` 为空 → 想做池）→ `plan`（定了日子）→ `done` / `skip`。做完可选 `rating`（1 不值 / 2 一般 / 3 值得）。「回味 × 频次」是将来回顾的核心数据 —— `rating` 和 `member_id` 是**为分析预埋的字段**，别删。
- 普通写操作，无唯一约束、不需要 upsert；PATCH 记得把 `updated_at` 放进 payload。
- 「眼前的周末」用 `thisWeekend()`：工作日指即将到来的周末，周六日指正在过的这个 —— **别用自然周**（周一看"本周末"必须是未来那个）。往事分组用 `weekendOf(iso)`（周六开头，工作日归上一个周六）。
- 「回顾」视图（类型频次 + 频次×回味四象限 + 发散）在 done ≥ 8 之后做；表结构已预埋，将来只加视图、不动数据。

## 营养估算

本地 `FOOD`（每 100g 热量/蛋白/碳水/脂肪）+ `UNIT_G`（单位→克）查表估算，UI 必须带「估算」标记。这是占位方案，正式版换真实 AI —— 接口预留：`estimate(ings, servings)` 签名不动，换实现即可。

## 开发流程（改代码必做）

```bash
# 1. 语法检查（唯一"测试"）
awk '/<script>/{f=1;next}/<\/script>/{f=0}f' index.html > /tmp/j.js && node --check /tmp/j.js

# 2. 本地手测
cd ~/IdeaProjects/family-home && python3 -m http.server 8924
# 手机访问 http://<Mac IP>:8924/index.html（注意：换网络后 Mac IP 会变）

# 3. 云端冒烟（动了 api()/migration 时）
KEY='sb_publishable_...'  # 在 index.html 顶部
BASE='https://irnjdlqqojjjunqyrvlw.supabase.co/rest/v1'
curl -s "$BASE/families?select=id" -H "apikey: $KEY" -H "Authorization: Bearer $KEY"   # 应返回 []
```

改了 `supabase/migration.sql` 时：迁移文件**只增不改**（线上库已跑过的语句重跑会报错），新增策略/函数用 `create or replace` 或新语句追加，并在本文登记约定。

## 部署（本网络环境的特殊路径）

当前开发网络 `github.com:443` 不通但 `api.github.com` 通，**git push 走不了**，用 Contents API 上传：

```bash
gh api --method PUT repos/neomatay/family-home/contents/index.html \
  -f message="deploy: <说明>" -f branch=main \
  -f content="$(base64 -i index.html | tr -d '\n')"
```

Pages 从 main 自动发布。⚠️ 本地 git 历史与远端不同源（API 上传造成的），网络恢复后先 `git fetch` 对齐，**不要强推**。

### ⚠️ 部署前必须先查远端（2026-11-09 踩过的坑）

远端**会收到本仓库之外的直接编辑**（维护者用 GitHub 网页编辑器或其他工具改过 index.html）。Contents API PUT 是整文件无脑覆盖 —— 本地没有的远端改动会被静默吃掉。曾因此把生理期月视图（远端 a6dfd47）覆盖丢失，靠 git blob 才抢救回来。**每次部署前：**

```bash
gh api "repos/neomatay/family-home/commits?per_page=10" --jq '.[].sha[0:7]'   # 有不认识的提交？
gh api repos/neomatay/family-home/contents/index.html --jq .content | base64 -d | diff - index.html
```
有远端独有改动 → 先移植进本地再部署。更新已存在的文件必须 GET 完整 40 位 blob sha 再 PUT（短 sha 会 409）。

## 二期池（优先级从高到低）

1. realtime 同步（替换 60s 轮询）
2. 预定的拒绝/换人流转
3. 书房「回顾」：类型频次 + 频次×回味四象限（done ≥ 8 就能做）
4. 猫角状态点：跨 iframe 读猫猫健康的今日待喂药（现阶段圆点仍是「冰箱猫用低库存」）
5. 卧室健康扩展（体重体脂/训练 —— 生理期记录已上线）
6. 账本（原书房让给了新鲜事，另找房住或书房开 tab）
7. AI 插画皮肤（替换矢量背景层）
8. 真·AI 营养估算
