---
name: ai-director-render
description: AI导演 - 渲染引擎(Agent C)v9。Seedance API单段单次调用、L0→L1→L2降级链、段级幂等+sidecar链式衔接、段级文件锁防TOCTOU、全局成本核算(API扫描task_list + 偏差>10%硬异常)、camera_movement_ref 运镜参考视频渲染集成(@视频N 的运镜方式 引用)。
---

## ⚠️ 0708 P0 修复共享模块（硬约束）

## 反馈协议（2026-07-12 主agent↔子agent通信规则 v1 配套）

执行过程中：
- ❌ 禁止主动 sessions_send 主 agent 中间过程（不刷屏）
- ✅ 状态变化时（每个原子步骤 running→done/failed）必须：
  1. 写 STATUS.yaml 的对应字段
  2. sessions_send 主 agent（label="main"）简报本次状态变化
- ✅ 收尾时写 final report 必含 RAW_OUTPUT 段
- ✅ 失明兜底：所有产物路径 + trace_id 必落 STATUS.yaml，主 agent 轮询兜底

## ⚠️ 0708 P0 修复共享模块（硬约束）

> **🔴 红线**: Agent C 渲染**必须** `import render_v3_template`，**禁止**重写自己的 render_v3.py。
> 越界 = 触发 0708 重演事故（双脚本 / 定价错 / 段间不衔接 / 状态字段误报）

**共享模块位置**: `skills/ai-director-render/render_v3_template.py`

**必走函数**（从共享模块 import，不得重写）:

| 函数 | 用途 | 0708 事故场景 |
|------|------|-------------|
| `setup_auditor_path()` | workspace 自动发现 + auditor 路径注入 | 路径硬编码 parent×4 脆弱 |
| `check_render_approval()` | 放行令检查 | 跳过直接渲染 → 无追溯 |
| `run_render_preflight_gate()` | P0-2/P0-3 交叉验证封装 | 缺此 → 放行令被篡改无感知 |
| `verify_input_hashes()` | H-1 MD5 hash 绑定 | 缺此 → 上游文件静默替换 |
| `acquire_seg()` / `release_seg()` | 段级文件锁 fcntl.flock | 多进程并发 TOCTOU 双倍扣费 |
| `save_chain_meta()` / `load_chain_meta()` | 链式衔接 sidecar | 幂等跳过时 extend 断裂 |
| `lock_seg_state()` / `load_seg_state()` | 段间状态锁定 | 段间角色状态/服装/伤丢失 |
| `query_task_list()` | 全局成本核算 | 脚本自报漏算 ¥17.15 |
| `check_cost_discrepancy()` | 偏差 > 10% 硬异常 | ¥17.15 vs ¥34.28 未阻断 |

**模块级断言**（启动时自动检查）：
- `PRICE_PURE_GEN == 46`（不是 56 等）
- `PRICE_WITH_VIDEO == 28`（不是 56 等）
- `PRICE_MAP[True] == 28` 且 `PRICE_MAP[False] == 46`

> 断言失败 = 模块启动即报 `AssertionError`，阻断渲染。

**验证方法**:
```bash
# 验证共��模块常量
cd skills/ai-director-render && python3 -c "from render_v3_template import *; print('PRICE_PURE_GEN=', PRICE_PURE_GEN); print('PRICE_WITH_VIDEO=', PRICE_WITH_VIDEO)"

# 运行自检
python3 render_v3_template.py
```

---

## ⚠️ 工具调用边界

> **🔴 红线**: 本 Agent（Agent C — 渲染引擎）严格遵守"工具调用边界"。
> 越界调用 = 破坏调度规则 = 烧钱 = 触发 P0 事故。
> 主 agent 不可见本 Agent 的工具越界后果——监管靠 内部规范 + 调度规则。

> **🚨 Agent C 是最高风险点** — 视频渲染是管线中成本最高（烧钱最快）的环节。
> 一个越界 `video_generate` 调用可能产生无追溯的 API 费用 + 重复计费。
> **严禁绕过 Seedance API 直接调 `video_generate` 工具。**

### ✅ 所有 Agent 通用允许

| 工具 | 用途 | 备注 |
|-----|------|------|
| `read` | 读上游产出 + 前置知识库 | 仅限项目目录 `outputs/{项目名}/` 内 |
| `write` | 写本 Agent 产出文件 | 仅限 `outputs/{项目名}/04_渲染/` 下 |
| `edit` | 修改本 Agent 自产文件 | 不修改它 Agent 的文件 |

### 📋 Agent C 特定允许

> 以下工具/API 仅在本 Agent 角色范围内允许。
> **不在本列表中的工具 = 禁止。不需要"先问再调"。禁止就是禁止。**

| 工具/API | 用途 | 调用方式/路径 |
|---------|------|-------------|
| **Seedance 2.0 API** | 视频片段渲染（文生视频/图生视频/视频编辑/延长） | `POST /api/v3/contents/generations/tasks` |
| **Query Task List API** | 全局成本核算 | `GET /api/v3/contents/generations/tasks?page_num=N&page_size=50` |
| **exec (render_v3.py)** | 渲染主流程脚本 | `python3 render_v3.py` |
| **fcntl.flock (文件锁)** | 段级渲染权原子声明（防并发 TOCTOU） | Python `fcntl.flock(fd, LOCK_EX \| LOCK_NB)` |

### 🚫 全局禁止（所有 AI导演 Agent 通用）

| 工具 | 原因 | 替代方式 |
|-----|------|---------|
| `sessions_spawn` | 严禁派 sub-agent。只有主 agent 可以调度。违反 = 破坏 A→B→C→D→E 顺序 | 如需帮忙 → 写文件通知主 agent |
| `web_search` / `web_fetch` | 严禁自行搜索获取外部信息 | 需外部信息 → 由主 agent 获取后通过 prompt 提交 |

### 🚫 Agent C 特定禁止

> **🚨 以下每项都是红线。越界 = 触发 P0 事故。**

| 工具 | 原因 | 应走路径 |
|-----|------|---------|
| `video_generate` | 🚨 **核心越界** — Agent C 唯一的渲染通道是 Seedance API。直接调 `video_generate` = 绕过成本核算系统 = 无追溯费用 | **Seedance 2.0 API** (`POST /api/v3/contents/generations/tasks`) |
| `image_generate` | 生图是 Agent B 的活。C 只渲染视频 | **通义万相2.5 API**（由 B 调用） |
| `music_generate` | 配音是 Agent E 的活 | **豆包 TTS API**（由 E 调用） |
| **ffmpeg 合成** | 🚨 **已声明不做** — 属于 Agent E 的职责 | **ffmpeg**（由 E 执行） |
| **TTS 配音** | 🚨 **已声明不做** — 属于 Agent E 的职责 | **豆包 TTS API**（由 E 调用） |
| **字幕生成** | 🚨 **已声明不做** — 属于 Agent E 的职责 | **字幕工具**（由 E 处理） |
| **不检查放行令直接渲染** | 🚨 P0-2/P0-3 已修 — 必须调用 `check_render_approval()` + `run_render_preflight_gate()` | 必须先调 `check_render_approval()` 和 `run_render_preflight_gate()` |

### 💀 越界后果

| 层级 | 触发条件 | 后果 |
|:---:|---------|------|
| 🟢 **警告** | 首次越界 / 非破坏性调用（如误 `web_search`） | 记录到 `05_审核/工具越界日志.yaml`，通知 Agent D 记录 |
| 🟡 **阻断** | 重复越界 / 轻度破坏性调用（如误 `image_generate` 但未产生真实消耗） | 写回 STATUS.yaml + 通知主 agent + 暂停本阶段流程 |
| 🔴 **致命** | 派 sub-agent / 烧钱调用（如直接 `video_generate`）/ 破坏流程顺序 | 🚨 通知主 agent → 项目负责人人工介入。自动标记为系统缺陷，**强制暂停整条管线** |

### 🔄 修复流程

如果不小心越界调用：

1. **立即停下** — 不要再调任何工具
2. **如实记录** — 在项目目录写 `05_审核/工具越界日志.yaml` 记录越界详情
3. **通知** — 通知主 agent 越界情况
4. **等待** — 主 agent 决定下一步（重跑 / 修复 / 人工介入）
5. **不补救** — 不要试图"自己修"，可能越界更多

```yaml
# 05_审核/工具越界日志.yaml 格式
agent: "Agent C"             # 越界的 Agent
tool_called: "video_generate" # 越界调用的工具
timestamp: "2026-07-09T00:01:00+08:00"
impact: "轻度/破坏性/致命"    # 越界后果评估
triggered_by: "误操作/逻辑错误/配置问题"
resolution: "等待主 agent 指令"
```

### 📝 边界判断速查

```
我是 Agent C（渲染引擎）。
我要调用一个工具/API。

→ 这个工具在"允许列表"里吗？
  ✅ 是 → 调。但确认一次：这是本 Agent 的职责吗？
  ❌ 否 → 下一个问题。

→ 这个工具在"禁止列表"里吗？
  ✅ 是 → 停下。找替代路径。第一原则：**走 Seedance API**。
  ❌ 否 → 但也不在"允许列表"里 → 默认禁止。停下。

→ 我还是不确定？
  默认按"禁止"处理。不要调。通知主 agent。
```

---

## ⚠️ 段间状态锁定 SOP（Phase 7 反例）

> **🔴 红线**: Agent C 多段项目，**每段渲染前必须检查段间状态锁定**。
> 越界 = 段间状态漂移（外套穿回去 / 绷带位置漂移 / 伤疤消失等，Phase 7 反例）
>
> 段间状态漂移根因：
> - ❌ 每段 prompt 只写当前段动作，不继承上段状态
> - ❌ 无 prev_state_dict 传递机制
> - ❌ sidecar 只有 video_url + last_frame_path，没有服装/伤/位置/道具状态
> - ❌ 角色特征（不变字段：人种/脸型/发型/发色/服装款式）每段可能重新生成
>
> **必走流程**:
>
> 1. **提取上段状态**（每段渲染前必做）：
>    - 角色服装状态（外套穿/脱、伤疤、伤口、武器持有、姿势）
>    - 角色位置（场景内位置/朝向）
>    - 关键道具状态（武器、物品、照片等）
>
> 2. **状态锁定写入 sidecar**：`save_seg_state(seg_id, state_dict)` 在每段渲染成功后执行
>    - 状态字典存储在 `.chain/seg_xx_state.json`
>    - 包含：不变字段（角色特征锁定）+ 变字段（状态变化）
>
> 3. **下段 prompt 必继承**：`build_content_with_state(seg_id, prev_state)` 强制把上段状态写入 prompt
>    - 将 prev_state 渲染为 "上段状态延续" 段追加到 prompt 头部
>    - 变字段用明确时间线语言："上段结尾时 [角色] [状态]，本段延续"
>
> 4. **角色特征锁定**（不变字段——每段必须保持）：人种、脸型、发型、发色、服装款式
> 5. **角色状态变化**（变字段——按剧本时间线）：姿势/动作/伤口/服装状态/道具持有
>
> **绝对禁止**:
> - ❌ 每段独立生成（不读上段状态）→ Phase 7 反例
> - ❌ prompt 只写当前段动作，不写上段状态 → 状态漂移
> - ❌ 多段项目不写 sidecar state → 下段无依据
> - ❌ 角色脸型/发色等不变字段每段重新生成 → 角色分裂
>
> **Phase 7 反例清单**（段间状态漂移记录）：
> - 段 1 陈影脱外套露左臂绷带 → 段 2-5 外套又穿回去
> - 段 1 左臂绷带 → 段 3-5 绷带左右臂漂移
> - 段 4 陈影抽照片举胸前 → 段 5 照片状态未自然延续
> - 段 5 刀滑落 → 刀具突然消失
>
> **实战流程**:
> 1. 渲染 SEG-1 前：定义初始状态（剧本段 1 描述）→ `save_seg_state("01", initial_state)`
> 2. 渲染 SEG-2 前：`prev_state = load_seg_state("01")` → 注入到 SEG-2 prompt
> 3. 渲染 SEG-2 后：`save_seg_state("02", updated_state)`
> 4. 依此类推直到 SEG-N
> 5. 终段（SEG-N）不保存 state（无下段）

