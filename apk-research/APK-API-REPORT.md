# 官方 APK 逆向：API 清单与可用性报告

> 分析对象：哔哩哔哩 8.91.1、抖音 40.7.0 官方 Android 安装包
> 分析方式：解包取 dex → 二进制串扫描 → 真实网络可达性验证
> 目的：搞清楚两个 App 各自在用什么接口、哪些能匿名用、能用在 Video Fusion 的哪些地方
> 所有结论都标注了证据来源；**没有实测过的会明确写"未验证"**

---

## 一、样本与方法

### 1.1 样本

| 应用 | 包名 | 版本 | 大小 | SHA256 |
|---|---|---|---|---|
| 哔哩哔哩 | `tv.danmaku.bili` | **8.91.1** (8911100) | 182.9 MB | `E6F1ADEE9B96CE9EB79001F27AB0688B5C1712F3C635BC9D6E2DB82D1A9C30C8` |
| 抖音 | `com.ss.android.ugc.aweme` | **40.7.0** (400701) | 343.2 MB | `99C4A66DAA3D7CB8D1CA3CAA47E7F9B46DCDE5825D0D2F694BB479A249BD2A2A` |

抖音这个版本号 `400701` 与项目既有逆向记录（HANDOVER 里的 APK 40.7.0）一致，可以互相对照。

来源：
- B站：`https://dl.hdslb.com/mobile/latest/iBiliPlayer-bili.apk`（需带浏览器 UA/Referer，否则 403）
- 抖音：豌豆荚 `com.ss.android.ugc.aweme` 应用页的下载重定向（`vcode=400701`）

### 1.2 方法

```
APK → 只抽 *.dex + AndroidManifest.xml（不解全部资源）
    → 扫描 dex 里的可打印 ASCII 串，归类出 URL / 路径 / host / 签名关键字
    → 挑出"可能匿名可用"的接口，逐个打真实请求验证
```

**为什么不全量 jadx 反编译**：两个包合计 700 MB dex（B站 38 个、抖音 55 个），全量反编译要几十分钟、产出几十 GB，而接口清单在 dex 里是**明文常量**，直接扫字节又快又全。定位到具体类之后再精读才有意义。

### 1.3 规模

| | dex 数 | URL 去重 | 接口路径去重 | host 去重 |
|---|---|---|---|---|
| B站 8.91.1 | 38 | 136 | **777** | 92 |
| 抖音 40.7.0 | 55 | 738 | **2059** | 370 |

---

## 二、B站 8.91.1

### 2.1 host 分布（说明 App 的接口分层）

```
    40  api.bilibili.com          ← 主 API
    24  app.bilibili.com          ← App 专属网关
    24  www.bilibili.com          ← Web 页面/H5
    10  api.live.bilibili.com     ← 直播
     8  live.bilibili.com
     7  api.vc.bilibili.com      ← 私信/IM
     7  cm.bilibili.com          ← 广告
     7  member.bilibili.com      ← 会员购/账号
     5  passport.bilibili.com    ← 登录
     5  space.bilibili.com       ← 用户空间
     4  pay.bilibili.com         ← 支付
     3  message.bilibili.com     ← 消息
```

### 2.2 匿名性实测（关键结论）

用真实 BV 号 `BV1j5nj68E48` 做样本，**不带任何 Cookie**：

| 接口 | 作用 | 匿名结果 |
|---|---|---|
| `/x/web-interface/view` | 视频元数据（标题/作者/统计/cid） | ✅ **可用**（46 字段） |
| `/x/web-interface/popular` | 热门列表 | ✅ **可用** |
| `/x/web-interface/ranking/v2` | 排行榜 | ✅ **可用**（138 KB） |
| `/x/v2/reply/main` | 评论（游标分页） | ✅ **可用**（13 字段） |
| `/x/v3/fav/resource/list` | 收藏夹内容 | ✅ **可用**（他人公开夹） |
| `/x/web-interface/archive/related` | **相关推荐** | ✅ **可用（40 条）** ← 项目未使用 |
| `/x/web-interface/card` | UP 主名片 | ✅ **可用** |
| `/x/web-interface/archive/relation` | 我的互动状态 | 🔒 `-101` 需登录 |
| `/x/v2/history/toview/web` | 稍后再看 | 🔒 `-101` |
| `/x/member/web/exp/reward` | 硬币余额 | 🔒 `-101` |
| `/x/relation` | 关注关系 | 🔒 `-101` |
| `/x/v3/fav/folder/created/list-all` | 我的收藏夹 | ⚠️ `code=0` 但 data 空（未登录时静默空） |
| `api.live.bilibili.com/.../getList` | 直播列表 | 🔒 `-352` 风控 |
| **所有写操作**（like/coin/fav/relation/reply action） | — | 🔒 **全部 `-101`** |

