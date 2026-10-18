# 视频融合 (Video Fusion)

多平台视频融合应用。以 Apple 设计语言构建的移动端短视频 + 长视频客户端，
接入哔哩哔哩、抖音，并为后续平台预留扩展能力。

**这不是视频解析工具，也不是网页套壳。** 视频通过 `media_kit`（libmpv）
在应用进程内原生解码播放，不嵌入任何平台网页。

---

## 当前状态

| 能力 | 状态 |
|---|---|
| B站链接识别（BV/av/b23.tv） | ✅ 已验证 |
| B站元数据（标题/作者/封面/时长/统计） | ✅ 已验证 |
| B站推荐流 / 热门 / 排行榜 | ✅ 已验证 |
| B站跨平台搜索 | ✅ 已验证 |
| B站应用内播放（DASH + Referer） | ✅ 已验证 |
| B站扫码登录 | ✅ 已验证 |
| B站评论读取 | ✅ 已验证（游标分页） |
| B站点赞 / 投币 / 收藏 | ⚠️ 已实现，待真实账号验证 |
| 抖音链接识别 | ✅ 已验证 |
| **抖音推荐流** | ✅ **已验证**（APP 端公开接口） |
| **抖音热榜** | ✅ **已验证**（50 条真实热搜） |
| **抖音应用内播放** | ✅ **已验证**（mp4 直链，ftypisom） |
| **抖音评论读取** | ✅ **已验证**（隐藏 WebView 签名桥，20 条真实评论） |
| **抖音评论 IP 属地** | ✅ **已验证**（`ip_label`，无需登录） |
| 抖音扫码登录 | ⚠️ 已打通（纯 Dart `a_bogus`），待真人扫码验证凭证换取 |
| 抖音 Cookie 导入登录 | ✅ 已验证（31 项测试） |
| 抖音点赞 / 关注 / 搜索 / 详情 | ❌ 需 Argus 签名，不实现 |
| TikTok | ❌ 未接入（网络不可达，未实测） |

> 能力标注依据实测结果。未验证的能力不会标注为可用。
>
> 抖音的能力边界来自对官方 APK 40.7.0 的静态分析，
> 详见 [docs/06-抖音APK逆向分析报告.md](docs/06-抖音APK逆向分析报告.md)。

---

## 界面

三个主页面（接入直播的平台会多一个），Apple HIG 风格：

- **推荐** — 全屏竖滑短视频流，滑到即播
- **发现** — 长视频网格浏览 + 跨平台搜索
- **直播** — 直播列表与直播间（仅 B 站，条件显示）
- **设置** — 多平台账号管理与能力说明

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
flutter test --concurrency=1                    # 343 项
flutter build apk --release --split-per-abi
```

> `--concurrency=1` 不是可选项：并行编译时设计系统测试与真实网络测试
> 偶发 `did not complete`（资源竞争，非真实失败），串行必过。

真实网络测试（需要能访问 B站）：

```bash
flutter test test/interaction_live_test.dart --tags network
```

---

## 已知限制

### 抖音

**可用**：推荐流与热榜走 APP 端公开接口 `api.amemv.com`，无需签名。
播放地址实测为 `video/mp4` 直链（`ftypisom` 头），可原生播放。
评论通过应用内隐藏 WebView 由页面 secsdk 签名获取，实测 20 条真实评论。

**不可用**：`/aweme/v1/aweme/detail/`（详情）、`/aweme/v1/general/search/`（搜索，502）、
`/aweme/v1/challenge/detail/`（话题）均返回空响应，需要 `X-Argus` 签名。

Argus 的签名逻辑是**远程下发的 JS**（`bytegecko.com` CDN）并在 **WebView** 中执行
（`ArgusGeckoLoader` / `TuringVerifyWebView`），算法不在 APK 内。

让应用执行平台风控脚本以获取签名，属于规避访问控制，**本项目不实现**。

> 注：Web 端常见的 `a_bogus`、`X-Gorgon`、`UIFID_TEMP` 在 APP 端**完全不存在**，
> 扫描 259 万字符串命中 0 次。Web 与 APP 是两套独立的风控体系。

#### 抖音登录

扫码登录协议已完整逆向：

| 环节 | 状态 |
|---|---|
| `get_qrcode` 获取二维码 | ✅ 纯 Dart 可用（19 个固定参数 + XOR 编码的设备指纹） |
| `check_qrconnect` 轮询状态 | ❌ 需要 `sign` 参数 |

`sign` 的推导过程：`qs` 解码后是 10 个参数名，尝试
md5/sha1/sha256 × 5 种拼接 × 4 种 salt × HMAC，全部不匹配。
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