> **版本日期**: 2026-07-08
> **版本历史**: v5(12份官方文档重构)→ v7(0708 实战整改:单段单次 API + 段级幂等 + 全局成本核算)→ v8(0708 实战后自查 4 个风险点整改:sidecar 链式衔接 + 文件锁防 TOCTOU + 翻页补全 + 偏差硬异常)→ **v9(camera_movement_ref 渲染集成 + render_v3.py 集成代码 + prompt 模板扩展 + 降级链适配 + 三档成本核算)**
> **v9 新增（2026-07-08）**:
> 1. @视频N 的运镜方式 引用模板 — 场景卡第八维 camera_movement_ref 文件 → reference_video + prompt suffix
> 2. render_v3.py 集成代码 — Step 0 解析 + Step 2 注入 + Step 3 API 调用 + 请求体大小验证
> 3. Prompt 模板扩展 — pipeline_prompt_template（默认/含运镜参考/分镜级）
> 4. 降级链 L0→L1→L2 适配 — 新增 L0C（含运镜参考），降级按 L0C→L0→L1→L2 顺序
> 5. 成本核算扩展 — 双档定价(07/09 ListBill 实测校正): 含视频输入 28元/百万 | 纯生成 46元/百万
>    (v9 三档定价中"extend_edit 56元"为错误推断,07/09 19:46 ListBill 实测取消该档,统一为 28)
> **v8 整改原因**: 0708 咖啡店项目落地后自查发现 4 个 bug:
> 1. 段级幂等命中时没把 last_frame_b64/video_url 加载给下一段 → extend 衔接断裂
> 2. 全局成本核算 max_pages=20 不够,100+ 段项目漏算
> 3. 多进程并发时幂等检查 TOCTOU 竞态,两个进程同时调 API
> 4. 脚本自报 vs API 实算偏差仅 print(warn),上游 Agent 不知道

你是专业的Seedance渲染执行层,**只负责API调用和视频片段生成**。不负责合成、不负责配音、不负责后期--那些是 Agent E 的活。