**结论**：B站的"读公开内容"基本免登录，"读我的数据"和"所有写操作"一律要 Cookie。

### 2.3 项目没用过、但值得接入的接口

| 接口 | 作用 | 为什么有价值 | 状态 |
|---|---|---|---|
| `/x/web-interface/archive/related` | 相关推荐（40 条） | 详情页可以加"相关视频"，纯匿名 | ✅ 已实测可用 |
| `/x/web-interface/card` | UP 主名片（头像/粉丝/签名） | 详情页作者区可以更完整 | ✅ 已实测可用 |
| `/x/v2/view/like/triple` | **一键三连**（点赞+投币+收藏） | 一个按钮完成三件事，比现在三次请求体验好 | 路由存在（dex 命中 2 次），需登录，**未实测** |
| `/x/v3/fav/resource/batch-deal` | **批量收藏** | 一次把多个视频收进同一个夹 | 路由存在，需登录，**未实测** |
| `/x/v3/fav/resource/unfav-all` | 一键取消全部收藏 | 夹内批量清理 | 路由存在，需登录，**未实测** |
| `/x/v3/fav/folder/resources` | 收藏夹内容（新版） | 可能是 `resource/list` 的替代 | 需登录（`-101`） |
| `/x/v2/reply/action` | **给评论点赞** | 评论面板目前只读，这是缺的一环 | 需登录（`-101`） |
| `/x/v2/dm/thumbup/add` | 给弹幕点赞 | 为将来视频弹幕做准备 | 需登录（`-101`） |
| `/x/relation/tag/special/add|del` | **特别关注** | 关注功能可以做分级 | 需登录（`-101`） |
| `/x/v2/history/toview/v2/list` | 稍后再看（v2） | 可能比 `toview/web` 更稳 | 需登录（`-101`） |
| `/x/v2/history/toview/move` | 调整稍后再看顺序 | 列表排序能力 | 需登录，**未实测** |
| `/pgc/app/follow/add|del` | 追番/追剧 | 如果将来接番剧 | 路由存在，**未实测** |

### 2.4 签名与风控体系（决定"能不能自己实现"）

dex 里挖到 **29 个 `x-bili-*` 请求/响应头**：

```
x-bili-gaia-vtoken      (11)   ← Gaia 风控令牌
x-bili-gaia-vvoucher     (7)   ← Gaia 凭证
x-bili-locale-bin        (6)
x-bili-metadata-ip-region (5)  ← 见下方说明
x-bili-metadata-legal-region (5)
x-bili-aurora-zone       (4)   ← Aurora 分区路由
x-bili-ticket            (4)   ← bili_ticket
x-bili-trace-id          (4)
x-bili-mid               (4)
x-bili-network-bin       (3)
x-bili-aurora-eid        (3)
x-bili-device-bin        (2)   ← 设备指纹（二进制）
x-bili-fawkes-req-bin    (2)   ← Fawkes 风控
x-bili-exps-bin          (2)   ← AB 实验
x-bili-metadata-bin      (2)
x-bili-restriction-bin   (2)
... 其余为 idc / moss / turn-only 等
```

相关类：`WbiSigner` / `BiliTicket` / `BiliTickets` / `SignUtil` / `BuidHelper` 系（`Buvid` 命中 34 次、`BuvidHelper` 26 次、`fp_local`/`fp_remote` 各 7 次）。

**解读**：
- **wbi 签名**在 App 里也存在（`WbiSigner`），但项目已经在 Web 端实现了 `wbi_signer.dart`，这部分**不需要从 APK 拿**。
- **`x-bili-gaia-vtoken` / `vvoucher` / `fawkes-*` / `device-bin` 是 App 端独有的**，Web 端没有。这就是为什么有些接口 Web 能过、App 反而被拦（反之亦然）。**不建议复刻**：这些是风控体系，复刻等于伪造设备身份。
- **`x-bili-metadata-ip-region` 是响应头**（实测 `popular` 返回 `CN`），语义是"**请求方所在区域**"，国家级粒度。它**不能**解决项目里那个"评论作者 IP 属地"的问题——那是评论作者的位置，两回事。这个头可以用来判断自己是否被地区限制。

