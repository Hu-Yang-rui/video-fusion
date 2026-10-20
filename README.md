# 视频融合 (Video Fusion)

多平台视频融合应用。以 Apple 设计语言构建的移动端短视频 + 长视频客户端，
接入哔哩哔哩、抖音，并为后续平台预留扩展能力。

**这不是视频解析工具，也不是网页套壳。** 视频通过 `media_kit`（libmpv）
在应用进程内原生解码播放，不嵌入任何平台网页。

---

## 当前状态

> 版本 **0.5.0**。本轮重点：B站私信完整实现、抖音直播弹幕打通、
> 抖音私信/通知结论修正、代码审计瘦身。

### 哔哩哔哩

| 能力 | 状态 |
|---|---|
| 链接识别（BV/av/b23.tv） | ✅ 已验证 |
| 元数据（标题/作者/封面/时长/统计） | ✅ 已验证 |
| 推荐流 / 热门 / 排行榜 | ✅ 已验证 |
| 跨平台搜索 | ✅ 已验证 |
| 应用内播放（DASH + Referer） | ✅ 已验证 |
| 扫码登录 | ✅ 已验证 |
| 评论读取 | ✅ 已验证（游标分页） |
| **视频弹幕** | ✅ **已验证**（protobuf，1406 条实测） |
| **评论点赞** | ✅ **已验证**（点赞→复查→撤销） |
| **评论回复** | ✅ **已验证**（拿到 rpid） |
| **一键三连** | ⚠️ **部分**：点赞+收藏通过，投币被风控（`-401` 要人机验证） |
| **私信（会话/消息/发送）** | ✅ **已验证** |
| **私信表情 / 图片上传** | ✅ **已验证** |
| 点赞 / 投币 / 收藏 | ✅ 已验证（真实账号） |

### 抖音

| 能力 | 状态 |
|---|---|
| 链接识别 | ✅ 已验证 |
| 推荐流 | ✅ 已验证 |
| 热榜 | ✅ 已验证（50 条真实热搜） |
| 应用内播放 | ✅ 已验证（mp4 直链，ftypisom） |
| 评论读取 | ✅ 已验证（`a_bogus` 签名，20 条真实评论） |
| 评论 IP 属地 | ✅ 已验证（`ip_label`，无需登录） |
| **直播列表 / 直播间** | ✅ **已验证** |
| **直播弹幕** | ✅ **已验证**（HTTP 轮询 `/webcast/im/fetch/`，6 次轮询 67 条真实弹幕） |
| Cookie 导入登录 | ✅ 已验证（31 项测试） |
| 扫码登录 | ⚠️ 已打通（纯 Dart `a_bogus`），待真人扫码验证凭证换取 |
| **私信 / 通知** | ⚠️ **接口可达，缺登录态**（Web 端返回 `code=8` 非 404，见下） |
| **评论点赞 / 回复** | ⚠️ **接口可达，缺登录态**（端点已确认，写入未验证） |
| 点赞 / 关注 / 搜索 / 详情 | ⚠️ 接口可达，缺登录态 |

### 其它

| 平台 | 状态 |
|---|---|
| 红果短剧 | 📋 已测绘（官网 `hongguoduanju.com` 零签名可直取，见文档） |
| TikTok | ❌ 未接入（网络不可达，未实测） |

> 能力标注依据实测结果。未验证的能力不会标注为可用。

---

## 关于抖音私信：一个被推翻的结论

早期版本把抖音私信标记为「不可达」，理由是「需要 X-Argus 签名」。
**这个判断是错的**（2026-10-20 修正）：

```
/aweme/v1/web/notice/                     → code=8 用户未登录
/aweme/v1/web/notice/count/               → code=8 用户未登录
/aweme/v1/web/notice/digg/list/           → code=8 用户未登录
/aweme/v1/web/im/spotlight/relation/      → code=8 用户未登录
/aweme/v1/web/im/conversation/info/other/ → code=8 用户未登录
```

`code=8` 而非 `404`，说明服务端识别了路径、走到业务层、只在登录校验处
拦下。这些接口走 **Web 端 `a_bogus` 签名**（本项目已实现），
**不需要 APP 端 X-Argus**。门槛是**登录态**。

