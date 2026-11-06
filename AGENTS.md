# AGENTS.md · 家庭伙伴「家」开发指南

> 任何开发者（人或 AI Agent）在动手改这个仓库之前，请先通读本文。产品定义见 [docs/PRD-v0.1.md](docs/PRD-v0.1.md)。

## 项目是什么

两个人的家（和三只猫）的家庭协作应用：**手机网页，首页是一栋可点击的矢量剖面小房子（room tour），点房间进功能**。v0.1–v0.3 已点亮：厨房（家庭餐厅：上架菜/预定/接单）、冰箱与库存、购物清单（玄关）、卧室（生理期记录：日期/周期稳定性/预计下次）。书房（账本）、猫角（猫猫管家）在二期池。

- 线上：https://neomatay.github.io/family-home/
- 仓库：https://github.com/neomatay/family-home
- 用户：两个女生 + 三只猫；数据是**家庭隐私**

## 技术形态（刻意的，别"升级"它）

- **单文件 `index.html`**（~1200 行），无构建、无依赖、无框架。这是产品决策：先以最直接的手机网页形式落地，未来可平移微信小程序/App。加构建工具链之前先和维护者讨论。
- 字体走 Google Fonts（Noto Sans SC + ZCOOL XiaoWei），其余全内联。
- JS 是 ES5 风格（`var` / `function` / 字符串拼 HTML）——**保持风格一致**，不要局部引入 ES Module / JSX。
- 渲染：状态 → `render()` 全量重画（数据量小，够用）。事件用委托：`[data-act]` / `[data-nav]`。

## 架构分层

```
index.html
├── CSS tokens（明暗三态主题）
├── <svg> 矢量小家（交互层：.hot 热区 + 状态圆点）
├── 视图 section（#v-join 进门 / #v-home / #v-kitchen / #v-fridge / #v-list / #v-cycle）
└── <script>（AUTH/D/UI 状态 + api() REST 层 + render + 事件）
supabase/migration.sql  七张表 + RLS + 校验函数（v0.2 段之后是追加段）
docs/PRD-v0.1.md        产品定义
```

美术方案是「分层皮肤」：交互层（代码画的 SVG，热区固定）+ 背景层（未来可换 AI 整图皮肤），**换皮不许动热区坐标**。

## 数据与安全模型（最重要的部分）

**家庭 = 租户，邀请码 = 唯一口令。** 没有用户系统、没有邮箱注册：创建家时生成 10 位邀请码（无易混淆字符），另一台手机输码加入。前端持 publishable key（公开放入仓库是**设计而非事故**，安全靠服务端 RLS）。

RLS 校验：每个请求带 `x-family-id` + `x-family-code` 两个头，服务端 `public.current_family_id()` 比对 `families.invite_code`；`rpc/join_family(code)` 只暴露 id/name。**service_role / secret key 永远不许出现在前端。**

### 两条硬约定（都是实测 42501 踩出来的坑）

1. **子表 INSERT 必须显式带 `family_id`**。members/dishes/inventory/reservations/shopping/periods 的策略是 `with check (family_id = current_family_id())`，NULL 永远不成立 → 42501。
2. **families INSERT 必须 `Prefer: return=minimal`**。`return=representation` 要求新行同时过 SELECT 策略（此时还没有 fid）→ 42501。fid 用 `rpc/join_family` 凭码取回。应用里 `createGo()` 就是这两步的参考实现。
3. **periods 写入用 upsert**：`POST periods?on_conflict=family_id,member_id,start_date` + `Prefer: resolution=merge-duplicates,return=minimal`。同人同一天重复记/批量补录不会报错，只更新备注（表上有对应唯一索引）。

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
- toast 只做轻提示；破坏性操作用两段式按钮（`data-armed`），不用 confirm()。

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

## 二期池（优先级从高到低）

1. realtime 同步（替换 60s 轮询）
2. 预定的拒绝/换人流转
3. 猫猫管家（猫角：档案/用药/猫粮猫砂库存）
4. 卧室健康扩展（体重体脂/训练 —— 生理期记录已上线）
5. 账本（书房）
6. AI 插画皮肤（替换矢量背景层）
7. 真·AI 营养估算