### 2.5 登录体系（`passport-login` 共 26 个端点）

```
passport-login/web/qrcode/generate     ← 项目已用（扫码）
passport-login/web/qrcode/poll         ← 项目已用
passport-login/web/sso/ticket
passport-login/web/key
passport-login/fast/login
passport-login/login/sms               ← 短信登录
passport-login/sms/send
passport-login/oauth2/{login,info,access_token,refresh_token}
passport-login/{revoke,batch/revoke,confirm/refresh}
passport-login/account/switch          ← 多账号切换
passport-login/country
passport-login/timestamp
passport-login/authorize(+agreement)
```

凭据字段：`SESSDATA` / `bili_jct` / `access_key`(30 次) / `refresh_token` / `sid`。
→ 项目现在用 Cookie 导入是可行的；如果将来想做"官方授权登录"，`oauth2/*` 那条链是正路。

---

## 三、抖音 40.7.0

### 3.1 host 分布（先看这个，能看出架构）

```
    84  lf-webcast-sourcecdn-tos.bytegecko.com   ┐
    55  lf-webcast-gr-sourcecdn.bytegecko.com    ├ 远程 JS/资源 CDN
    54  lf-dy-sourcecdn-tos.bytegecko.com        ┘ （合计 193 次！）
    44  aweme.snssdk.com          ← 主 API（旧域名）
    34  lf3-static.bytednsdoc.com ← 静态资源
    32  webcast.amemv.com         ← 直播
    14  ecom.snssdk.com           ← 电商
    12  api.amemv.com             ← 主 API（新域名）
    12  i.snssdk.com              ← 通用服务
    12  ugapk.com                 ← 包管理
     9  aweme-aigc.zijieapi.com
     8  ad.zijieapi.com
     8  polaris.zijieapi.com     ← 埋点
     7  p3-sign.douyinpic.com    ← 图片（带签名）
     7  tsearch.amemv.com        ← 搜索
```

**`bytegecko.com` 占前 3 位、合计 193 次**——这是字节的远程资源 CDN。结合下文的 `ArgusGeckoLoader`，证实了项目里的结论：**Argus 签名逻辑是远程下发的 JS，不在 APK 里**。

### 3.2 匿名性实测

| 接口 | 作用 | 匿名结果 |
|---|---|---|
| `webcast/feed/` | 直播推荐流 | ✅ **可用**（每批 6 条，空 body 率高） |
| `webcast/room/info/` | 直播间详情 | ✅ **可用（165 字段）** — 但**必需 3 个参数**：`aid=6383` + `device_platform=web` + `version_code`；缺 `device_platform` 返回 **200 + 空 body** |
| `webcast/room/info_by_user/` | 按主播查直播间 | ✅ **可用（163 字段）** |
| `webcast/gift/list/` | **礼物面板数据** | ✅ **可用（3.8 MB，1295 条礼物）** ← 项目未使用 |
| `webcast/room/enter/` | 进房间（App 参数） | ❌ 空 body（缺 web_rid，此路封死） |
| `webcast/im/fetch/` | 弹幕拉取 | ⚠️ `{"data":[]}` 恒空 |
| `webcast/room/chat/` | 发弹幕 | 🔒 `20003` 需登录 |
| `webcast/room/info_by_scene/` | 场景化房间信息 | ⚠️ `10011` 参数错误 |
| `aweme/v2/feed/` | 短视频推荐流 | ⚠️ 返回 363 KB 但非 JSON（需签名/加密） |
| `aweme/v1/aweme/detail/` | 视频详情 | ❌ 空 body（需 `X-Argus`） |
| `aweme/v1/multi/aweme/detail/` | 批量详情 | ❌ 空 body |
| `aweme/v1/aweme/post/` | 用户作品 | ⚠️ `code=0` 但 data 空 |
| `aweme/v1/comment/list/` | 评论列表 | ❌ 空 body |
| `aweme/v1/search/sug/` | 搜索建议 | ⚠️ 32 KB 但 data 空 |
| `aweme/v1/commit/item/digg/` | 点赞（写） | 🔒 需登录 |
| `aweme/v1/user/profile/self/` | 我的资料 | 🔒 `status_code=8` 未登录 |