从 155 个前端 bundle 里还挖出 31 个 IM/通知路径
（`im/token/`、`im/user/active/status/`、`notice/del/` 等）。

**教训**：`code=8`（缺登录）与 `404`（不存在）是两件事，不能混为一谈。
写 `unsupportedPlatform` 前必须先确认是哪一种。

---

## 文档

| 想知道什么 | 看哪个 |
|---|---|
| APK 逆向产物 | `APK样本/README.md` |
| 逆向方法论 | `APK样本/逆向分析/通用/README.md` |
| 抖音接口测绘全记录 | `APK样本/逆向分析/抖音/APK-API-逆向报告.md` |
| 抖音私信为何可达 | `APK样本/逆向分析/抖音/私信通知接口-结论修正.md` |
| 抖音直播弹幕怎么通的 | `APK样本/逆向分析/抖音/直播弹幕HTTP通道.md` |
| 抖音签名库为什么封存 | `archive/douyin-native-signer-v2/README.md` |
| 红果短剧 Web 端方案 | `APK样本/逆向分析/红果短剧/Web端直取方案.md` |
| **代码审计与瘦身** | `docs/CODE-AUDIT-2026-10-20.md` |
| 项目约定（给 Agent） | `AGENTS.md` |

完整的逐轮实测证据与复现脚本在
[video-fusion-prompts](https://github.com/Hu-Yang-rui/video-fusion-prompts)
仓库（私有）。

---

## 界面

四个主页面（接入直播的平台会多一个），Apple HIG 风格：

- **推荐** — 全屏竖滑短视频流，滑到即播
- **发现** — 长视频网格浏览 + 跨平台搜索
- **直播** — B 站与抖音直播列表、直播间（条件显示）
- **我的** — 账号、我的收藏夹、稍后再看、观看历史；**设置**作为次级入口

> 一级导航只放内容消费。收藏夹/历史/稍后再看这类内容型入口放在「我的」，
> 而不是挤进设置页——用户不会去设置里找自己的收藏。

设计系统位于 `lib/src/design/`：
- 语义化配色（`label` / `separator` / `fill`，而非 `red1` / `blue2`）
- 13 级字体层级，对齐 iOS Dynamic Type
- 4pt 间距刻度、44pt 最小触控目标
- WCAG 对比度校验（有测试守护）

视频播放区域固定深色（画面需要纯黑背景），应用外壳浅色。

---

## 架构

```
lib/
├── adapters/         平台适配器（bilibili / douyin / mock + 注册表）
├── core/             错误模型、HTTP、缓存、日志脱敏、凭证保险库、播放策略
├── models/           统一视频模型、播放源密封类、互动数据契约
├── player/           media_kit 内核接入
├── design/           Apple 设计系统（令牌 / 主题 / 组件）
└── ui/
    ├── shell/        标签栏外壳
    ├── feed/         推荐页（竖滑流）
    ├── discover/     发现页
    ├── detail/       长视频详情页
    ├── live/         直播列表与直播间
    ├── settings/     设置
    └── interaction/  互动（点赞/评论/投币/收藏）
```

**关键约束**：

- 平台判断集中在 `PlatformRegistry`，UI 层零平台分支
- 播放降级链固定为 `NATIVE → OFFICIAL_EMBED → EXTERNAL`，每级只在适配器声明支持时尝试
- 失败与"没有内容"严格区分，不静默降级
- 未登录不伪造互动状态（显示"登录后可操作"而非"未点赞"）
- 凭证永不进日志、UI 或公开仓库

---

## 构建

需要 Flutter 3.47+ 与 Android SDK（minSdk 24）。

```bash
flutter pub get
flutter test --concurrency=1                    # 535 项（8 项无凭据时跳过）
flutter build apk --release --split-per-abi
```

> `--concurrency=1` 不是可选项：并行编译时设计系统测试与真实网络测试
> 偶发 `did not complete`（资源竞争，非真实失败），串行必过。
>
> 单测超时在 `dart_test.yaml` 里放宽到 120s：抖音直播 feed 实测空 body 率
> 约 71%，客户端带 5 次重试，全量套件里会撞默认 30s 上限报
> `did not complete`（单独跑该文件是稳的）。放宽超时不改变任何断言。

真实网络测试（需要能访问 B站/抖音）：

```bash
flutter test test/interaction_live_test.dart --tags network

# 收藏闭环（真实账号，含可逆写入）
$env:BILI_COOKIE_FILE = 'D:\vf-local\bili_cookie.txt'   # 仓库外，绝不入库
$env:VF_ALLOW_WRITE = '1'                               # 不加则只读
flutter test test/favorite_live_test.dart --tags network
```

---

## 已知限制

### 抖音

**可用**：推荐流、热榜、直播列表、直播弹幕、详情、评论读取、播放
全部走 **Web 端接口**（`www.douyin.com/aweme/v1/web/*`），
签名 `a_bogus` 已纯 Dart 实现（`_abogus.dart`，含 SM3）。

**真正卡住功能的不是签名，是登录态。**

#### 关于 APP 端签名（已放弃）

抖音 APP 端用另一套签名（`X-Gorgon` / `X-Argus` / `X-Ladon` /
`X-Khronos`），算法在 `libmetasec_ml.so` 里，被 VMP 保护。
**本项目不实现这条路**，代码封存在
[archive/douyin-native-signer-v2](archive/douyin-native-signer-v2/README.md)。

放弃理由（不是技术失败，是投入产出比）：

| 前提 | 状态 |
|---|---|
| arm64 真机 | ❌ 模拟器走不通（见下） |
| app-bound license | ❌ 未提取（dex 里加密） |
| 设备身份自洽 | ❌ 未构造 |
| 服务端接受 header | ❌ 无人验证过 |
| 功能增益 | **零**——Web 端已全覆盖 |

模拟器为什么走不通（实测结论）：

- 多 ABI 包在 x86_64 模拟器上以**原生 x86_64 进程**运行，
  linker 只查 `lib/x86_64/`，而 metasec 只在 `lib/arm64-v8a/`
  → `dlopen` 报 `library not found`
- 纯 arm64 包也起不来：x86_64 模拟器的 zygote 是 x86_64，
  `libflutter.so` 找不到 → `UnsatisfiedLinkError`

**翻译层不会把 x86_64 进程的 `dlopen` 重定向到 arm64 目录。**

#### Web 端 vs APP 端是两套独立体系

| | Web 端 | APP 端 |
|---|---|---|
| 域名 | `www.douyin.com/aweme/v1/web/*` | `api.amemv.com/aweme/v1/*` |
| 签名 | `a_bogus`（JS，**本地可算**） | `X-Argus` 等（native so） |
| 本项目 | ✅ 已实现 | ❌ 封存 |

**两者不能互相替代**，但 Web 端覆盖了所有需要的功能。

#### 已知的 Web 端细节

Web 端真正卡住 detail 的不是签名，而是 `uifid` Cookie 的**会话等级**：
`UIFID_TEMP`（约 500ms 下发）只够评论，正式 `UIFID`（约 2.5–4s 下发）
才放行 detail。这一条曾长期被误记成"签名不可得"。

#### 抖音登录

扫码登录协议已逆向，但 `check_qrconnect` 需要 `sign` 参数，
它依赖 JS 运行时状态（`performance.timeOrigin` 等），**纯 Dart 无法复现**。

因此应用内提供的是 **Cookie 导入登录**：
从浏览器 F12 → Network → Request Headers 复制 Cookie 后粘贴导入。

### B站

- 未登录时 `playurl` 只下发 480P/360P（接口宣称支持 1080P+，但实发不符）
- 评论旧接口 `/x/v2/reply` 未登录只给 3 条，必须用 `/x/v2/reply/main` 游标分页
- 搜索接口未签名时有 412 限流风险
- **评论 IP 属地匿名不可得**：8 个接口 × 3 种 UA = 24 种组合全部验证，
  `reply_control` 只有 `max_line` / `time_desc` / `translation_switch` / `support_share` 四个键

### TikTok

本机网络无法访问 `tiktok.com`（全部超时），无法完成实测，因此未接入。

---

## 合规声明

- 只使用各平台**公开 Web 接口**与用户自身账号授权范围内的数据
- 不绕过登录保护、不破解 DRM、不伪造设备身份
- 不索取用户密码（仅扫码登录）
- 不实现平台个性化推荐算法，只消费平台已有的公开推荐/榜单接口

---

## 许可

本项目代码仅供学习与研究。接入的平台内容版权归各平台与原作者所有。