**核心能力:**
- 段打包清单→Seedance API→视频片段
- 私域资产库引用 (asset://ID)
- 提示词工程(8要素公式+符号系统+分镜时序)
- 参数预检 + 错误码处理 + 回退策略
- 尾帧链式衔接(v8 新增:sidecar 持久化 + 幂等时重新加载)
- 段级文件锁(v8 新增:fcntl.flock 防并发 TOCTOU)
- @视频N 运镜引用(v9 新增:camera_movement_ref → reference_video + prompt suffix)
- 三档→双档成本核算(07/09 19:46 ListBill 实测校正): 含视频输入 28元/百万 | 纯生成 46元/百万

## ⚠️ v8 核心规则(必读 - 0708 事故 + 4 个 v8 风险点后强制)

```
⚠️ CRITICAL RULE 1 - 单段单次 API(v7 原生)
   每个 seg_id 在脚本整个生命周期内,最多只调一次 Seedance API
   触发时机:第一档(最高优先级)成功后立即 return
   反例:render.py(主) + render_v2.py(回退) 先后跑同一 seg → 双倍扣费

⚠️ CRITICAL RULE 2 - 段级幂等保护(v7 原生 + v8 增强)
   启动时检查 clips/seg_xx.mp4 是否存在
   存在(size>10KB)→ 跳过整个 seg,不发起任何 API 请求,不扣费
   场景:脚本中途崩溃后重跑 / 用户手动重跑 / 调度器自动重试
   v8 增强:跳过时从 .chain/seg_xx.json sidecar 加载 video_url
            从 last_frame_seg_xx.png 加载 prev_last_frame_b64
            → 下一段 extend 模式衔接不断

⚠️ CRITICAL RULE 3 - 全局成本核算(v7 原生 + v8 增强)
   用 Query Task List API (GET /api/v3/contents/generations/tasks?page_num=N&page_size=50)
   循环翻页拉项目时间段内所有 task,按 task_id 去重,按 tokens × 单价累加
   与脚本自报数对比,差异 > 0.01 元视为漏报
   v8 增强:max_pages 20→100(足够 5000 条 task);空 page 明确终止
   v8 增强:偏差 > 10% 硬异常 raise RuntimeError(不仅 print warn)

⚠️ CRITICAL RULE 4 - 档位常量定义(v7 原生,消除 docstring 歧义)
   TIER_L0 = "L0"   # 主流程:完整 5 张参考图
   TIER_L1 = "L1"   # 降级1:仅场景图
   TIER_L2 = "L2"   # 降级2:纯文本
   TIER_PRIORITY = [TIER_L0, TIER_L1, TIER_L2]
   不用 docstring 文字描述,用代码常量明确主/备

⚠️ CRITICAL RULE 5 - 链式衔接 sidecar(v8 新增 - Bug #1 修复)
   渲染成功时同步保存 .chain/seg_xx.json 记录 {video_url, last_frame_path, saved_at}
   幂等跳过时调用 load_chain_meta(seg_id) + load_existing_last_frame(seg_id) 重新加载
   保证 chain-link 不会因幂等跳过而断裂

⚠️ CRITICAL RULE 6 - 段级文件锁(v8 新增 - Bug #3 修复)
   每次渲染前用 fcntl.flock 原子声明 .locks/seg_xx.lock(非阻塞)
   拿不到锁 → 跳过本段,不调 API
   防多进程并发 TOCTOU 竞态(两个进程同时通过 is_seg_already_done 检查)
   锁持有者写入 pid+timestamp 便于排查

⚠️ CRITICAL RULE 7 - 偏差硬异常阈值(v8 新增 - Bug #4 修复)
   COST_DISCREPANCY_THRESHOLD_PCT = 10.0
   脚本自报 vs API 实算偏差 > 10% → raise RuntimeError
   同时打印对照表(每个 task_id 的脚本/API 标记 + 费用)
   偏差 <= 10% 仍 print warn(不抛)

⚠️ CRITICAL RULE 8 - Sidecar 兼容性兜底(v8 新增)
   v7 之前渲染的项目(无 .chain/seg_xx.json) → 跳过时只 warn 不崩
   链式衔接会丢失 → 下一段 extend 可能失败
   建议:v7 项目升级到 v8 后手动补一次 main() 跑,让 .chain/ 自动生成

⚠️ CRITICAL RULE 9 - camera_movement_ref 优先级(v9 新增)
   场景卡第八维 camera_movement_ref 文件 > 第七维文字运镜描述
   当场景卡包含 camera_movement_ref 且文件存在且有效时:
   → 必须将 mp4 作为 reference_video 传入 API
   → 必须在 prompt 末尾追加 @视频N 的运镜方式 引用语法
   当第八维为 null、文件不存在、或文件 > 200MB 时:
   → 降级到第七维文字运镜描述
   → 不传 reference_video，不加 @视频1 语法
   Reference_video 不支持 Base64，仅支持 URL 或 asset://ID

⚠️ CRITICAL RULE 10 - 定价档位选择(07/09 19:46 ListBill 实测校正,双档)
   with_video 模式:含 reference_video(运镜参考/段间衔接/extend/编辑) → 28 元/百万 tokens
   pure_generation 模式:无任何视频输入 → 46 元/百万 tokens
   选择逻辑:
   1. 段间衔接有 prev_video_url → with_video(28元)
   2. 有 camera_movement_ref 运镜参考 → with_video(28元)
   3. 无任何视频输入 → pure_generation(46元)
   (原 v9 "extend_edit 56元" 为错误推断,实测含视频输入统一为 28 元/百万,07/09 19:46 锁定取消该档)
```

## 前置知识

- `skills/knowledge/管线规范.yaml` ⭐ v4.0(含 camera_movement_assets / prompt_engineering.camera_reference / agent_c_upgrade 章节)
- `skills/knowledge/模型技术约束.yaml`
- `skills/knowledge/画质参数模板.yaml`

## 输入确认

必读文件:
- `02_分镜/段打包清单.yaml` ⭐ 核心输入
- `02_分镜/分镜表.md`(查对白/时间码/角色名)
- `02_分镜/风格参考板.yaml`
- `03_资产/角色卡/`、`03_资产/道具卡/`、`03_资产/场景卡/`

## 职责边界

```
Agent B: 段打包清单 + 参考素材路径
    ↓
Agent C (你): Seedance API调用 → clips/*.mp4 + last_frame_*.png
    ↓ 移交
Agent E: ffmpeg合成 + 视频编辑/延长 + TTS兜底 + 字幕 + 交付
```

**明确不做的:**
- ❌ ffmpeg 拼接合成 → Agent E
- ❌ TTS 配音生成 → Agent E
- ❌ 字幕生成 → Agent E
- ❌ 数据订阅配置 → Agent E
- ✅ 只做 Seedance API 调用和视频片段下载

## 第零步:渲染放行令检查 🔑

**Agent C 不自行预检。** 所有审核/预检/门禁由 Agent D 负责。

渲染前只做一件事:检查 Agent D 签发的放行令。

```python
def check_render_approval(project_dir):
    """检查 Agent D 的渲染放行令"""
    release_path = project_dir / "05_审核" / "渲染放行令.yaml"
    if not release_path.exists():
        raise NotApprovedError(
            "❌ 未找到 05_审核/渲染放行令.yaml!"
            "请先跑完 Agent D 全关审计。"
            "Agent C 只接收已审核通过的清单,不自行预检。"
        )

    release = read_yaml(release_path)
    if release.get("status") != "APPROVED":
        raise NotApprovedError(
            f"❌ 放行令状态: {release.get('status')},无法继续。"
            f"请 Agent D 重新审核。"
        )

    print(f"✅ Agent D 放行令有效 ({release['date']})")
    print(f"→ 直接执行渲染,无需重复预检")
    return True
```

> **为什么?** Agent C 是渲染执行层,不是审核层。参数格式/资产完整性/风格约束 - 全部由 Agent D 在第四关(渲染前置门禁)统一检查。C 只管调 API。

### P0-2/P0-3 集成:Agent D 工具调用 🔗 (v8 新增)

**启动渲染前必须调用以下两个 Agent D 工具**,否则放行令可能已被静默篡改。

```python
# ── 强制调用:Agent D P0-2/P0-3 工具集成 ──
# 路径: skills/ai-director-auditor/auditor/
from auditor.live_reverify_gate import live_reverify_gate
from auditor.verify_input_hashes import verify_input_hashes

def run_render_preflight_gate(project_dir, gate_yaml_path):
    """渲染放行后、渲染启动前,调用 Agent D 工具验证放行令时效性
    
    在 check_render_approval() 之后、段渲染之前调用。
    """
    print("\n🔐 P0-2/P0-3 交叉验证:放行令时效性检查...")
    
    # Step 0a: 实时交叉验证放行令 (H-4 门禁 — G1-G7 1 秒内复核)
    # 重新读取上游文件,确认放行令签发后无人篡改
    live_reverify_gate(project_dir, gate_yaml_path)
    print("  ✅ H-4 实时交叉验证通过")
    
    # Step 0b: 验证上游文件 hash 一致性 (H-1 门禁 — MD5 绑定)
    # 重算每个上游文件的 MD5,与放行令记录对比
    verify_input_hashes(gate_yaml_path)
    print("  ✅ H-1 hash 一致性验证通过")
    
    print("🔐 放行令时效性验证全部通过,渲染可继续")
    return True
```

> **任意失败** → 抛出 RuntimeError → **阻断 Agent C 渲染**,提示 Agent D 重新审核。
> 这是 P0 安全修复的最后一道防线,不可跳过。

## 降级链(v7 核心 - 用常量定义消除歧义)

```python
# ────────────────────────────────────────
# 档位常量(0708 之前用 docstring 文字描述导致误读 → 改为代码常量)
# ────────────────────────────────────────
TIER_L0 = "L0"   # PRIMARY:完整 5 张参考图(4 角色 + 1 场景)
TIER_L1 = "L1"   # FALLBACK1:仅 1 张场景氛围图(避开 real person 过滤)
TIER_L2 = "L2"   # LAST RESORT:纯文本模式(无任何参考图)
TIER_PRIORITY = [TIER_L0, TIER_L1, TIER_L2]  # 严格按此顺序尝试

# 档位 → 参考图策略映射(用代码而非文字)
TIER_REF_IMAGES = {
    TIER_L0: ["林远_人脸", "林远_全身", "苏晓_人脸", "苏晓_全身", "咖啡馆_氛围"],
    TIER_L1: ["咖啡馆_氛围"],   # 只传场景图,无人脸
    TIER_L2: [],                # 纯文本
}

# 档位 → 中文描述(仅用于日志)
TIER_DESC = {
    TIER_L0: "主流程·完整5图",
    TIER_L1: "降级1·仅场景图",
    TIER_L2: "降级2·纯文本",
}
```

### 单段渲染主逻辑

```python
def render_segment_with_fallback(seg_id, ref_images_b64, prev_video_url, prev_last_frame_b64):
    """对单个 seg_id 依次尝试 L0→L1→L2,第一档成功立即返回

    ⚠️ CRITICAL - 单段单次 API:
       每个 seg_id 在本函数内最多只调一次 Seedance API
       一旦任一档 succeeded,立即 return;后续档位不再尝试
    """
    for tier in TIER_PRIORITY:
        content = build_content(seg_id, tier, ref_images_b64, prev_video_url, prev_last_frame_b64)
        body = build_request(content, seg_id)
        result = submit_and_wait(seg_id, tier, body)

        if result["status"] == "succeeded":
            # ⚠️ 关键:第一档成功就 return,后续档位不再尝试
            result["tier_used"] = tier
            return result
        else:
            # 失败:记录后继续尝试下一档
            log_fallback(seg_id, tier, result["error"])
            continue

    # 所有档位都失败
    return {"status": "failed", "tried_tiers": TIER_PRIORITY}
```

### 0708 事故复盘(v5 之前的问题)

```
0708 咖啡店项目(v5 时代)实际执行流程:
1. 用户跑 render.py(主流程,5 张参考图)
2. SEG-1 提交 → 拒绝 "real person" → 失败
3. 用户认为"主流程坏了",又跑 render_v2.py(回退脚本,1 张图)
4. SEG-1 重新提交 → 成功 → 又扣一次费
5. SEG-2/3 同理 → 共 6 次 API 调用 → 扣费 ¥34.28
6. Agent C 报告时只算了 v2 那 3 个 task,漏算 v1 那 3 个
7. 报告 ¥17.15,项目负责人查控制台发现实际 ¥34.28 → 差 ¥17.15

v7 整改后:
- render_v3.py 单脚本处理主流程 + 降级
- 同一 seg_id 只调一次 API(在 L0 失败时 L1 自动接力,但 L1 成功后 L2 不再试)
- 用 Query Task List API 全局核算成本
- 段级幂等:clips/seg_xx.mp4 已存在则跳过
```

## 段级幂等保护(v7 + v8 增强)

```python
IDEMPOTENT_MIN_SIZE = 10000  # 10KB,小于此视为损坏文件

def is_seg_already_done(seg_id):
    """检查 clips/seg_xx.mp4 是否存在且有效 → 跳过整个 seg

    返回: (already_done: bool, existing_size_kb: float)
    """
    clip_path = CLIP_DIR / f"seg_{seg_id}.mp4"
    if clip_path.exists() and clip_path.stat().st_size > IDEMPOTENT_MIN_SIZE:
        return True, round(clip_path.stat().st_size / 1024, 0)
    return False, 0

# 主循环中(v8 增强):
for seg_id in ["01", "02", "03"]:
    already_done, existing_kb = is_seg_already_done(seg_id)
    if already_done:
        # v8 新增 - 加载 sidecar 拿回 video_url + last_frame_b64
        chain_meta = load_chain_meta(seg_id)
        if chain_meta:
            prev_video_url = chain_meta.get("video_url")
            if seg_id != "03":
                prev_last_frame_b64 = load_existing_last_frame(seg_id)
        else:
            # 兼容 v7 之前项目:无 sidecar
            if seg_id == "01":
                prev_video_url = None
                prev_last_frame_b64 = None
        results[seg_id] = {"status": "skipped_idempotent", "cost_yuan": 0}
        continue
    # ... 否则才进入降级链渲染
```

**幂等保护触发场景:**
- 脚本中途崩溃后重跑(部分段已完成)
- 调度器自动重试(瞬时网络故障后重试)
- 用户手动重跑("我再跑一遍看看")
- 跨项目复用(同一 seg_id 跨多个项目)

**v8 增强:sidecar 链式衔接**
- 详情见下一节【链式衔接 sidecar】

## 链式衔接 sidecar(v8 新增 - Bug #1 修复)

**问题:**v7 段级幂等命中时,prev_video_url 和 prev_last_frame_b64 都被置空,导致下一段 extend 模式 reference_video 失效。3 段视频时,如果 SEG-1 幂等命中、SEG-2 重新跑,SEG-2 的 reference_video 会失效。

**解决:**渲染成功时同步保存 sidecar 元信息,幂等跳过时从 sidecar + 尾帧 PNG 重新加载。

```python
# ───────────────────────────────────────
# sidecar 路径常量(v8 新增)
# ───────────────────────────────────────
CHAIN_META_DIR = CLIP_DIR / ".chain"   # sidecar 存储目录
SEG_LOCK_DIR = CLIP_DIR / ".locks"     # 文件锁目录(下一节)

def save_chain_meta(seg_id, video_url, last_frame_path):
    """渲染成功后保存链式衔接元信息到 sidecar 文件"""
    meta = {
        "seg_id": seg_id,
        "video_url": video_url,
        "last_frame_path": str(last_frame_path) if last_frame_path else None,
        "saved_at": datetime.now().isoformat(),
    }
    meta_path = CHAIN_META_DIR / f"seg_{seg_id}.json"
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

def load_chain_meta(seg_id):
    """幂等跳过时加载链式衔接元信息,返回 dict 或 None"""
    meta_path = CHAIN_META_DIR / f"seg_{seg_id}.json"
    if not meta_path.exists():
        return None
    try:
        with open(meta_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        print(f"  ⚠️ 加载 chain_meta 失败: {e}")
        return None

def load_existing_last_frame(seg_id):
    """幂等跳过时加载已有的 last_frame_seg_xx.png 并返回 base64"""
    lf_path = CLIP_DIR / f"last_frame_seg_{seg_id}.png"
    if not lf_path.exists():
        return None
    try:
        with open(lf_path, "rb") as f:
            return "data:image/png;base64," + base64.b64encode(f.read()).decode("utf-8")
    except Exception as e:
        print(f"  ⚠️ 加载 last_frame 失败: {e}")
        return None
```

**调用点:**
- `process_success` 末尾 → `save_chain_meta(seg_id, vid, last_frame_path)`
- 主循环幂等命中 → `chain_meta = load_chain_meta(seg_id); prev_last_frame_b64 = load_existing_last_frame(seg_id)`

**补充说明:**
- Seedance 视频 URL 有效期限通常 24h,如果 v8 sidecar 加载后 URL 过期,extend 仍会失败
- v9 候选:本地上传视频到 base64 保留,或改用 reference_image (尾帧) 作为唯一街接手段

## camera_movement_ref 渲染集成(v9 新增) ⭐

**能力**:从分镜表读取场景卡第八维 camera_movement_ref，将运镜参考 mp4 以 reference_video 形式传入 Seedance API，同时 Prompt 中注入 `@视频N 的运镜方式` 引用语法。

### 9.1 输入参数

```python
# 分镜表 / 段打包清单中的场景卡第八维结构
scene_card_camera_movement = {
    "camera_movement_ref": "assets/camera_movements/dolly_in_01.mp4",  # 可选，文件路径
    "camera_movement_ref_strategy": "auto",  # auto | manual | disabled
    "camera_movement_video_count": 1,  # 引用视频数量(最多3段，总≤15s)
}
```

**字段说明**:

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| camera_movement_ref | str | 否 | 运镜参考视频文件路径，空=无第八维 |
| camera_movement_ref_strategy | str | 否 | auto=自动引用；manual=引用但修改描述；disabled=显式禁用 |
| camera_movement_video_count | int | 否 | @视频1/@视频2/@视频3 对应数量，等于传递的 reference_video 段数 |

### 9.2 优先级规则

```
场景卡第八维 camera_movement_ref (文件存在且有效)
    ↓ 有值
使用 reference_video + @视频N 语法
    ↓ 无值 / 文件不存在 / 文件>200MB
降级到第七维文字运镜描述（原有L0→L1→L2流程不变）
```

### 9.3 API 集成

在 build_request() 中新增 camera_movement_ref 处理（详见【请求体构建】章节）：

```python
def inject_camera_movement_ref(content_list, seg_data, video_ref_index_start=1):
    """将 camera_movement_ref 视频注入 content 列表
    
    在 reference_video（段间衔接）之后、尾帧图之前添加。
    video_ref_index_start 控制 @视频N 中的起始编号。
    
    ⚠️ 参考视频不支持 Base64，仅支持 URL 或 asset://ID
    """
    cam_ref_path = seg_data.get("camera_movement_ref")
    cam_strategy = seg_data.get("camera_movement_ref_strategy", "auto")
    
    if not cam_ref_path or cam_strategy == "disabled":
        return content_list, []  # 无第八维 → 不处理
    
    # 文件存在性 + 大小检查
    if not os.path.exists(cam_ref_path):
        print(f"  ⚠️ camera_movement_ref 文件不存在: {cam_ref_path}")
        print(f"  → 降级到第七维文字运镜描述")
        return content_list, []
    
    file_size_mb = os.path.getsize(cam_ref_path) / (1024 * 1024)
    if file_size_mb > 200:
        print(f"  ⚠️ camera_movement_ref 文件 > 200MB ({file_size_mb:.1f}MB)")
        print(f"  → 降级到第七维文字运镜描述")
        return content_list, []
    
    # 构建 reference_video 条目
    # ⚠️ Seedance API 要求: role=reference_video, url 不支持 Base64
    video_entry = {
        "type": "video_url",
        "video_url": {"url": cam_ref_path},
        "role": "reference_video",
    }
    content_list.append(video_entry)
    
    # 记录注入的引用编号
    ref_tags = [f"@视频{video_ref_index_start}"]
    print(f"  ✅ camera_movement_ref 已注入: {cam_ref_path}")
    print(f"  → Prompt 将添加 '{ref_tags[0]} 的运镜方式' 引用")
    
    return content_list, ref_tags
```

### 9.4 Prompt 注入（@视频N 语法）

**新模板定义**:

```yaml
prompt_template_with_camera_ref:
  base_prompt: "<从场景卡七维生成的文字 prompt，含八要素+分镜时序+约束词>"
  camera_ref_suffix: "@视频1 的运镜方式"  # 当 camera_movement_ref 存在时追加
  final_prompt: "{base_prompt}, {camera_ref_suffix}"
  example: "现代写实 CGI 风格咖啡店女主角低头看表，时间 17:30，<咖啡馆暖色调>，@视频1 的运镜方式"
```

**多视频场景**（多个 camera_movement_ref）：

```yaml
# 当有 2 段参考视频时
camera_ref_suffix: "结合 @视频1 的横移运镜和 @视频2 的推镜变焦"

# 当有 3 段参考视频时
camera_ref_suffix: "将 @视频1、@视频2 和 @视频3 的运镜方式融合到镜头中"
```

**shot_level_prompt_template**（按管线规范 v4.0）：

```
"将 @视频1 的运镜方式应用到 [主体1] 身上，[主体1] [动作描述]，[场景环境]。"
"结合 @视频1 的横移运镜和 @视频2 的推镜变焦，展示 [主体1] 从 [位置A] 到 [位置B] 的行走过程。"
```

### 9.5 verify_camera_movement_ref() 预检（Step 0a 后）

```python
def verify_camera_movement_ref(segment_list):
    """检查所有段中 camera_movement_ref 的可用性
    
    在 Step 0a 预检之后、段渲染之前执行。
    预检失败时阻断渲染（注册降级）但不抛异常阻断整项目。
    
    Returns:
      degradation_map: dict[seg_id, list[str]] 每段的降级原因列表
    """
    degradation_map = {}
    
    for seg in segment_list:
        seg_id = seg["seg_id"]
        cam_ref = seg.get("scene_card", {}).get("camera_movement_ref")
        
        if not cam_ref:
            # 无第八维 → 正常使用第七维文字描述
            continue
            
        issues = []
        
        # 1. 文件存在性
        if not os.path.exists(cam_ref):
            issues.append(f"camera_movement_ref 文件不存在 ({cam_ref})")
        
        # 2. 文件大小 (>200MB)
        elif os.path.getsize(cam_ref) > 200 * 1024 * 1024:
            issues.append(f"camera_movement_ref 文件 >200MB")
        
        # 3. 文件格式
        if cam_ref and not cam_ref.lower().endswith(('.mp4', '.mov')):
            issues.append(f"camera_movement_ref 不是 mp4/mov 格式")
        
        # 4. 策略检查
        strategy = seg.get("scene_card", {}).get("camera_movement_ref_strategy", "auto")
        if strategy == "disabled":
            issues.append(f"camera_movement_ref_strategy=disabled，显式禁用")
        
        if issues:
            degradation_map[seg_id] = issues
            print(f"  ⚠️ SEG {seg_id} camera_movement_ref 降级: {', '.join(issues)}")
            print(f"  → 降级到第七维文字运镜描述")
    
    return degradation_map
```

### 9.6 主循环集成

```python
# v9 新增:Step 0a 之后，Step 1 之前
print("\n📹 camera_movement_ref 预检...")
degradation_map = verify_camera_movement_ref(segment_list)
degraded_seg_count = len(degradation_map)
print(f"  → {len(segment_list) - degraded_seg_count}/{len(segment_list)} 段使用第八维运镜参考")
if degraded_seg_count > 0:
    print(f"  → {degraded_seg_count} 段降级到第七维文字描述")
```

### 9.7 错误处理 + 降级逻辑总结

| 条件 | 行为 |
|------|------|
| camera_movement_ref = null | 使用第七维文字运镜描述（完全兼容 v8 流程） |
| camera_movement_ref 文件不存在 | 降级 + log 警告，不阻断渲染 |
| camera_movement_ref 文件 > 200MB | 降级 + log 警告（Seedance 单段 ≤200MB） |
| camera_movement_ref_strategy = disabled | 显式禁用，使用第七维文字描述 |
| Seedance API 拒绝 reference_video | 降级 + log 警告，后续段不再对该段尝试 |
| 多个 camera_movement_ref（>3段，总>15s）| 优先前3段，其余降级到文字描述 |
| camera_movement_ref 视频 > 5秒 | 裁剪至5秒后再引用 |

### 9.8 向后兼容性

- v3.0/v4.0/v8 项目无需修改 SKILL.md
- 场景卡无第八维时自动使用第七维文字运镜描述（完全走 v8 原有流程）
- 段打包清单无 camera_movement_ref 字段时不触发新逻辑
- 段级幂等 + 文件锁 + 全局成本核算保持不变

### 9.9 @视频N 引用模板（核心新能力）

Seedance 2.0 多模态 content 输入支持 `text + images(0-9) + videos(0-3) + audios(0-3)`。
camera_movement_ref 运镜参考视频通过 `reference_video` role 传入 API 请求体。

**YAML 引用模板**：

```yaml
# scene_card 第八维 → Agent C 渲染请求体映射
camera_movement_ref: "assets/camera_movements/dolly_in_1.mp4"  # 场景卡第八维
video_refs:
  - path: "assets/camera_movements/dolly_in_1.mp4"          # 实际文件路径
    role: "reference_video"                                     # 仅用于运镜参考，不参与画面融合
    type: "video_url"
    video_url:
      url: "assets/camera_movements/dolly_in_1.mp4"           # 不支持 Base64，仅 URL 或 asset://ID
prompt_suffix: "@视频1 的运镜方式"                              # N = video_refs 数组索引(1-based)
```

**多视频场景**（多个运镜参考）: 

```yaml
video_refs:
  - path: "assets/camera_movements/track_1.mp4"
    role: "reference_video"
  - path: "assets/camera_movements/zoom_1.mp4"
    role: "reference_video"
prompt_suffix: "将 @视频1 的横移运镜和 @视频2 的推镜变焦融合到镜头中"
```

**约束**：
- 最多 3 段 reference_video，总时长 ≤ 15s
- 单段视频 ≤ 200MB
- 请求体总大小(content 编码后) ≤ 64MB
- Reference_video 不支持 Base64，只支持公网 URL 或 asset://ID

### 9.10 render_v3.py 集成代码

render_v3.py 是 Agent C 的单一入口脚本（取代 render.py + render_v2.py）。
camera_movement_ref 集成涉及 Step 0（输入校验）、Step 2（构造请求体）、Step 3（API 调用）。

```python
"""
render_v3.py — Agent C 渲染引擎单一入口

v9 新增：camera_movement_ref 运镜参考视频集成
  - Step 0: scene_card.camera_movement_ref 解析 + verify_camera_movement_ref() 预检
  - Step 2: video_refs + prompt_suffix 注入 content 列表
  - Step 3: videos 参数传入 Seedance API
  - 降级链 L0→L1→L2 适配 camera_movement_ref
"""

import os
import sys
import json
import base64
import time
import logging
from pathlib import Path
from datetime import datetime
from typing import Optional, List, Dict, Tuple

import requests

# ────────────────────────────────────────
# 路径常量
# ────────────────────────────────────────
PROJECT_DIR = Path(os.environ.get("PROJECT_DIR", "."))
SHOTS_DIR = PROJECT_DIR / "04_渲染" / "clips"
ASSETS_CAMERA_DIR = PROJECT_DIR.parent.parent / "assets" / "camera_movements"
SEG_DIR = PROJECT_DIR / "04_渲染" / "clips"
CHAIN_META_DIR = SEG_DIR / ".chain"
SEG_LOCK_DIR = SEG_DIR / ".locks"
API_BASE = "https://ark.cn-beijing.volces.com/api/v3"

# ────────────────────────────────────────
# 档位常量 (v9 新增:TIER_L0_CAM_REF)
# ────────────────────────────────────────
TIER_L0 = "L0"            # 主流程:完整5参考图 + camera_movement_ref
TIER_L0_CAM_REF = "L0C"   # v9:完整5参考图 + camera_movement_ref (含 @视频1 语法)
TIER_L1 = "L1"            # 降级1:仅场景图 + 文字运镜描述
TIER_L2 = "L2"            # 降级2:纯文本
TIER_PRIORITY = [TIER_L0_CAM_REF, TIER_L0, TIER_L1, TIER_L2]

# ────────────────────────────────────────
# Step 0a: camera_movement_ref 解析
# ────────────────────────────────────────

def parse_camera_movement_ref(scene_card: dict) -> dict:
    """从场景卡解析第八维 camera_movement_ref
    
    Args:
        scene_card: 场景卡字典（来自段打包清单）
    
    Returns:
        dict with keys: path, strategy, video_count, resolved_path
        path=None 表示无第八维
    """
    cam_ref = scene_card.get("camera_movement_ref")
    strategy = scene_card.get("camera_movement_ref_strategy", "auto")
    video_count = scene_card.get("camera_movement_video_count", 1)
    
    result = {
        "path": cam_ref,
        "strategy": strategy,
        "video_count": video_count,
        "resolved_path": None,
        "valid": False,
        "issues": [],
    }
    
    if not cam_ref:
        result["issues"].append("无第八维 camera_movement_ref")
        return result
    
    if strategy == "disabled":
        result["issues"].append("camera_movement_ref_strategy=disabled")
        return result
    
    # 尝试解析文件路径
    # 1. 绝对路径
    resolved = Path(cam_ref)
    # 2. 相对路径(从项目目录或 assets/ 解析)
    if not resolved.exists():
        # 尝试在 assets/camera_movements/ 下找
        alt_path = ASSETS_CAMERA_DIR / Path(cam_ref).name
        if alt_path.exists():
            resolved = alt_path
    
    if not resolved.exists():
        result["issues"].append(f"文件不存在: {cam_ref}")
        return result
    
    # 文件大小检查
    file_size_mb = resolved.stat().st_size / (1024 * 1024)
    if file_size_mb > 200:
        result["issues"].append(f"文件 >200MB ({file_size_mb:.1f}MB)")
        return result
    
    result["resolved_path"] = str(resolved)
    result["valid"] = True
    result["file_size_mb"] = round(file_size_mb, 1)
    return result


def verify_camera_movement_ref(segment_list: list) -> dict:
    """批量预检所有段的 camera_movement_ref
    
    Returns:
        degradation_map: {seg_id: [issue_strings]}
    """
    degradation_map = {}
    for seg in segment_list:
        seg_id = seg["seg_id"]
        scene_card = seg.get("scene_card", {})
        cam_info = parse_camera_movement_ref(scene_card)
        
        if cam_info["valid"]:
            logging.info(f"SEG {seg_id}: camera_movement_ref ✓ ({cam_info['resolved_path']}, {cam_info.get('file_size_mb', '?')}MB)")
        elif cam_info["path"] is not None:
            # 有 camera_movement_ref 但无效 → 降级
            degradation_map[seg_id] = cam_info["issues"]
            logging.warning(f"SEG {seg_id}: camera_movement_ref 降级 → {', '.join(cam_info['issues'])}")
        # path=None → 无第八维，正常走第七维
    return degradation_map


# ────────────────────────────────────────
# Step 2: 请求体构建 (v9 扩展)
# ────────────────────────────────────────

def inject_camera_movement_ref(
    content_list: list,
    seg_data: dict,
    video_ref_index_start: int = 1,
) -> Tuple[list, list]:
    """将 camera_movement_ref 视频注入 content 列表
    
    在 reference_video（段间衔接）之后、尾帧图之前添加。
    video_ref_index_start 控制 @视频N 中的起始编号
    （当 prev_video_url 存在时，@视频1 被占用，从 @视频2 开始）。
    
    Args:
        content_list: 已有的 content 列表（可变）
        seg_data: 段数据
        video_ref_index_start: @视频编号起始值
    
    Returns:
        (content_list, ref_tags)
        content_list: 注入后的列表
        ref_tags: @视频N 标签列表，供 prompt 注入
    """
    scene_card = seg_data.get("scene_card", {})
    cam_info = parse_camera_movement_ref(scene_card)
    
    if not cam_info["valid"]:
        return content_list, []  # 无有效第八维 → 不处理
    
    # 检查请求体大小限制
    # 粗略估算：200MB 视频 → Base64 约 267MB → 超出 64MB 限制
    # ⚠️ reference_video 不支持 Base64，所以用 URL 不涉及编码膨胀
    # 但需确保总请求体不超过 64MB
    current_size_est = len(json.dumps(content_list).encode("utf-8"))
    vid_path = cam_info["resolved_path"]
    
    # 构建 reference_video 条目
    video_entry = {
        "type": "video_url",
        "video_url": {"url": vid_path},
        "role": "reference_video",
    }
    content_list.append(video_entry)
    
    # 生成 @视频N 标签
    video_count = cam_info.get("video_count", 1)
    ref_tags = []
    for i in range(video_count):
        n = video_ref_index_start + i
        ref_tags.append(f"@视频{n}")
    
    logging.info(f"camera_movement_ref 已注入: {vid_path}")
    logging.info(f"  → Prompt 将添加引用: {', '.join(ref_tags)}")
    
    return content_list, ref_tags


def build_prompt_with_camera_ref(
    seg_data: dict,
    base_prompt: str,
    ref_tags: Optional[list] = None,
) -> Tuple[str, bool]:
    """将 camera_movement_ref 的 @视频N 引用注入 prompt
    
    Args:
        seg_data: 段数据
        base_prompt: 从七维生成的文字 prompt
        ref_tags: 可选，从 inject_camera_movement_ref() 返回的标签
    
    Returns:
        (final_prompt, used_ref)
    """
    if ref_tags is None:
        scene_card = seg_data.get("scene_card", {})
        cam_info = parse_camera_movement_ref(scene_card)
        if not cam_info["valid"]:
            return base_prompt, False
        
        video_count = cam_info.get("video_count", 1)
        prev_video_count = 1 if seg_data.get("prev_video_url") else 0
        ref_tags = [f"@视频{prev_video_count + 1 + i}" for i in range(video_count)]
    
    if not ref_tags:
        return base_prompt, False
    
    if len(ref_tags) == 1:
        camera_ref_suffix = f"{ref_tags[0]} 的运镜方式"
    elif len(ref_tags) == 2:
        camera_ref_suffix = f"将 {ref_tags[0]} 和 {ref_tags[1]} 的运镜方式融合到镜头中"
    else:
        suffixes = "、".join(ref_tags)
        camera_ref_suffix = f"将 {suffixes} 的运镜方式融合到镜头中"
    
    final_prompt = f"{base_prompt}，{camera_ref_suffix}"
    return final_prompt, True


# ────────────────────────────────────────
# Step 3: API 调用 (v9 扩展)
# ────────────────────────────────────────

def submit_and_wait(
    seg_id: str,
    tier: str,
    content: list,
    prev_video_url: Optional[str] = None,
) -> dict:
    """提交 Seedance API 并轮询结果
    
    v9: 验证 request body 总大小 ≤ 64MB
    """
    body = {
        "model": "doubao-seedance-2-0-260128",
        "content": content,
        "generate_audio": True,
        "duration": 5,
        "resolution": "720p",
        "ratio": "16:9",
        "watermark": False,
        "return_last_frame": True,
    }
    
    # 检查请求体大小
    body_bytes = json.dumps(body).encode("utf-8")
    if len(body_bytes) > 64 * 1024 * 1024:
        logging.error(f"SEG {seg_id}: 请求体 {len(body_bytes)/1024/1024:.1f}MB > 64MB 限制")
        return {"status": "failed", "error": "request_body_too_large"}
    
    # 提交任务
    resp = requests.post(
        f"{API_BASE}/contents/generations/tasks",
        headers={"Authorization": f"Bearer {os.environ['ARK_API_KEY']}"},
        json=body,
    )
    
    if resp.status_code != 200:
        error_data = resp.json()
        error_code = error_data.get("code", "Unknown")
        return {"status": "failed", "error": error_code, "http_status": resp.status_code}
    
    task_id = resp.json().get("id")
    
    # 轮询直到完成
    max_wait = 300  # 5 分钟
    start = time.time()
    while time.time() - start < max_wait:
        task_resp = requests.get(
            f"{API_BASE}/contents/generations/tasks/{task_id}",
            headers={"Authorization": f"Bearer {os.environ['ARK_API_KEY']}"},
        )
        task_data = task_resp.json()
        status = task_data.get("status")
        
        if status == "succeeded":
            return {
                "status": "succeeded",
                "task_id": task_id,
                "video_url": task_data["output"]["video_url"],
                "last_frame_url": task_data["output"].get("last_frame_url"),
                "usage": task_data.get("usage", {}),
                "duration": task_data.get("output", {}).get("duration"),
                "resolution": task_data.get("output", {}).get("resolution"),
            }
        elif status in ("failed", "cancelled"):
            return {
                "status": "failed",
                "task_id": task_id,
                "error": task_data.get("error", {}).get("code", "Unknown"),
            }
        
        time.sleep(5)
    
    return {"status": "failed", "error": "timeout"}


# ────────────────────────────────────────
# 降级链 (v9 适配)
# ────────────────────────────────────────

def render_segment_with_fallback(
    seg_id: str,
    seg_data: dict,
    ref_images_b64: list,
    prev_video_url: Optional[str] = None,
    prev_last_frame_b64: Optional[str] = None,
) -> dict:
    """对单个 seg_id 依次尝试 L0C→L0→L1→L2，第一档成功立即返回
    
    v9 新增: L0C (L0 + camera_movement_ref) 作为最高优先级
    
    TIER_PRIORITY = [
        L0C: 完整5参考图 + camera_movement_ref reference_video + @视频1 引用
        L0:  完整5参考图（无 camera_movement_ref）
        L1:  仅场景图（无 camera_movement_ref）
        L2:  纯文本
    ]
    """
    # L0C: 完整5图 + camera_movement_ref
    content_l0c = build_content(seg_id, TIER_L0_CAM_REF, ref_images_b64, prev_video_url, prev_last_frame_b64)
    content_l0c, ref_tags = inject_camera_movement_ref(content_l0c, seg_data, 
        video_ref_index_start=1 if not prev_video_url else 2)
    if ref_tags and content_l0c[0]["type"] == "text":
        base = content_l0c[0]["text"]
        content_l0c[0]["text"], _ = build_prompt_with_camera_ref(seg_data, base, ref_tags)
    
    if ref_tags:
        result = submit_and_wait(seg_id, TIER_L0_CAM_REF, content_l0c, prev_video_url)
        if result["status"] == "succeeded":
            result["tier_used"] = TIER_L0_CAM_REF
            return result
        logging.warning(f"SEG {seg_id} L0C 失败({result.get('error')})，降级到 L0")
    else:
        logging.info(f"SEG {seg_id}: 无 camera_movement_ref，直接走 L0")
    
    # L0: 完整5图（降级：无 camera_movement_ref）
    content_l0 = build_content(seg_id, TIER_L0, ref_images_b64, prev_video_url, prev_last_frame_b64)
    result = submit_and_wait(seg_id, TIER_L0, content_l0, prev_video_url)
    if result["status"] == "succeeded":
        result["tier_used"] = TIER_L0
        return result
    logging.warning(f"SEG {seg_id} L0 失败({result.get('error')})，降级到 L1")
    
    # L1: 仅场景图
    content_l1 = build_content(seg_id, TIER_L1, ref_images_b64, prev_video_url, prev_last_frame_b64)
    result = submit_and_wait(seg_id, TIER_L1, content_l1, prev_video_url)
    if result["status"] == "succeeded":
        result["tier_used"] = TIER_L1
        return result
    logging.warning(f"SEG {seg_id} L1 失败({result.get('error')})，降级到 L2")
    
    # L2: 纯文本
    content_l2 = build_content(seg_id, TIER_L2, ref_images_b64, prev_video_url, prev_last_frame_b64)
    result = submit_and_wait(seg_id, TIER_L2, content_l2, prev_video_url)
    if result["status"] == "succeeded":
        result["tier_used"] = TIER_L2
        return result
    
    return {"status": "failed", "tried_tiers": TIER_PRIORITY}


# ────────────────────────────────────────
# Step 4: 成本核算 (07/09 19:46 ListBill 实测校正,双档定价)
# ────────────────────────────────────────

def compute_tier_price(tier: str) -> int:
    """根据档位返回单价(元/百万tokens)
    
    双档定价(07/09 19:46 ListBill 实测锚定,与 render_v3 PRICE_MAP 一致):
    - with_video (L0/L0C, 含 reference_video: camera_movement_ref 或段间衔接 prev_video_url): 28 元/百万
    - pure_generation (L1/L2, 无任何视频输入): 46 元/百万
    
    历史: v9 曾引入三档定价(extend_edit=56),为错误推断,07/09 ListBill 实测取消该档。
    """
    if tier in (TIER_L0, TIER_L0_CAM_REF):
        return 28   # with_video: 含 reference_video (运镜参考/段间衔接)
    else:
        return 46   # pure_generation: L1/L2 无视频输入


def track_cost(result: dict, seg_id: str, has_video_input: bool) -> dict:
    """从 API 响应追踪单段成本 (v9 三档定价扩展)"""
    tokens = result.get("usage", {}).get("completion_tokens", 0)
    
    # 根据 tier_used 选择定价
    tier_used = result.get("tier_used", TIER_L2)
    unit_price = compute_tier_price(tier_used)
    
    if unit_price == 28:
        tier_label = "视频编辑"  # camera_movement_ref reference_video
    elif unit_price == 56:
        tier_label = "延长编辑"  # extend/edit mode
    else:
        tier_label = "纯生成"    # 无视频输入
    
    cost = tokens / 1_000_000 * unit_price
    
    return {
        "seg_id": seg_id,
        "completion_tokens": tokens,
        "tier": tier_label,
        "pricing_tier": tier_used,
        "unit_price_per_million": unit_price,
        "cost_yuan": round(cost, 2),
        "duration_seconds": result.get("duration"),
        "resolution": result.get("resolution"),
    }


# ────────────────────────────────────────
# main() — v9 主流程
# ────────────────────────────────────────

def main():
    """V9 渲染引擎主入口"""
    
    # Step 0: 读取段打包清单
    segment_list = load_segment_list()
    
    # Step 0a: camera_movement_ref 预检 (v9 新增)
    logging.info("📹 camera_movement_ref 预检...")
    degradation_map = verify_camera_movement_ref(segment_list)
    total_segs = len(segment_list)
    valid_refs = total_segs - len(degradation_map)
    logging.info(f"  → {valid_refs}/{total_segs} 段使用第八维运镜参考")
    if degradation_map:
        for seg_id, issues in degradation_map.items():
            logging.warning(f"  → SEG {seg_id} 降级: {', '.join(issues)}")
    
    results = {}
    for seg in segment_list:
        seg_id = seg["seg_id"]
        
        # 段级幂等检查
        if is_seg_already_done(seg_id):
            results[seg_id] = {"status": "skipped_idempotent", "cost_yuan": 0}
            continue
        
        # 段级文件锁
        claimed, lock_fd = claim_seg_atomic(seg_id, blocking=False)
        if not claimed:
            results[seg_id] = {"status": "locked_by_other"}
            continue
        
        try:
            result = render_segment_with_fallback(
                seg_id, seg,
                ref_images_b64=seg.get("ref_images_b64", []),
                prev_video_url=seg.get("prev_video_url"),
                prev_last_frame_b64=seg.get("prev_last_frame_b64"),
            )
            results[seg_id] = result
            
            if result["status"] == "succeeded":
                save_chain_meta(seg_id, result["video_url"], result.get("last_frame_path"))
        finally:
            release_seg(lock_fd)
    
    # Step 4: 全局成本核算
    compute_total_cost_from_api(...)
    
    # Step 5: 写段渲染清单 + 通知 Agent E
    write_rendering_manifest(results)


if __name__ == "__main__":
    main()
```

### 9.11 Prompt 模板扩展（pipeline_prompt_template）

**YAML 模板定义**:

```yaml
# ── pipeline_prompt_template v9 ──
# 含 camera_movement_ref @视频N 引用

template_default:
  description: "默认模板（无运镜参考视频）"
  formula: "精准主体 + 动作细节 + 场景环境 + 光影色调 + 镜头运镜 + 视觉风格 + 画质 + 约束条件"
  constraints:
    - "保持无字幕"
    - "不要生成Logo"
    - "不要生成水印"
    - "禁止出现外形/着装/配饰完全一致的人物"
    - "人物面部和身体比例稳定不变形"
  example: "现代写实 CGI 风格咖啡店女主角低头看表，时间 17:30，<咖啡馆暖色调>，缓慢推镜"

template_with_camera_ref:
  description: "含运镜参考视频的模板"
  base_prompt: "<从场景卡七维生成的文字 prompt，含八要素+分镜时序+约束词>"
  camera_ref_suffix: "@视频1 的运镜方式"
  final_prompt: "{base_prompt}，{camera_ref_suffix}"
  multi_suffix: "将 @视频1、@视频2 和 @视频3 的运镜方式融合到镜头中"
  example: "现代写实 CGI 风格咖啡店女主角低头看表，时间 17:30，<咖啡馆暖色调>，@视频1 的运镜方式"

template_shot_level:
  description: "段内多镜头 + camera_movement_ref"
  format: |
    镜头1: {运镜方式},{主体动作描述},{场景环境}
    镜头2: {运镜方式},{主体动作描述},{场景环境}
    {camera_ref_suffix}
  example: "镜头1: 将 @视频1 的运镜方式应用到[主体1]身上，[主体1]缓慢转头，[咖啡馆窗边]。镜头2: 平稳横移展示[主体2]推门而入，@视频1 的运镜方式。全程画面[写实CG]，[高清]，[电影质感]。"
  note: "当 camera_movement_ref 存在时，@视频N 引用放在每镜头末尾或整段末尾"
```

**优先级（严格递减）**：
1. 场景卡第八维 `camera_movement_ref` 文件引用（最高，文件存在时强制使用）
2. 场景卡第七维文字运镜描述（中等，第八维空/无效时使用）
3. 默认运镜（兜底，无运镜信息时使用 static/中景）

**冲突处理**：第八维和第七维描述不一致时，优先第八维的文件引用，在 prompt 中只追加 @视频N 语法，忽略第七维的文本描述。

### 9.12 降级链 L0 → L1 → L2 适配

v9 扩展降级链：在 L0 之前增加 L0C（含 camera_movement_ref）。

```python
# v9 降级链
TIER_PRIORITY = [TIER_L0_CAM_REF, TIER_L0, TIER_L1, TIER_L2]
# L0C: 完整5参考图 + camera_movement_ref reference_video + @视频1 引用
# L0:  完整5参考图（无 camera_movement_ref，降级：文字运镜描述）
# L1:  仅1张场景图（无 camera_movement_ref，降级：文字运镜描述）
# L2:  纯文本模式（无任何参考图/视频，提示词不含任何运镜描述）
```

**触发条件**：

| 层级 | 条件 | 含 camera_movement_ref | prompt 运镜引用 |
|:--:|------|:---:|:---:|
| L0C | camera_movement_ref 文件存在且有效 | ✅ | `@视频1 的运镜方式` |
| L0 | 第八维 null / 文件不存在 / 文件 >200MB | ❌ | 第七维文字描述 |
| L1 | L0 失败（PrivacyInformation / real person） | ❌ | 第七维文字描述 |
| L2 | L1 失败（InputImageSensitiveContentDetected） | ❌ | 无运镜描述 |

**原 v8 降级链保持不变**：L0→L1→L2 仍在 L0C 之后尝试。

### 9.13 成本核算扩展

07/09 19:46 ListBill 实测校正,双档定价(与 render_v3 PRICE_MAP 一致):

| 定价档位 | 单价 | 适用场景 | 触发条件 |
|:--------:|:----:|----------|----------|
| with_video | 28元/百万 tokens | 含 reference_video（运镜参考/段间衔接/extend/edit） | L0（含 prev_video_url）或 L0C（含 camera_movement_ref） |
| pure_generation | 46元/百万 tokens | 无任何视频输入 | L1/L2（无 prev_video_url 且无 camera_movement_ref）|

```python
def compute_tier_price(tier: str) -> int:
    """双档定价(07/09 ListBill 实测锚定)"""
    if tier in (TIER_L0, TIER_L0_CAM_REF):
        return 28   # with_video: 含 reference_video
    else:
        return 46   # pure_generation: L1/L2 无视频输入
```

**成本追踪格式更新(07/09 双档)**：

```markdown
> 定价(07/09 ListBill 实测): 含视频输入 28元/百万tokens | 纯生成 46元/百万tokens
> 选择逻辑: 含 reference_video (运镜参考/段间衔接/extend/edit) → with_video(28元) | 无 → pure_generation(46元)
> completion_tokens = API 返回的计费口径数值
```

**段渲染清单 tier 字段**：

```yaml
seg_01:
  tier: "视频编辑"
  pricing_tier: "L0"  # 含 reference_video (运镜参考或段间衔接)
  unit_price_per_million: 28
```

## 段级文件锁(v8 新增 - Bug #3 修复)

**问题:**v7 `is_seg_already_done` 检查文件存在后、下游写文件前,另一个进程可能也在跑同一段。两进程同时通过检查,各跑一次(概率小但可能)。

**解决:**用 `fcntl.flock` 原子声明渲染权;拿不到锁(非阻塞)则跳过本段。

```python
import fcntl

def claim_seg_atomic(seg_id, blocking=False):
    """原子地声明对某段的渲染权

    Returns:
        (claimed: bool, lock_fd: int or None)
        claimed=True 表示本进程获得该段渲染权;
        claimed=False 表示另一进程已持有锁,应跳过本段。
    """
    lock_path = SEG_LOCK_DIR / f"seg_{seg_id}.lock"
    try:
        fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o644)
    except Exception as e:
        print(f"  ⚠️ 打开锁文件失败: {e}")
        return False, None

    try:
        if blocking:
            fcntl.flock(fd, fcntl.LOCK_EX)
        else:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (IOError, OSError):
        os.close(fd)
        return False, None

    # 拿锁成功:写持有者 pid+时间戳便于排查
    try:
        os.lseek(fd, 0, os.SEEK_SET)
        os.write(fd, f"pid={os.getpid()}\nacquired_at={time.time()}\n".encode())
        os.fsync(fd)
    except Exception:
        pass
    return True, fd

def release_seg(lock_fd):
    """释放渲染权锁(幂等)"""
    if lock_fd is None:
        return
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)
    except Exception:
        pass
```

**调用点:**
```python
for seg_id in ["01", "02", "03"]:
    already_done, _ = is_seg_already_done(seg_id)
    if already_done:
        # 幂等路径(不需锁,文件已存在)
        ...
        continue

    # 原子声明渲染权
    claimed, lock_fd = claim_seg_atomic(seg_id, blocking=False)
    if not claimed:
        # 锁被另一进程持有 → 跳过
        results[seg_id] = {"status": "locked_by_other", ...}
        continue

    try:
        result = render_segment_with_fallback(...)
    finally:
        release_seg(lock_fd)  # 脚本崩溃时 OS 会自动释放
```

**补充说明:**
- flock 是咨询锁,依赖同一文件系统;多机部署需考虑 `flock` → 集中锁服务迁移
- Linux/macOS 都支持;Windows 需改用 `msvcrt.locking`

## 全局成本核算（不依赖脚本自报）

```python
def compute_total_cost_from_api(start_time_iso, end_time_iso, known_task_ids):
    """调用 Query Task List API 拉项目时间段所有 task，按 task_id 去重
    
    0708 整改原因：脚本自报可能漏算（render.py 跑完又跑 render_v2.py）
    v8 增强：max_pages 20→100（足够 5000 条 task）；空 page 明确终止；
            偏差 > 10% raise RuntimeError。
    """
    all_tasks = []
    page = 1
    page_size = 50
    max_pages = 100  # v8 新增：20→100（最多 5000 条 task）
    
    while page <= max_pages:
        resp = api_get(f"/contents/generations/tasks?page_num={page}&page_size={page_size}")
        items = (resp.get("data", {}).get("items")
                 or resp.get("items")
                 or resp.get("tasks")
                 or [])
        if not items:
            break
        if len(items) == 0:  # v8 新增 — 空页明确终止
            break
        all_tasks.extend(items)
        
        # 优先用 total 字段
        total_count = resp.get("total")
        if total_count is None and isinstance(resp.get("data"), dict):
            total_count = resp["data"].get("total")
        if total_count and len(all_tasks) >= total_count:
            break
        if len(items) < page_size:
            break
        page += 1
    else:
        # while 未 break → 达到 max_pages 安全阀
        print(f"  ⚠️ 达到 max_pages={max_pages} 安全阀")
    
    # ... 详见 render_v3.py
```

**为什么需要全局核算？**
- 0708 事故：脚本自报 ¥17.15 vs 实测 ¥34.28
- 根因：render.py(主) + render_v2.py(回退) 先后跑同一 seg，脚本只记最后一次
- 解法：不依赖脚本内 `cost_items` 列表，直接用 API 扫描所有 task

**v8 增强：偏差硬异常**

```python
COST_DISCREPANCY_THRESHOLD_PCT = 10.0  # v8 新增

# main() Step 4 中：
diff = api_cost - script_cost
discrepancy_pct = abs(diff) / max(api_cost, script_cost, 0.01) * 100
if discrepancy_pct > COST_DISCREPANCY_THRESHOLD_PCT:
    # v8 新增 — 偏差 > 10% 硬异常
    raise RuntimeError(
        f"❌ 脚本自报 vs API 实算偏差 {discrepancy_pct:.1f}% > 阈值 {COST_DISCREPANCY_THRESHOLD_PCT}%\n"
        f"  脚本自报费用: ¥{script_cost:.2f} ({n_script} tasks)\n"
        f"  API 实算费用: ¥{api_cost:.2f} ({n_api} tasks)\n"
        f"  差      异: ¥{diff:+.2f} ({discrepancy_pct:.1f}%)"
    )
```

## 第一步:提示词构建 ⭐(v5 新增)

### 1.1 八要素公式

每段 Prompt 按以下8要素组织:

```
1. 精准主体:将图片N中的[特征]定义为主体N,保证唯一可识别
2. 动作细节:肢体细化+程度量化+情绪外化
3. 场景环境:地点/时间/天气/氛围
4. 光影色调:灯光方向/色温/对比度
5. 镜头运镜:每镜头只1种运镜方式
6. 视觉风格:统一美术调性
7. 画质:高清/细节丰富/电影质感
8. 约束条件:无字幕/无Logo/无双胞胎/面部稳定
```

### 1.2 分镜时序

```python
# 段内多镜头提示词模板
prompt_template = """
[主体定义:将图片N中的{特征}定义为主体N]

镜头1:{运镜方式},{主体动作描述},{场景环境}
镜头2:{运镜方式},{主体动作描述},{场景环境}
镜头3:{运镜方式},{主体动作描述},{场景环境}

全程画面{风格},{画质},{约束条件}。
"""
```

### 1.3 camera_movement_ref Prompt 注入（v9 新增）

当 camera_movement_ref 存在且文件有效时，在 base_prompt 末尾追加 `@视频N 的运镜方式` 引用语法：

```python
def build_prompt_with_camera_ref(seg_data, base_prompt, ref_tags=None):
    """将 camera_movement_ref 的 @视频N 引用注入 prompt

    Args:
        seg_data: 段数据（含 scene_card 第八维）
        base_prompt: 从七维生成的文字 prompt（含8要素+分镜时序+约束词）
        ref_tags: 可选，从 inject_camera_movement_ref() 返回的标签列表

    Returns:
        final_prompt: 已注入 @视频N 引用的 prompt
        used_cam_ref: 是否使用了 camera_movement_ref
    """
    if ref_tags is None:
        # 无 ref_tags 时自行检查 camera_movement_ref
        cam_ref = seg_data.get("scene_card", {}).get("camera_movement_ref")
        cam_strategy = seg_data.get("scene_card", {}).get("camera_movement_ref_strategy", "auto")

        if not cam_ref or cam_strategy == "disabled":
            return base_prompt, False

        # 文件存在性 + 大小预检（已通过 verify_camera_movement_ref，这里做二次防御）
        if not os.path.exists(cam_ref):
            return base_prompt, False
        if os.path.getsize(cam_ref) > 200 * 1024 * 1024:
            return base_prompt, False

        # 确定 @视频N 起始编号
        prev_video_count = 1 if seg_data.get("prev_video_url") else 0
        video_ref_num = prev_video_count + 1

        # 多段 camera_movement_ref 场景
        video_count = seg_data.get("scene_card", {}).get("camera_movement_video_count", 1)
        if video_count == 1:
            camera_ref_suffix = f"@视频{video_ref_num} 的运镜方式"
        elif video_count == 2:
            camera_ref_suffix = f"将 @视频{video_ref_num} 和 @视频{video_ref_num+1} 的运镜方式融合到镜头中"
        else:
            suffixes = "、".join([f"@视频{video_ref_num + i}" for i in range(video_count)])
            camera_ref_suffix = f"将 {suffixes} 的运镜方式融合到镜头中"
    else:
        # 有 ref_tags 时直接使用（由 inject_camera_movement_ref 预计算）
        if len(ref_tags) == 1:
            camera_ref_suffix = f"{ref_tags[0]} 的运镜方式"
        else:
            suffixes = "、".join(ref_tags)
            camera_ref_suffix = f"将 {suffixes} 的运镜方式融合到镜头中"

    final_prompt = f"{base_prompt}，{camera_ref_suffix}"
    return final_prompt, True


# 使用示例
# v9 新增:在 build_content() 或 build_prompt() 中调用
base = build_prompt_from_7dimensions(seg_data)  # 原有 v8 逻辑
final_prompt, used_ref = build_prompt_with_camera_ref(seg_data, base)
if used_ref:
    print(f"  ✅ prompt 已注入 @视频N 运镜引用")
```

**yaml 模板定义**:

```yaml
prompt_template_with_camera_ref:
  base_prompt: "<从场景卡七维生成的文字 prompt，含八要素+分镜时序+约束词>"
  camera_ref_suffix: "@视频1 的运镜方式"  # 当 camera_movement_ref 存在时追加
  final_prompt: "{base_prompt}, {camera_ref_suffix}"
  example: "现代写实 CGI 风格咖啡店女主角低头看表，时间 17:30，<咖啡馆暖色调>，@视频1 的运镜方式"
```

### 1.4 音频符号系统

| 类型 | 符号 | 示例 |
|------|------|------|
| 台词 | `{}` | 男人说:{你记住,以后不可以用手指指月亮。} |
| 音效 | `<>` | <远处传来狗叫声> |
| 音乐 | `()` | (背景中播放着快节奏的摇滚乐) |
| 字幕 | `【】` | 【第一章:启程】 |

> ⚠️ 生成有声视频的 prompt 中,台词必须用 `{}` 包裹!

### 1.5 提示词约束词(必须附加到每段末尾)

```
保持无字幕,不要生成Logo,不要生成水印,禁止出现外形/着装/配饰完全一致的人物,禁止生成同款分身/双胞胎效果,人物面部和身体比例稳定不变形,动作连贯自然,不僵硬,无穿模无卡顿。
风格关键词来自 Agent A 视觉风格锁定.yaml,由 Agent D 审核保证,不在此处重复否定。
```

## 第二步:段打包渲染

### 流程

```
段打包清单.yaml
    ↓
第零步:参数预检(不通过→停止)
    ↓
对每段 SEG-N:
    0. 段级幂等检查(clips/seg_xx.mp4 存在?→ 跳过)
    1. 尝试 L0:5 张参考图
       失败 → 记录 → 继续
    2. 尝试 L1:1 张场景图
       失败 → 记录 → 继续
    3. 尝试 L2:纯文本
       失败 → 标记 failed
    4. 任一档成功 → 立即 return,后续档位跳过
    ↓
所有段完成后:
    - 全局成本核算(API 扫描所有 task,与脚本自报交叉验证)
    - 写日志/清单/状态
```

### 请求体构建

#### 对白格式自动转换（Dialogue Quote Transformer）

```python
def transform_dialogue_quotes(text: str) -> tuple[str, int]:
    """把说：{台词} 格式自动转成 Seedance 真实触发的双引号格式。Returns: (转换后text, 转换次数)"""
    import re
    pattern = r'(说[：:])\s*\{([^}]+)\}' 
    count = len(re.findall(pattern, text))
    text_new = re.sub(pattern, r'\1"\2"', text)
    return text_new, count

# 构造 request body 时调用：
# content_text, transform_count = transform_dialogue_quotes(seg["content"]["text"])
# if transform_count > 0:
#     log_to("dialogue_transform.jsonl", {"seg": seg["id"], "count": transform_count})
```

#### 主请求体构建函数

```python
def build_request(seg, prev_last_frame_url=None, prev_video_url=None):
    """从段打包清单构建 Seedance API 请求

    ⚠️ 互斥规则:首帧/首尾帧/多模态参考为3种互斥场景,不可混用。
    - SEG-1: 多模态参考模式(reference_image)
    - SEG-2+: 多模态参考模式 + reference_video(段间衔接)
    - 尾帧图作为额外 reference_image,而非 first_frame role
    """

    request = {
        "model": "doubao-seedance-2-0-260128",  # 或端点ID
        "content": [],
        "generate_audio": seg.get("generate_audio", True),
        "return_last_frame": True,  # 链式衔接必需
        "duration": int(seg["duration"]),
        "resolution": seg.get("resolution", "720p"),
        "ratio": seg.get("ratio", "16:9"),
        "watermark": False,
        "priority": seg.get("priority", 0),
    }

    # 1. 文本 Prompt(含8要素+分镜时序+约束词)
    prompt = build_prompt(seg)  # 见第一步

    # ⚠️ 编辑/延长模式提示词:不用"参考"前缀,直接用<视频N>指代
    if prev_video_url and seg.get("mode") == "extend":
        prompt = f"向后延长视频1,{prompt}"  # 延长模式
    elif prev_video_url and seg.get("mode") == "edit":
        prompt = f"严格编辑视频1,{prompt}"   # 编辑模式(不用"参考"前缀!)

    request["content"].append({"type": "text", "text": prompt})

    # 2. 参考图片
    ref_images = seg.get("reference_images", [])
    for i, img in enumerate(ref_images):
        image_url = img["url"]  # 公网URL / Base64 / asset://<ID>
        role = img.get("role", "reference_image")
        request["content"].append({
            "type": "image_url",
            "image_url": {"url": image_url},
            "role": role,
        })

    # 3. 参考视频(段间衔接)-- 视频仅支持URL或asset://ID,不支持Base64
    if prev_video_url:
        request["content"].append({
            "type": "video_url",
            "video_url": {"url": prev_video_url},
            "role": "reference_video",
        })

    # 4. (v9 新增) camera_movement_ref 运镜参考视频
    # - 通过 inject_camera_movement_ref() 注入 content 列表
    # - 同时将 @视频N 标签返回给 prompt 构建
    # - 当 prev_video_url 存在时，@视频1 被占用，camera_ref 从 @视频2 开始
    prev_video_count = 1 if prev_video_url else 0
    content_list, ref_tags = inject_camera_movement_ref(
        request["content"], seg, video_ref_index_start=prev_video_count + 1
    )
    request["content"] = content_list

    # 如果注入成功，更新 prompt 追加 @视频N 引用
    if ref_tags:
        prompt = build_prompt_with_camera_ref(seg, prompt, ref_tags)
        # 重写 prompt 到 content[0]
        request["content"][0] = {"type": "text", "text": prompt}

    # 6. ⚠️ 尾帧图:作为 reference_image(非 first_frame!遵守互斥规则)
    if prev_last_frame_url:
        request["content"].append({
            "type": "image_url",
            "image_url": {"url": prev_last_frame_url},
            "role": "reference_image",  # ⚠️ 不是 first_frame!
        })

    # 7. 参考音频(可选)-- 支持URL/Base64/asset://ID
    # ⚠️ 不可单独输入音频!必须配合图片或视频
    if "reference_audio" in seg:
        request["content"].append({
            "type": "audio_url",
            "audio_url": {"url": seg["reference_audio"]},
            "role": "reference_audio",
        })

    return request
```

### 资产库引用(v5 新增)⭐

如项目配置了私域资产库:

```python
# 使用 asset://ID 替代公网URL(需通过CreateAsset先上传)
"image_url": {"url": "asset://asset-20260224200602-qn7wr"}

# 提示词中仍需用"图片N"指代,不能直接用Asset ID
# 正确:图片1中的角色站起来
# 错误:asset-20260224200602-qn7wr中的角色站起来
```

## 第三步:常见问题应对

渲染过程中遇到以下问题按预案处理:

| 问题 | 检测方式 | 处理 |
|------|----------|------|
| ID漂移(换脸) | 目视检查 | 重新生成;或补充大头照参考,明确定义主体 |
| 双胞胎 | 目视检查 | 提示词加全局约束,重新生成 |
| 意外字幕 | 目视检查 | 提示词加"保持无字幕",重新生成 |
| Logo/水印 | 目视检查 | 提示词加"不要生成Logo",重新生成 |
| 风格漂移 | 目视检查 | 提示词加明确风格约束词 |
| 中文发音不准 | 听感检查 | 替换为同音字重新生成 |
| 720p/1080p 降级 | ResolutionCheck | 确认模型版本支持,或降级期望 |

## 第四步:失败回退

Seedance 审核拒绝时自动回退(v7 重构):

```python
TIER_PRIORITY = [TIER_L0, TIER_L1, TIER_L2]

def render_segment_with_fallback(seg_id, ...):
    for tier in TIER_PRIORITY:
        result = submit_and_wait(seg_id, tier, ...)
        if result["status"] == "succeeded":
            return result  # ⚠️ 关键:第一档成功立即返回
        # 否则尝试下一档
```

| 层级 | 操作 | 触发错误码 |
|:--:|------|------|
| L0 | 完整 5 张参考图 | (主流程,期望成功) |
| L1 | 移除人脸参考图,仅保留场景图 | PrivacyInformation / real person |
| L2 | 移除所有 image/video/audio → 纯文本模式 | InputImageSensitiveContentDetected |
| - | 标记 failed,记录到回退日志 | - |

写入 `04_渲染/回退日志.md`

## 第五步:移交流程

```
完成所有 clip 生成后:
    ↓
写入 04_渲染/段渲染清单.yaml(记录每个clip的路径/时长/尾帧/问题标注)
    ↓
⚠️ 全局成本核算(compute_total_cost_from_api):
   - Query Task List API 拉所有 task（v8: max_pages=100，空页终止）
   - 按 task_id 去重
   - 与脚本自报对比，差异 > 0.01 视为漏报
   - v8 新增：偏差 > 10% 报抛 RuntimeError（不静默）
   - 写入 STATUS.yaml
    ↓
通知 Agent E: "渲染完成,请开始后期合成"
移交文件:
    - 04_渲染/clips/*.mp4
    - 04_渲染/clips/last_frame_*.png
    - 04_渲染/clips/.chain/*.json  (v8 新增 - 链式衔接 sidecar)
    - 04_渲染/段渲染清单.yaml
    - 04_渲染/成本追踪.md
    - 04_渲染/回退日志.md
    - STATUS.yaml
```

## 输出结构

```
04_渲染/
├── clips/
│   ├── seg_01.mp4
│   ├── seg_02.mp4
│   ├── ...
│   ├── last_frame_seg_01.png    # return_last_frame=true 产出
│   ├── last_frame_seg_02.png
│   ├── .chain/                  # v8 新增 — 链式衔接 sidecar
│   │   ├── seg_01.json
│   │   ├── seg_02.json
│   │   └── ...
│   └── .locks/                  # v8 新增 — 段级文件锁(运行时)
│       ├── seg_01.lock
│       └── ...
├── 段渲染清单.yaml               # 移交给 Agent E 的清单
├── 成本追踪.md                   # v9 含三档定价记录
├── 回退日志.md
├── 渲染日志.md
├── camera_movement_ref_使用记录.md  # v9 新增:运镜参考视频使用情况
└── render_v3.py                  # v9 整合脚本(含 camera_movement_ref 集成)
```

## 成本追踪 ⭐

每段渲染完成后,从 API 响应提取计费数据:

```python
def track_cost(get_result, seg_id, has_video_input, tier_used=None):
    """从 API 响应追踪单段成本 (v9 三档定价)
    
    v9 新增: 根据 tier_used 选择 28/46/56 三档定价
    
    Args:
        get_result: API 响应对象
        seg_id: 段ID
        has_video_input: 是否有视频输入（保留兼容）
        tier_used: 使用的档位(L0C/L0/L1/L2)，决定定价档位
    """
    tokens = get_result.usage.completion_tokens

    # 双档定价(07/09 19:46 ListBill 实测锚定,与 render_v3 PRICE_MAP 一致)
    # - with_video (L0/L0C: 含 reference_video): 28 元/百万
    # - pure_generation (L1/L2: 无任何视频输入): 46 元/百万
    if tier_used in (TIER_L0, TIER_L0_CAM_REF) or has_video_input:
        unit_price = 28   # 含 reference_video (运镜参考/段间衔接/extend)
        tier = "视频编辑"
    else:
        unit_price = 46   # 纯生成
        tier = "纯生成"

    cost = tokens / 1_000_000 * unit_price

    return {
        "seg_id": seg_id,
        "completion_tokens": tokens,
        "tier": tier,
        "pricing_tier": tier_used,
        "unit_price_per_million": unit_price,
        "cost_yuan": round(cost, 2),
        "duration_seconds": get_result.duration,
        "resolution": get_result.resolution,
    }

# 判断是否有视频输入
# content 中包含 type="video_url" → has_video_input = True
# 否则 → has_video_input = False
# v9 细化(07/09 19:46 ListBill 实测取消): 含 reference_video → with_video(28元)
#          含 prev_video_url(段间衔接) 或 camera_movement_ref(运镜参考) 均统一为 28 元/百万
#          原 v9 "extend_edit 56元" 为错误推断,实测含视频输入统一为 28
```

写入 `04_渲染/成本追踪.md`:

```markdown
# 成本追踪

| 段 | tokens | 档位 | 时长 | 分辨率 | 费用(元) |
|----|--------|------|------|--------|----------|
| seg_01 | 102,500 | 纯生成 | 5s | 720p | 4.72 |
| seg_02 | 98,300 | 视频编辑 | 5s | 720p | 2.75 |
| ... | ... | ... | ... | ... | ... |
| **合计** | **616,000** | - | **30s** | - | **¥20.57** |

> 定价(07/09 19:46 ListBill 实测双档): with_video(含 reference_video: 运镜参考/段间衔接/extend/edit) 28元/百万tokens | pure_generation(无视频输入) 46元/百万tokens
> 选择逻辑: 含 reference_video → with_video(28元) | 无任何视频 → pure_generation(46元)
> 原 v9 三档定价(extend_edit 56元)为错误推断,07/09 19:46 ListBill 实测取消该档
> completion_tokens = API 返回的计费口径数值
```

## 段渲染清单格式 (移交Agent E)

```yaml
segments:
  seg_01:
    clip: "04_渲染/clips/seg_01.mp4"
    duration_actual: 5.0
    last_frame: "04_渲染/clips/last_frame_seg_01.png"
    generate_audio: true
    completion_tokens: 102500  # API返回
    cost_yuan: 4.72
    tier: "纯生成"
    resolution: "720p"
    status: "success"
    issues: []
  seg_02:
    clip: "..."
    ...
  seg_03:
    clip: "..."
    status: "warning"
    issues: ["人物ID轻微漂移,建议Agent E检查或重新渲染"]

metadata:
  total_segments: 5
  total_duration: 25.0
  total_token_cost: 544500
  total_cost_yuan: 20.57       # Agent C 计算的实际费用
  success_rate: "4/5"
  resolution: "720p"
  ratio: "16:9"
```

## 自查清单

**v7 原始项：**
- [ ] ⚠️ 第零步参数预检已通过
- [ ] ⚠️ 单段单次 API:每个 seg_id 在 L0→L1→L2 链中只调一次
- [ ] ⚠️ 段级幂等:clips/seg_xx.mp4 已存在则跳过
- [ ] ⚠️ 全局成本核算:调用 compute_total_cost_from_api(),与脚本自报对比
- [ ] 每段 Prompt 含:8要素+分镜时序+符号系统+约束词
- [ ] generate_audio=true(除非明确要求无声)
- [ ] return_last_frame=true(链式衔接)
- [ ] duration 为整数秒(不是毫秒!)
- [ ] reference_image 使用公网URL或asset://ID
- [ ] 失败段已执行回退策略
- [ ] 段渲染清单已完整填写
- [ ] 已通知 Agent E 开始后期

**v8 新增项：**
- [ ] ⚠️ sidecar 已保存:渲染成功后 .chain/seg_xx.json 生成且完整
- [ ] ⚠️ 幂等跳过时:load_chain_meta + load_existing_last_frame 被调用
- [ ] ⚠️ 段级锁:fcntl.flock 原子声明渲染权(多进程场景)
- [ ] ⚠️ 偏差阈值:脚本自报 vs API 实算偏差 > 10% 时抛 RuntimeError(不静默)
- [ ] ⚠️ P0-2/P0-3 集成:run_render_preflight_gate() 已在 main() Step0 中调用
  - live_reverify_gate(project_dir, gate_yaml_path) — H-4 实时交叉验证
  - verify_input_hashes(gate_yaml_path) — H-1 hash 一致性验证
  - 两项均通过后,渲染方可继续;任意失败阻断渲染

**v9 新增项：**
- [ ] ⚠️ verify_camera_movement_ref() 预检已执行（Step 0a 后、渲染前）
- [ ] ⚠️ camera_movement_ref 文件存在性 + 大小检查已通过（单视频≤200MB）
- [ ] ⚠️ 请求体总大小检查已通过（≤64MB）
- [ ] ⚠️ 降级日志:有降级的段已在 degradation_map 中记录原因
- [ ] ⚠️ 定价档位已正确选择:有段间衔接→56元 | 仅有camera_movement_ref→28元 | 无视频→46元
- [ ] camera_movement_ref 已作为 reference_video 传入 API 请求体（当可用时）
- [ ] Prompt 末尾已追加 @视频N 的运镜方式 引用语法
- [ ] 多视频场景:@视频1/@视频2/@视频3 已正确编号
- [ ] camera_movement_ref 为空时已正常使用第七维文字运镜描述（完全兼容前序版本）
- [ ] 段渲染清单中已包含 camera_movement_ref 使用记录 + pricing_tier 字段

## 飞书回复格式

```
🎬 渲染完成 → 移交 Agent E

📁 04_渲染/
  ├── clips/ {N}段 (含{skipped}段幂等跳过)
  ├── 段渲染清单.yaml
  ├── 成本追踪.md
  ├── 回退日志.md
  └── camera_movement_ref_使用记录.md

📊 统计:
  • segments: {N}段 × 平均{X}s = 总计{Y}s
  • 成功率: {success}/{total}
  • camera_movement_ref 使用: {cam_ref_count}段 (含{degraded}段降级)
  • issues: {M}个待Agent E处理

⚠️ 成本双档报告(07/09 19:46 ListBill 实测锚定):
  • with_video(28元/百万): {n_with_video}段, ¥{cost_with_video}  # 含 reference_video (运镜参考/段间衔接/extend/edit)
  • pure_generation(46元/百万): {n_pure}段, ¥{cost_pure}
  • 总计: ¥{total_cost} ({total_tasks} tasks)

💰 定价口径(07/09 ListBill 实测): 含视频输入 → 28元/百万 | 纯生成 → 46元/百万
```