**结论**：抖音**直播系匿名基本可用**（列表/详情/礼物面板），**短视频 `aweme/*` 系几乎全部需要签名**。这与项目既有结论完全一致。

### 3.3 签名体系（为什么短视频系拿不到）

dex 里 `argus` 命中 23 次，相关类 **26 个**：

```
ArgusGeckoLoader            ← Gecko（远程资源加载器）
ArgusApi / ArgusAPI
ArgusAesGcmCipher           ← AES-GCM 加密
ArgusSecureManager
ArgusWebChromeClient        ← WebView 容器
ArgusNetworkUtil
ArgusConfigManager
ArgusBizId
ArgusContainerDelegate
ArgusMotionEventParams      ← 采集触摸事件（行为风控）
ArgusWebDomMonitorUserSecTokenRawServerModel
TuringVerifyView / TuringVerifyWebView / TuringVerifyService / TuringVerifyThread
                            ← 人机验证（滑块/点选）
SecSdkConfig / SecSdkInitTaskOpt / SecSdkInited / SecSdkRequest / SecSdkAdapter
SignManager / SignatureUtil
```

**关键证据链**：
1. `ArgusGeckoLoader` + `bytegecko.com`（193 次）→ 签名逻辑**从 CDN 拉 JS**
2. `ArgusWebChromeClient` + `TuringVerifyWebView` → 在 **WebView** 里执行
3. `ArgusMotionEventParams` → 还采集触摸行为做风控
4. `ArgusAesGcmCipher` → 结果加密

→ **算法确实不在 APK 内**，本地静态分析拿不到签名算法。项目"不实现 Argus"的决定是对的：要复刻必须让 App 去执行平台的远程风控脚本，那是规避访问控制。

### 3.4 抖音公共参数（1215 次命中）

```
aid (54) / app_name (37) / version_code (35) / device_platform (32)
iid (27) / cdid / openudid / install_id / msToken / ttwid / s_v_web_id
```

这解释了为什么 `webcast/room/info` 缺 `device_platform` 就返回空 body——**参数集本身参与路由/风控判断**。

---

## 四、这些 API 能用在 Video Fusion 的哪些地方

按"改动成本 × 收益"排序，**每条都注明是否需要登录**。

### 4.1 立即可做（匿名可用，已实测）

| # | 能力 | 用哪个接口 | 用在哪 | 收益 |
|---|---|---|---|---|
| 1 | **相关推荐** | `archive/related?bvid=` | 详情页底部加"相关视频"列表 | 详情页目前到底就没了，这是最容易补的内容模块；实测一次返回 40 条 |
| 2 | **UP 主名片** | `web-interface/card?mid=` | 详情页作者区（粉丝数/签名/认证） | 现在只显示昵称+头像，信息太薄 |
| 3 | **抖音直播间直查** | `webcast/room/info/?room_id=&device_platform=web&version_code=&aid=6383` | 替换现在"翻 feed 找房间"的实现 | 现在进直播间要翻最多 3 批 feed（每批 6 条、空 body 率 71%）；直查 1 个请求拿 165 字段，且**人数更新鲜**（实测 feed 7698 → room/info 7716 → 8017） |
| 4 | **按主播查直播间** | `webcast/room/info_by_user/?user_id=` | 主播主页"TA 在直播吗" | 可以给主播维度做入口 |
| 5 | **抖音礼物面板** | `webcast/gift/list/` | 直播间礼物列表（只展示，不发送） | 3.8 MB / **1295 条**真实礼物数据（实测 `data.gifts`，样例 `id=21021 芦花剑影 diamond=8999`），纯匿名 |

### 4.2 需要登录才能做（路由已验证存在）

| # | 能力 | 用哪个接口 | 用在哪 |
|---|---|---|---|
| 6 | **一键三连** | `POST /x/v2/view/like/triple` | 长按点赞触发"点赞+投币+收藏"，比现在点三次顺 |
| 7 | **评论点赞** | `POST /x/v2/reply/action` | 评论面板现在只读，这是补全互动闭环的一环 |
| 8 | **批量收藏** | `POST /x/v3/fav/resource/batch-deal` | 收藏面板支持多选视频批量入夹 |
| 9 | **一键取消全部收藏** | `POST /x/v3/fav/resource/unfav-all` | 夹内批量清理（要加二次确认） |
| 10 | **特别关注** | `POST /x/relation/tag/special/add|del` | 关注功能做分级（现在只有关注/取关） |
| 11 | **稍后再看 v2** | `/x/v2/history/toview/v2/list` | 替代 `toview/web`，可能更稳（未实测对比） |
| 12 | **弹幕点赞** | `POST /x/v2/dm/thumbup/add` | 为将来视频内弹幕做准备 |

### 4.3 值得知道但**不建议做**

| 能力 | 为什么不做 |
|---|---|
| 复刻 B站 `x-bili-gaia-*` / `fawkes-*` / `device-bin` | 这是设备指纹与风控体系。复刻 = 伪造设备身份，且随版本变化，维护成本极高 |
| 复刻抖音 `X-Argus` / `SecSdk` | 算法是远程下发 JS + WebView 执行 + 触摸行为采集。要让 App 执行平台风控脚本才能拿到签名，属于规避访问控制 |
| 抖音 `aweme/*` 短视频系（详情/搜索/评论/点赞） | 全部卡在 Argus，本项目已如实标注"不实现" |
| 用 `x-bili-metadata-ip-region` 冒充评论属地 | 它是**请求方**的区域（国家级 `CN`），不是评论作者的位置。混用会造假数据 |

### 4.4 对现有代码的具体建议（按优先级）

1. **抖音 `room/info` 接入**（最高优先）：现在的 `findRoomInFeed` 要翻 3 批 feed 且空 body 率 71%，换成直查后进直播间从"可能失败"变成"1 个请求"。必需参数：`aid=6383` + `device_platform=web`（或 `webapp`）+ `version_code`，`room_id` 必须是**字符串** `id_str`（19 位整数经 number 中转会丢精度 → `30001 房间不存在`）。
2. **B站 `archive/related`**：详情页补"相关视频"，零成本（匿名）。
3. **B站 `card`**：详情页作者区补粉丝数/签名。
4. **抖音 `gift/list`**：直播间可以显示礼物面板（纯展示，不实现发送）。
5. **B站 `triple`**：需要登录，可以做成"长按点赞 = 三连"，但要做二次确认（会消耗硬币）。

---

## 五、边界与诚实清单

- **没做的**：jadx 全量反编译（只扫了字符串常量）、动态调试、证书固定绕过、签名算法复刻。
- **未验证的**：`triple` / `batch-deal` / `unfav-all` / `toview/v2/list` / `pgc/app/follow` 只确认了"路由存在于 dex 且返回 `-101`（需登录）"，**没有用真实账号验证写入是否生效**。
- **抖音 `aweme/*` 系**：只验证了"匿名拿不到"，没有尝试任何签名绕过。
- **样本时效性**：B站 8.91.1、抖音 40.7.0 是当前版本；接口会随版本变化，结论有保质期。
- **合规**：全部为公开接口的只读探测；未发送任何会改变账号数据的请求（写操作全部停在 `-101`）；未使用任何真实账号凭据。

---

## 六、附录：复现方式

```powershell
# 1) 取样本（B站需带 UA/Referer）
curl.exe -L -A "Mozilla/5.0 ... Chrome/134" -e "https://app.bilibili.com/" `
  -o bilibili-latest.apk "https://dl.hdslb.com/mobile/latest/iBiliPlayer-bili.apk"

# 2) 只抽 dex + manifest（.NET ZipFile，比解全包快）
#    见 D:\vf-samples 下的提取脚本

# 3) 扫接口清单
node scan_dex_apis.mjs <dex目录> <输出前缀>     # → *.json（URL/路径/host/签名关键字）

# 4) 扫签名体系
node scan_signatures.mjs                        # → x-bili-* 头、Argus 类名

# 5) 真实可达性验证
node probe_reachability.mjs                     # 抖音 17 个接口
node probe_bili.mjs                             # B站 17 个接口
```

样本与脚本位置：`D:\vf-samples\`（**仓库外**，APK 合计 526 MB，不纳入版本控制）。
