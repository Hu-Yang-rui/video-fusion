# 抖音直播真实可用能力 — 实测报告

生成时间：2026-10-19（所有结论均为本机当日真实网络请求，非引用文档）
探针目录：`tool/vf_dy_*.mjs` + `tool/vf_dy_decode.ps1`，全部可重复运行、不依赖一次性状态。
运行方式：

```powershell
$env:Path = "D:\flutter\bin;D:\android-sdk\platform-tools;" + $env:Path
cd "D:\DSH HZ\Video Fusion"
node tool/vf_dy_feed.mjs            # Q1 列表 + 字段树
node tool/vf_dy_fields.mjs          # Q1 精确字段结构
node tool/vf_dy_stream.mjs          # Q2 HLS 真拉分片
node tool/vf_dy_h264_tier.mjs       # Q2 每档真实 codec
node tool/vf_dy_flv_ts.mjs          # Q2 FLV + TS 编码
powershell -NoProfile -ExecutionPolicy Bypass -File tool/vf_dy_decode.ps1   # Q2 解码验证
node tool/vf_dy_offline.mjs         # Q3 下播/失效
node tool/vf_dy_cdn_auth.mjs        # Q3 CDN 鉴权与 403 指纹
node tool/vf_dy_replay.mjs          # Q3 replay 语义
node tool/vf_dy_creds.mjs           # Q4 登录态与 cookie 存在性
node tool/vf_dy_imfetch_body.mjs    # Q5 im/fetch 响应体
node tool/vf_dy_ws.mjs              # Q5 弹幕 wss
node tool/vf_dy_ws_raw.mjs          # Q5 wss 握手原始取证
node tool/vf_dy_roominfo_ablate.mjs # Q6 room/info 必需参数
node tool/vf_dy_roominfo_diff.mjs   # Q6 参数差异定位
node tool/vf_dy_enter.mjs           # Q6 端点候选枚举
node tool/vf_dy_interact.mjs        # Q7 写操作三档（只读）
node tool/vf_dy_short_fields.mjs    # Q8 推荐流字段穷举
node tool/vf_dy_orientation.mjs     # 朝向判据
```

---

## 结论速查表

| # | 问题 | 结论 | 标记 |
|---|---|---|---|
| 1 | 直播列表匿名可用 | 每批固定 6 条，485KB，171 字段/房间；空 body 率 ~70% 必须重试 | 【实测通过】 |
| 2 | 播放地址真能拉流 | 4 房间 × 4 档 = 16/16 全部取到真实 TS 分片（`0x47`）；FLV 也可拉 | 【实测通过】 |
| 2b | 分片能否解码 | FFmpeg 完整解码成功，抽帧 YAVG=92.6/114.4（非黑）；模拟器有 HEVC 软解 | 【实测通过】 |
| 2c | 档位真实编码 | hls_map 四档 **全是 HEVC/bytevc1**；H.264 只有 `md` 档（360p）且不在 hls_map | 【实测通过】 |
| 3 | 下播 / 地址失效区分 | 地址失效 = HTTP 403（两种 body 形态）；房间不存在 = `status_code=30001`；主播未在播 = `data={}`。**无法构造 status≠2 样本** | 【部分实测】 |
| 4 | 登录对直播有无增益 | **无增益**。列表/详情/播放地址全匿名可用；本机无可复用抖音 cookie | 【实测通过】 |
| 5 | 弹幕实时可收 | **不可用**。wss 升级返回 `HTTP/1.1 200 OK`（非 101），0 帧；无任何 signature 实现 | 【实测失败】 |
| 6 | 进直播间该调什么 | `/webcast/room/web/enter/` **匿名不可用**；改用 `webcast/room/info/?room_id=`（需 `device_platform=web`） | 【实测通过】 |
| 7 | 送礼/点赞/关注/发弹幕 | 点赞/送礼 = 需登录+需签名；发弹幕 = 路由未证实+需登录；关注 = 未找到可用路由。礼物**面板数据**匿名可取（1289 条） | 【实测通过（只读）】 |
| 8 | 短视频推荐流 | 匿名可用，真视频条目 play_addr = `video/mp4` `ftyp isom` HTTP 206。**README 结论成立**；但混发图文帖（`media_type=42`，地址是 mp3） | 【实测通过】 |

---

## 1. 直播列表 `webcast/feed`

### 请求（匿名、无 Cookie、无签名）

```
GET https://webcast.amemv.com/webcast/feed/?aid=1128&app_name=douyin_lite
    &device_platform=android&version_code=400701&device_type=Pixel7&os_version=13
    &channel=googleplay&language=zh&count=10&offset=0&type=0
user-agent: com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7;
            Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)
referer:    https://live.douyin.com/
```

### 响应

| 项 | 实测值 |
|---|---|
| HTTP | 200 |
| `status_code` | 0 |
| `status_msg` | **不存在**（不是 `"url doesn't match"`，真业务成功） |
| body | 485082B / 475690B |
| 房间条数 | **每批恒 6 条**（`count=1/2/5/6/8/10/20/50` 全部只给 6） |
| 空 body 间歇 | 7 次请求 5 次 `HTTP 200 len=0`（**71.4%**），第 2/5 次才成功 |

### 分页与筛选（新测，推翻"随便重试就能加载更多"）

```
count=1..50      → 一律 6 条
offset=0/6/12/20/40 → 每次 6 条，新增 6/2/2/4/3 条（offset 有微弱影响，不是真游标）
顶层 key         → data, extra, status_code（无 max_time/has_more 在顶层）
extra 里         → has_more:true, max_time:1792339148441, min_time:0, offset:0,
                   offset_type:0, total:6, log_pb.impr_id, now
同参数连打 6 次   → 累计去重 17 个不重复房间（6→9→12→13→16→17）
type=1/2/4       → 仍 6 条，category 混合，**不改变内容**
partition_id / category_id / secondary_category_id / live_id=1&category=545
                 → 全部无效（category 依然混合）→ **服务端不支持按分区筛选**
```

结论：**"加载更多"只能靠重复请求 + 本地按 `id_str` 去重**，且必须显式告知用户"抖音直播推荐流不提供分页/分区筛选"。

### 展示字段可用性（12/12 = 全部存在）

| 展示项 | 确切路径 | 实测样本 |
|---|---|---|
| 房间号 | `data[i].data.id_str` | `"7698007617718995727"`（19 位字符串） |
| 房间号（数字） | `data[i].data.id` | `7698007617718996000` ← **JS/精度截断，绝不可用** |
| 直播标题 | `title` | `"米莱狄打野才是真正的野王"` |
| 主播昵称 | `owner.nickname` | `"黄靖"` |
| 主播 UID | `owner.id_str` | `"1317653625700538"` |
| 主播头像 | `owner.avatar_thumb.url_list[0]` | `https://p26.douyinpic.com/aweme/100x100/…jpeg` |
| 封面 | `cover.url_list[0]`（2 张，`cover.uri`、`cover.avg_color` 也在） | `https://p11-webcast-sign.douyinpic.com/…webp` |
| 分区码 | `category` + `base_category` | `545` / `412` |
| **分区中文名** | `game_data.game_tag_info.game_tag_name` | `"王者荣耀"` ← **比手写映射表权威** |
| 观看人数（数值） | `user_count` | `12734` / `126` / `1677` / `4990` / `1` / `33` |
| 观看人数（展示串） | `stats.user_count_str` 或 `room_view_stats.display_long` | `"1万+"` / `"126"`；`"2856在线观众"` |
| 观看人数（数值·展示口径） | `room_view_stats.display_value` | `12356` |
| 累计观看 | `stats.total_user` / `stats.total_user_str` | `178093` / `"10万+"` |
| 点赞数 | `like_count` | `64558` |
| 状态 | `status` | **恒 2**（见下） |
| 播放地址 | `stream_url.hls_pull_url_map.{FULL_HD1,HD1,SD1,SD2}` | 见 §2 |
| 默认清晰度 | `stream_url.default_resolution` | `"HD1"` |
| 候选清晰度 | `stream_url.candidate_resolution` | `["SD1","SD2","HD1","FULL_HD1"]` |
| 档位中文名 | `stream_url.resolution_name` | `{FULL_HD1:"蓝光",HD1:"超清",ORIGION:"原画",SD1:"标清",SD2:"高清"}` |
| 朝向 | `stream_url.stream_orientation` | 1 或 2（见 §9） |
| 欢迎语（系统消息） | `im_info.welcome_messages[0]` | `"欢迎来到直播间！抖音严禁未成年人直播或礼物消费…"` |
| 弹幕输入框 | `comment_box.placeholder` | `"说点什么..."` |
| 分享/进房链接 | `share_url` | `https://webcast.amemv.com/douyin/webcast/reflow/<room_id>` |
| 主播抖音号 | `owner.display_id` / `owner.short_id` | `"28927344519"` / `28927344519` |
| 主播粉丝数 | `owner.follow_info.follower_count_str` | `"4.9万"` |

**不存在的字段（别写代码去找）**：`web_rid`（0/12）、`status_name`、`room_status`、`live_type`、`category_name`、`stats.display_concurrent_user_count`、`stats.user_count`、`linkmic_info`、`vertical_cover`、`landscape`、`anchor`/`anchors`、`live_play`、`ticket`。
**没有 `stat_display`，也没有 `pulse`。**

### 脱敏真实响应字段树（截断）

```jsonc
{
  "data": [                                   // Array(6)，每条是信封
    {
      // ★ 信封层实测 keys（27 个）：type, rid, data, tags, ad, is_recommend_card, tabs,
      //   is_pseudo_living, live_reason, open_data_room, live_status, is_live_explore,
      //   is_ad, skylight_biz_flag, content_category, live_recommend_info, live_source,
      //   latest_watch_time, latest_watch_time_str, camera_type, item_pitaya_param,
      //   user_id, item_log_pb, ending_page_recommend_reason, private_setting_text,
      //   user_open_id, web_rid
      "type": 1,
      "rid": "20261019003122F99A68F364C7ACAA8C10",   // 本次请求的 impr 串，不是房间号
      "live_reason": "rec",
      "live_status": 0,                      // ⚠️ 信封层这个恒 0，与房间对象的 status=2 不同层
      "is_pseudo_living": false,
      "is_recommend_card": false, "is_ad": false,
      "web_rid": "",                         // ★ 信封层有 web_rid 字段但恒空串
      "user_id": 0, "user_open_id": "", "content_category": 0, "tabs": [], "tags": [],
      "data": {                              // ★ 房间对象，171 个 key
        "id": 7698007617718996000,            // ⚠️ 精度已丢失，不可用
        "id_str": "7698007617718995727",
        "status": 2,                          // ★ 恒 2 = 直播中
        "title": "米莱狄打野才是真正的野王",
        "user_count": 12734,                  // ★ 当前在线
        "like_count": 64558,
        "create_time": 1792332081,
        "start_time": 1792332086,
        "finish_time": 1792336846,            // ⚠️ 直播中也有值，不能用来判下播
        "stream_close_time": 0,
        "last_ping_time": 1792336846,
        "category": 545, "base_category": 412,
        "orientation": 0,                     // ⚠️ 恒 0，无区分度
        "tags": [], "room_tag": 0, "content_tag": "",
        "video_feed_tag": "直播中",
        "game_data": { "game_tag_info": { "is_game": 1, "game_tag_id": 1010045,
                         "game_tag_name": "王者荣耀" } },   // ★ 真实分区名
        "cover": { "url_list": [ "<https://p11-webcast-sign.douyinpic.com/…webp>", "…" ],
                   "uri": "webcast-cover/751471…", "width": 400, "height": 400,
                   "avg_color": "#373752", "image_type": 0, "is_animated": false },
        "owner": { "id": 1317653625700538, "id_str": "1317653625700538",
                   "nickname": "黄靖", "sec_uid": "MS4wLjABAAAA…",
                   "display_id": "28927344519", "short_id": 28927344519,
                   "web_rid": "",              // ★ 空
                   "avatar_thumb":  { "url_list": ["https://p26.douyinpic.com/aweme/100x100/…jpeg", …] },
                   "avatar_medium": { "url_list": [ … ] },
                   "avatar_large":  { "url_list": ["…/1080x1080/…"] },
                   "follow_info": { "following_count": 236, "follower_count": 49136,
                                    "follower_count_str": "4.9万", "follow_status": 0 },
                   "pay_grade": { "level": 1 }, "level": … , "signature": … ,
                   /* 共 100 个 key */ },
        "stats": { "id": …, "id_str": "7698007617718995727",
                   "total_user": 181061, "total_user_str": "10万+",
                   "user_count_str": "1万+", "up_right_stats_str": "1万+",
                   "follow_count": 619, "fan_ticket": 0, "money": 0,
                   "gift_uv_count": 0, "digg_count": 0, "enter_count": 0,
                   "comment_count": 0, "like_count": 0,
                   "user_count_composition": { "city":0,"video_detail":0,"my_follow":0,"other":1 } },
        "room_view_stats": { "is_hidden": false, "display_value": 12356,
                             "display_short": "1万", "display_middle": "1万",
                             "display_long": "1万在线观众",
                             "display_short_anchor": "1.2万", "display_long_anchor": "1.2万在线观众",
                             "display_type": 1, "display_version": 1663849727 },   // ★ 仅 feed 有
        "stream_url": {
          "provider": 0, "id": …, "id_str": "696742121432417086",
          "default_resolution": "HD1",
          "candidate_resolution": ["SD1","SD2","HD1","FULL_HD1"],
          "resolution_name": { "FULL_HD1":"蓝光","HD1":"超清","ORIGION":"原画","SD1":"标清","SD2":"高清" },
          "stream_orientation": 2,             // ★ 1=竖屏 2=横屏（见 §9）
          "hls_pull_url": "",                  // ⚠️ 恒空字符串（0/12）
          "flv_pull_url": {},                  // ⚠️ 恒空对象（0/12）
          "rtmp_pull_url": "",
          "hls_pull_url_map": {                // ★ 唯一可用的档位表
            "FULL_HD1": "http://pull-hls-q95.douyincdn.com/thirdgame/stream-…_Thirdgame1A200uhd5.m3u8?expire=…&sign=…&arch_hrchy=h1&exp_hrchy=h2&major_anchor_level=…&t_id=…",
            "HD1": "…_Thirdgame1A200hd5.m3u8?…",
            "SD1": "…_hiqld5.m3u8?…",
            "SD2": "…_Thirdgame1A200sd5.m3u8?…"
          },
          "extra": { "width": 1920, "height": 1440, "fps": 0, "h265_enable": false, … },
          "live_core_sdk_data": {              // ★ 真实多协议地址藏在这里
            "pull_data": {
              "stream_data": "<字符串化 JSON, 44KB>",
              "options": {
                "default_quality": { "name":"超清", "sdk_key":"hd" },
                "quality_strategy": "default",
                "qualities": [
                  { "name":"标清",   "sdk_key":"ld",   "v_codec":"bytevc1", "resolution":"720x540",   "level":1, "v_bit_rate":1000000,  "fps":25 },
                  { "name":"高清",   "sdk_key":"sd",   "v_codec":"bytevc1", "resolution":"1440x1080", "level":2, "v_bit_rate":3000000,  "fps":59 },
                  { "name":"超清",   "sdk_key":"hd",   "v_codec":"bytevc1", "resolution":"1440x1080", "level":3, "v_bit_rate":4000000,  "fps":59 },
                  { "name":"蓝光",   "sdk_key":"uhd",  "v_codec":"bytevc1", "resolution":"1440x1080", "level":4, "v_bit_rate":20176896, "fps":59 },
                  { "name":"蓝光帧彩","sdk_key":"xuhd", "v_codec":"bytevc1", "resolution":"1440x1080", "level":7, "v_bit_rate":15000000, "fps":59 }
                ] } } } },
        "im_info": { "welcome_messages": ["欢迎来到直播间！抖音严禁未成年人直播或礼物消费…"],
                     "room_tag": "external", "hide_gift_message": "" },
        "danmaku_detail": 0,
        "comment_box": { "placeholder": "说点什么..." },
        "paid_live_data": { "paid_type": 0, "view_right": 0, "max_preview_duration": 0, … },
        "share_url": "https://webcast.amemv.com/douyin/webcast/reflow/7698007617718995727?did=…&iid=…&sec_user_id=…&with_sec_did=…",
        "pack_meta": { "scene": "aweme_live_square(prod_all_dc/rpc/topo)", "env":"prod", "dc":"lf", "cluster":"feed" },
        /* 共 171 个 key，其余为 UI/埋点/连麦/电商等无关字段 */
      }
    }
  ],
  "extra": { "has_more": true, "max_time": 1792339148441, "min_time": 0, "offset": 0,
             "offset_type": 0, "total": 6, "now": 1792339148445,
             "log_pb": { "impr_id": "…" }, "forbid_interpose": true,
             "unread_extra": "{\"channel_id\":21,…}", "user_extra_info": "{…}" },
  "status_code": 0
}
```

> 注意：信封层也有一个 `web_rid` 字段，但实测恒为空串；房间对象的 `owner.web_rid` 同样恒空。所以**匿名拿不到任何可用的 web_rid**（§6.1 已实测穷尽）。

### `status` 的确切语义（重要陷阱）

```
24 条样本（4 批）+ 后续 11 批 66 条 → status 恒为 2，从未出现其它值
伴随字段：video_feed_tag = "直播中"
         start_time < now  ✓
         finish_time 非 0 且 < now  ⚠️  ← 直播中也有 finish_time！
         stream_close_time = 0
         is_replay = false（全部）
         replay    = true 占 8/11（有回放可看，不代表已下播）
```

**抖音的 `status: 2` = 直播中**，与 B站的 `live_status: 1=直播中/2=轮播` 语义完全不同。
`douyin_adapter.dart:341` 的 `status == 2 ? 1 : 0` 映射**是正确的**；但 `lib/src/models/live.dart:126` 注释写着「2 轮播」，会让人误改。建议在模型注释里明确「平台各自定义，抖音 2=直播中」。

---

## 2. 播放地址真实可拉流

### 2.1 HLS 完整链路（4 房间 × 4 档 = 16/16 全通）

```
房间 7698007617718995727 / HD1
  ① GET …stream-696742121432417086_Thirdgame1A200hd5.m3u8?expire=…&sign=…
     → HTTP=200  content-type=application/x-mpegurl  len=265  1453ms
     → body 以 "#EXTM3U" 开头（media playlist，1 个分片，target=4，endList=false，seq=1792337028）
  ② GET 首个 .ts（Range: bytes=0-4095）
     → HTTP=206  content-type=video/mp2t
     → 首 8 字节 hex = 47 40 00 10 00 00 b0 0d
     → 0x47 同步字节，188 字节包长对齐（偏移 188 / 376 处仍是 0x47）
     ★ 标准 MPEG-TS，不是 fMP4

房间 7698007689713945384（master 变体也验过）
  ① → HTTP=200 content-type=application/vnd.apple.mpegurl len=452  body="#EXTM3U #EXT-X-VERSION:3 #EXT-X-STREAM-INF…"
  ② GET variant → 200 m3u8（3 分片，target=2）
  ③ GET .ts → 206，首 8 字节 47 40 00 11 00 00 b0 0d，188B 对齐 ✓
```

| 档位 | playlist HTTP=200 | 分片真取到（`0x47`/`ftyp`） |
|---|---|---|
| FULL_HD1 | 4/4 | **4/4** |
| HD1 | 4/4 | **4/4** |
| SD1 | 4/4 | **4/4** |
| SD2 | 4/4 | **4/4** |

**没有"1080p 取不到、只有 720p 能取"的情况——四档全部真实可拉。**

### 2.2 https 可用（`_normalizeScheme` 是对的）

```
feed 下发 http://…douyincdn.com/….m3u8
同址改 https://  → HTTP=206 len=1（Range bytes=0-0）✓
另一房间        → HTTP=200 len=453 ✓
```

### 2.3 FLV：feed 顶层为空，但地址真实存在且可拉

```
stream_url.flv_pull_url  = {}           0/12 有内容  ← Dart 现有第 3 级回退永不命中
stream_url.hls_pull_url  = ""           0/12 有内容  ← 第 2 级回退永不命中
真实 FLV 在 stream_url.live_core_sdk_data.pull_data.stream_data（字符串化 JSON）：
  data.{origin,uhd,hd,sd,ld,md,ao,xuhd}.{main,backup}.{flv,hls,lls}

实测（流式读 4KB 后断流）：
  hd.flv     → HTTP=200 ct=video/x-flv  5677B  魔数 FLV ver=1 hdrLen=9  host=pull-flv-q11.douyincdn.com
  sd.flv     → HTTP=200 ct=video/x-flv  4261B  FLV ✓
  origin.flv → HTTP=200 ct=video/x-flv  6657B  FLV ✓
  hd.lls     → HTTP=200 ct=application/json 35B  {"code":400,"message":"body er…  ✗（需 POST body）
```

⚠️ **踩坑记录**：FLV 是无限流，用 `arrayBuffer()` 读会永不 resolve（我第一版因此误判"FLV 不可用"）。必须流式读够就 cancel。

### 2.4 每档真实编码（ffprobe 读分片，不信 JSON 声明）

```
房间 7697991152271723273 (stream_orientation=2)
  ld     声明=bytevc1  ffprobe=hevc,Main,960,540
  sd     声明=bytevc1  ffprobe=hevc,Main,1280,720
  hd     声明=bytevc1  ffprobe=hevc,Main,1280,720
  origin 声明=bytevc1  ffprobe=hevc,Main,1920,1080
  md     声明=h264     ffprobe=h264,High,640,360     ← 唯一 H.264
  ao     声明=h264     只有 flv，无 hls（音频轨）
  hls_map:FULL_HD1 → hevc,Main,1920,1080 | hls_map:HD1 → hevc,Main,1280,720
房间 7697987924211747599 (stream_orientation=1)
  md → h264,High,360,640；ld/sd/hd/uhd/origin 全 hevc
```

TS 内部证据（PMT 解析）：

```
PAT: program 1 → PMT pid 4096/4097
ES : pid=256 stream_type=0x24  H.265/HEVC
     pid=257 stream_type=0x0F  AAC ADTS
```

**Dart 现在用的 hls_map 四档 100% 是 HEVC。H.264 只在 `md` 档（360p/15fps），且不在 hls_map 里，必须额外从 `stream_data` 取。**

### 2.5 能不能解码：能，且不是黑帧

```
ffmpeg 2026-07-20 full_build（与 media_kit/libmpv 同源解码器）

房间 7698007617718995727 HD1
  分片 1839580B 首 8 字节 [47 40 00 12 00 00 b0 0d]
  ffprobe: codec_name=hevc profile=Main 1440x1080 yuv420p r_frame_rate=60/1
           + aac LC
  ffmpeg -t 1 -f null -        → decode exit=0            ✅ 完整解码
  ffmpeg -frames:v 1 out.png   → 1440x1080 PNG 2407KB
                                  signalstats YAVG=92.6188  ✅ 非黑帧
房间 7697991395642018579 HD1
  961244B [47 40 00 10 00 00 b0 0d]  hevc Main 720x1280
  decode exit=0，YAVG=114.39          ✅

模拟器 HEVC 解码器存在：
  /vendor/etc/media_codecs.xml            c2.goldfish.hevc.decoder  video/hevc  (max 4 instances)
  /vendor/etc/media_codecs_google_video.xml OMX.google.hevc.decoder video/hevc  (AOSP 软解)
  model=sdk_gphone64_x86_64  Android 15
media_kit 自述：
  I/flutter: media_kit: Emulator detected.  Enforcing S/W rendering.
```

**结论：直播黑屏不是 HEVC 解码缺失。** 剩余嫌疑集中在 libmpv 的 header 传递（UA/Referer）与 https 证书链，需要在真机或人工点进直播页时抓 logcat 才能定论（本报告 §10 记录了自动化导航失败）。

---

## 3. 下播与失效处理

### 3.1 无法构造 `status != 2` 的样本（如实报告）

```
11 批 × 6 条 = 66 条房间，status 集合恒 [2]
type=1 / type=2 / type=4 仍全是 2
feed 里 is_replay 恒 false；replay=true 占 8/11（表示"有回放"，不是"已下播"）
```
→ **「接口对已结束房间返回什么」无法用 feed 直接实测**。只能给相邻证据（§3.3、§3.4）。

### 3.2 房间从 feed 消失 ≠ 下播（重要）

```
26 分钟前快照里的 5 个房间，现在：
  7698007617718995727  在feed=Y  room/info status=2 uc=16857 档位=4  旧快照地址 HTTP=200  新地址 HTTP=200
  7698007827515771689  在feed=Y  status=2 uc=7459  旧地址 200  新地址 200
  7698008051487787785  在feed=N  status=2 uc=1975  旧地址 200  新地址 200   ← 不在 feed 但仍在播
  7698012687837711158  在feed=Y  status=2 uc=5862  旧地址 200  新地址 200
  7697959724830018331  在feed=Y  status=2 uc=9446  旧地址 200  新地址 200
```
→ **不能把"feed 里查不到"当成"已下播"**（现有 `findRoomInFeed` 抛 `videoNotFound` 的语义是错的，见 §8 建议）。

### 3.3 播放地址失效指纹（多种 CDN，实测）

签名方案不止一种，按 CDN 节点不同：

| 方案 | query 参数 | 服务端 |
|---|---|---|
| A | `expire`(秒级) + `sign`(md5) + `arch_hrchy,exp_hrchy,major_anchor_level,t_id` | nginx / MCP_VCLOUD_LIVE / TLB |
| B | `keeptime` + `wsSecret` + `wsTime`(16 进制) + `wsSession,wsIPSercert,wsBindIP,wsserid,wsApp` | Tengine（阿里 remote-auth） |
| C | `auth_key` | Tengine |

篡改后的真实响应：

```
方案 A（expire+sign）
  原始地址                HTTP=200 ct=application/x-mpegurl len=467
  expire → 7 天前          HTTP=403 len=146 ct=text/html  server=nginx   "<html><head><title>403 Forbidden</title>…"
  expire → 7 天前（另一节点）HTTP=403 len=0   ct=-           server=MCP_VCLOUD_LIVE
  sign → 全 0             HTTP=403 len=146（nginx） / len=0（MCP_VCLOUD_LIVE）
  去掉 sign               HTTP=403 len=0
  stream 号改成不存在       HTTP=403 len=146 / len=0
  真实 .ts 分片            HTTP=206 ct=video/mp2t len=188 首字节 0x47 ✓
  分片 URL 无 expire/sign（签名在 playlist 层）→ 直接 206

方案 B（wsSecret+wsTime）
  原始 playlist           HTTP=200 len=442 "#EXTM3U #EXT-X-MEDIA-SEQUENCE:597445837…"
  改 expire/sign          HTTP=200 len=529 ← **无效**（这两个参数不存在，服务端不看）
  真实分片                HTTP=206 ct=video/MP2T len=188 首字节 0x47 ✓

猜分片名（把 seq 换成过去时间） → HTTP=400 len=145 / HTTP=404 len=150
```

**地址有效期实测**：`expire=1792942309` → 距今 **+168.0 小时（7 天）**。所以实践中"地址过期"几乎不会发生，**403 主要来自下播后 CDN 撤流或签名不匹配**。

### 3.3b ⚠️ 关键补充：CDN 鉴权强度**按节点不一致**，不能把 403 当唯一判据

第二轮抽样 5 个房间（`vf_dy_cdn_auth.mjs`），出现**三种完全不同的行为**：

```
① server=MCP_VCLOUD_LIVE      篡改 expire/sign → HTTP 403 len=0 ct=-        （严格校验）
② server=nginx / Tengine      篡改 expire/sign → HTTP 403 len=146/238/2575B
                               ct=text/html "<title>403 Forbidden</title>"   （严格校验，带 HTML）
③ server=Bytedance NSS        篡改 expire → HTTP 200 len=357 ct=application/x-mpegurl
                               body="#EXTM3U #EXT-X-TARGETDURATION:4 …"      ← ★ 照常返回可用 playlist！
                               篡改 sign  → HTTP 200 len=357                ← ★ 同样不校验
                               但改 stream 号 → HTTP 403 len=0               （只校验流是否存在）
④ 方案 B（wsSecret+wsTime）   篡改分片 wsSecret → HTTP 200 ct=video/MP2T    ← ★ 分片也不校验
   server=-                                    篡改 wsTime  → HTTP 403 len>400B text/html
```

**含义（必须写进代码注释）**：
- **不能**用"篡改签名后是否 403"来判定房间存活 —— 部分节点（Bytedance NSS）对签名完全放行。
- **能**用的存活判据是：① `room/info` 的 `status_code`（30001=不存在）与 `status`；② 对**原始下发地址**请求 playlist 得到 2xx + `#EXTM3U`。
- 403 有两种 body 形态（`len=0` 与 `text/html`），**两者都表示该节点拒绝**，但原因（撤流 / 签名 / 节点策略）无法从状态码区分。
- 因此 UI 侧的正确策略是：**403 一律先重取一次 `room/info` 拿新地址**；新地址仍 403 才提示"直播已结束或流已失效"；`status_code=30001` 才提示"房间不存在"。不要把 403 直接映射成"下播"。

### 3.4 UI 判据（可直接实现）

| 现象 | 判据 | 文案 |
|---|---|---|
| 网络失败 | HTTP 状态取不到（0 / timeout / DNS / ConnectionRefused） | "网络异常，请重试" |
| 地址被节点拒绝 | **HTTP 403**（body 可能是 0 长度，也可能是 nginx/Tengine 的 146B~2575B `403 Forbidden` HTML） | "直播流已失效，正在重新获取…" → **重取 room/info 一次**，新地址仍 403 才提示"直播已结束或流已失效" |
| 房间不存在/已销毁 | `room/info` 返回 `status_code=30001`，`data.message="room doesn't exist"`，`data.prompts="该直播室不存在"` | "该直播间不存在或已关闭" |
| 主播未在播 | `room/info_by_user` 返回 `status_code=0` 且 **`data` 是空对象 `{}`** | "主播暂未开播" |
| 需要登录 | `status_code=20003`，`data.message="User doesn't login"`，`prompts="请登录后进入直播间"` | "该内容需登录后观看" |
| 参数错误 | `status_code=10011`，`prompts="当前服务繁忙，请稍后重试"` | 归为"接口调用异常"（不是网络失败） |
| 路径不认识 | HTTP 200 + `{"status_code":0,"status_msg":"url doesn't match"}`（**50 字节**） | 绝不显示为成功 |

⚠️ 两点必须记住：
1. `status_msg="url doesn't match"` 时 **HTTP 200 且 status_code=0**。只看 HTTP 或只看 status_code 会把失败当成功。现有 `live_client.dart` 已校验 `status_msg`，保留。
2. **403 不能直接映射为"下播"**（见 §3.3b：不同 CDN 节点鉴权强度不一致，有的节点对签名放行、有的对撤流才 403）。唯一可靠的"下播/不存在"判据是 `room/info` 的 `status_code` 与 `status` 字段。

> 探针输出里的 `len=>400(HTML)` 只是"body 大于 400 字节"的分桶标签（我的脚本用长度分桶），**不代表该响应是 HTML**；具体是否 HTML 看同行的 `ct=` 列（例如 `ct=video/MP2T` 就是真实分片）。


---

## 4. 登录态对直播的影响

### 4.1 项目凭证存储机制（读 `credential_vault.dart` / `cookie_portable.dart`）

```
CredentialVault：key = "video_fusion.session." + platformId（抖音用 "douyin"）
  落点 = FlutterSecureStore → Windows 凭据管理器 / Android Keystore / iOS Keychain
  日志与 UI 只出口 safeSummary（platformId/userId/displayName/cookieCount/cookieNames/loggedInAt），绝不打印取值
CookiePortable:89  抖音必需 cookie 名 = ['sessionid','sessionid_ss','sid_tt','passport_csrf_token']
```

### 4.2 本机可复用抖音 cookie 存在性（只查存在，未打印任何值）

```
D:\vf-local\douyin_cookie.txt   MISSING
D:\vf-local\dy_cookie.txt       MISSING
D:\vf-local\douyin.txt          MISSING
D:\vf-local\cookie.txt          MISSING
D:\vf-local\                    DIR 11 项，文件名疑似凭证只有 bili_cookie.txt（B站，按要求未使用）
_mint/                          MISSING（浏览器 mint 工作区，含 cookie，已 gitignore）
%LOCALAPPDATA%\video_fusion     missing
%APPDATA%\video_fusion          missing
Windows 凭据管理器 cmdkey /list  无 video_fusion / douyin / flutter_secure 目标
环境变量 DY_COOKIE / DOUYIN_COOKIE / WEB_COOKIE / TTWID   全部 unset
```
→ **本机没有任何可复用的抖音登录态**。仓库里 grep 到 `sessionid|ttwid|passport_csrf_token` 的 9 个文件全是代码/探针中的**键名**，不是凭证值（未打印任何匹配行内容）。

### 4.3 A/B 实测：登录/访客态对直播有无增益

```
（ttwid 是匿名访客标识，不是登录态；这里作为"带 cookie vs 不带"的可测代理）
feed 匿名      : rooms=6 withStream=6 withCover=6 withNick=6 withUserCount=6 keysPerRoom=171
feed + ttwid   : rooms=6 withStream=6 withCover=6 withNick=6 withUserCount=6 keysPerRoom=171  ← 完全一致
room/info 匿名 : keys=163 status=2 user_count=1902 tiers=4 paid_live_data 完整可见
room/info +ttwid: keys=163 status=2 user_count=1902 tiers=4                      ← 完全一致
登录才下发的字段在匿名响应里：ticket=不存在  user_ticket=不存在  gift_list=不存在  diamond=不存在
（pay_grade/fansclub/score 出现，但那是 owner 对象里的公开字段，不是本用户登录态字段）
```

**结论：直播列表、房间详情、播放地址在未登录下 100% 完整可用；登录对直播没有任何增益。** 登录只影响互动（送礼/点赞/关注/发弹幕，见 §7）。

---

## 5. 弹幕：当前不可用（具体失败证据）

### 5.1 三层尝试，全部 0 帧

```
L1 无 signature 无 cookie  → 握手失败  帧=0 字节=0 真实弹幕条数=0
L2 带 ttwid（实测获取成功 len=127）无 signature → 握手失败 帧=0 字节=0
L3b 带伪 signature（32 位）+ ttwid → 握手失败 帧=0 字节=0
Node WebSocket 报错：Connection was closed before it was established
```

### 5.2 原始 TLS + 手写 Upgrade 取证（关键证据）

```
DNS：webcast100-ws-web-lq.douyin.com → 113.24.210.15,113.24.210.16  ✓ 可解析
     webcast5-ws-web-lf.douyin.com   → 59.42.248.103,107            ✓
     webcast100-ws-web-al.douyin.com → ENOTFOUND（该机房域名已不存在）
     webcast100-ws-web-lax / webcast1-ws-web-lf / ws-web-c1 / webcast-ws → ENOTFOUND

A. 真实房间 + 无 signature（完整 13 参数 + cursor + internal_ext）
   状态行: HTTP/1.1 200 OK          ← ★ 不是 101 Switching Protocols
   响应头: server: TLB, x-tt-logid: …, server-timing: inner; dur=1
           无 Upgrade、无 Sec-WebSocket-Accept
   content-length: 0，收到 550 字节后服务端关闭连接

B. 真实房间 + 伪 signature("a"×32)
   状态行: HTTP/1.1 200 OK          ← 与 A 完全相同（signature 内容不影响响应）

C. 基线：/webcast/im/push/v2/ 不带任何 query
   状态行: HTTP/1.1 502 Bad Gateway  body="<html>…<title>502 Bad Gateway</title>…<center>TLB</center>"
   → 证明路径活着，是参数/签名被上游拒

D. webcast5-ws-web-lf.douyin.com（另一机房）
   HTTP/1.1 200 OK  server: volc-dcdn  via: n173-214-162.gdguangzhou-mp03-ct.Creative  818B，同样不升级

E. live.douyin.com/webcast/im/push/
   HTTP/1.1 404 Not Found  server: Tengine  body="404 Page not found"

F. 纯 HTTPS GET（不发 Upgrade）同样参数
   HTTP=200 len=0 ct=null  server=TLB
```

### 5.3 HTTP 对等接口 `im/fetch` 也拿不到消息

```
穷举 11 种参数组合（web 基础 / +room_id / +user_unique_id / +need_persist_msg_count=15 /
  +cursor+internal_ext / 完整 wss 同款 13 参数 / +伪 signature / +signature=空串）
  → 全部 HTTP=200 len=27  body={"data":[],"status_code":0}   data = Array(0)
App 参数（aid=1128）任意组合 → HTTP=200 len=0
POST（无 body）web 参数 → HTTP=200 len=27 {"data":[],"status_code":0}
→ 没有 general_msg_list，加 signature（哪怕伪值）不改变响应
```

### 5.4 签名可得性

```
build/dyref/sign.js   MISSING
tool/sign.js          MISSING
assets/dyref/sign.js  MISSING
build/sign.js         MISSING
→ 仓库/本机不存在任何 signature 生成实现（与 danmaku_client.dart 的"项目不内置不执行"一致）
signature 的正确输入（PARAM_ORDER 13 参数拼 "k=v,k=v,…" 后 md5）实测可算出，例如
  cc76a837488155bda767482d6da3713c
但没有 webmssdk 就算不出 signature。
signature 是否有 HTTP 换取接口：webcast/sign/、im/sign/、push/sign/、sign/get/ → 404；
  webcast/room/push_sign/ → "url doesn't match"  ⇒ 无
```

### 5.5 历史弹幕兜底

```
webcast/room/chat_history/     → {"status_code":0,"status_msg":"url doesn't match"}
webcast/room/barrage_list/     → url doesn't match
webcast/room/danmaku/history/  → url doesn't match
webcast/chat/history/          → HTTP 404
webcast/room/chat/             → status_code=20003 "User doesn't login" / "请登录后进入直播间"
```

### 5.6 结论

**抖音直播弹幕当前不可用。失败点不是"缺签名所以没帧"，而是"没签名所以 HTTP 升级分支根本没进去"（拿到 200 而非 101）。** 真实弹幕条数 = **0**，无任何模拟数据。
`danmaku_client.dart` 的解析层与 `danmaku_codec.dart` 没问题，但**永远拿不到输入**。UI 应显示"弹幕暂不可用（缺少平台签名，本项目不实现）"，不要显示"连接中"或空列表冒充。

---

## 6. 进入直播间该调哪个接口

### 6.1 `/webcast/room/web/enter/` 匿名不可用（两种参数集都试过）

```
webcast.amemv.com/webcast/room/web/enter/  (App aid=1128 + App UA)  → 200 len=50 "url doesn't match"
webcast.amemv.com/webcast/room/web/enter/  (web aid=6383 + Chrome UA) → 200 len=50 "url doesn't match"
live.douyin.com/webcast/room/web/enter/                              → 200 len=0（空 body）
根因：feed 不下发 web_rid（0/12，owner.web_rid 也是空串），拿不到合法 web_rid
```

`web_rid` 可得性也实测穷尽：`share_url` 的 reflow 页（HTTP 200 / 82747B）正则不到 `web_rid`/`roomId`/`status`（JS 壳，只内嵌 pull-hls/pull-flv 域名）；`live.douyin.com/<display_id>` → 1.28MB HTML，但 `web_rid`/`roomId`/`user_count`/`wss://`/`"signature":` **全部未出现**，无 `RENDER_DATA` script。→ **匿名无法获得 web_rid**。

### 6.2 ✅ 替代端点 A：`webcast/room/info/?room_id=`（按房间号，推荐用于"进直播间"）

```
GET https://webcast.amemv.com/webcast/room/info/?aid=6383&app_name=aweme
    &channel=channel_id_web&device_platform=web&version_code=180800&room_id=<id_str>
user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) … Chrome/126.0.0.0 Safari/537.36
referer:    https://live.douyin.com/
（不带任何 cookie）
→ HTTP 200  len=56780  status_code=0  data 165 字段
```

**必需参数恰好 3 个**（逐项消融，每组打 3 次）：

```
删 aid                → len=0   ❌
删 device_platform    → len=0   ❌      值必须是 web（或 webapp）；android → len=0
删 version_code       → len=0   ❌
删 app_name/channel/version_name/browser_*/screen_*/timezone/cookie_enabled → 全部仍 ✅
channel=channel_pc_web + device_platform=web → ✅（channel 取值无所谓）
无 channel + device_platform=web → ✅
UA 不敏感：Chrome / 空 UA / App UA / curl UA / 完全不带 header → 全部 ✅
cookie 不敏感：带 ttwid、带假 __ac_nonce、先访问 live.douyin.com 预热 → 无差别 ✅
稳定性：同房间连打 12 次 → 非零 12/12（**不间歇，与 feed 不同，不需要重试**）
域名：只有 webcast.amemv.com ✅；live.douyin.com → 18B"404 Page not found"；
      webcast.bytedance.com → 546B；webcast.larkoffice.com → 33B；www.douyin.com → 非 JSON
```

其它踩坑形态：`room_id_str=` 或 `id_str=` → `status_code=10011 "Request params error"`；路径末尾多一个斜杠 → 10011；`room/info`（无尾斜杠）反而可以；HEAD → len=0（HEAD 不给 body，别拿 HEAD 判可用性）；`room_id` 传成 19 位 JS number（精度丢失）→ `status_code=30001`。

### 6.3 ✅ 替代端点 B：`webcast/room/info_by_user/?user_id=`（按主播）

```
GET https://webcast.amemv.com/webcast/room/info_by_user/?<web参数>&user_id=<owner.id_str>
→ HTTP 200 len=54276 status_code=0 data 163 字段
&sec_user_id=<owner.sec_uid> 同样可用（54266B）
只给 room_id 不给 user_id → data 空（57B）
⚠️ 该端点对 device_platform 不敏感（缺它也通），与 room/info 不同 → 别共用同一套参数串
```

### 6.4 权威性对比（同一房间同一时刻）

```
feed       : user_count=7698  status=2  档位=[FULL_HD1,HD1,SD1,SD2]  flv_pull_url={}  hls_pull_url=""
room/info  : user_count=7716  status=2  档位=[FULL_HD1,HD1,SD1,SD2]  flv_pull_url 4 档  hls_pull_url 235B
info_by_user: user_count=7732 status=2  档位 4                       flv 4 档          hls 235B
```

→ **`room/info` 比 feed 更新鲜，且额外下发 FLV 四档 + 顶层 `hls_pull_url`（feed 全为空）。**
→ info_by_user 独有 `short_touch_auth, life_groupon_info`；feed 独有 `extra, im_info, linker_detail, ecom_data, game_cp, room_view_stats, others, pico_info, game_data`。
→ **列表页用 feed（有 room_view_stats 展示串 + game_tag_name），进直播间用 room/info（有 FLV + 非空 hls_pull_url + 更新鲜的 user_count）。**

### 6.5 地址不可缓存

```
同 room_id 连查 2 次（间隔 1.2s）：
  第1次 {"status":2,"uc":17147,"exp":"1792943298","sign":"81077a33…"}
  第2次 {"status":2,"uc":16469,"exp":"1792943300","sign":"3bcecb20…"}
→ expire 与 sign 每次都重新签发 ⇒ 播放地址绝不持久化，每次进房重取
```

### 6.6 其它"进房"候选（全部失败，别再试）

```
webcast/room/enter/            → 200 len=0
webcast/room/info_by_id/       → "url doesn't match"
webcast/room/status/ preview/ barrage/ user/ anchor/ get/ detail/
webcast/room/list/ list_by_category/ search/ feed/ partition/ wish/list/ replay/ settings/
webcast/replay/feed/           → 404
webcast/category/list/         → 404
（webcast.amemv.com 对不认识的路径统一返回 200 + len=50 + status_msg="url doesn't match"）
```

---

## 7. 送礼 / 点赞 / 关注 / 发弹幕（严格只读，未发送任何写请求）

探测方法只有三种：无 body 的 GET（命中路由层，不会执行动作）、OPTIONS 预检、只读伴生接口。

| 能力 | 档位 | 证据 |
|---|---|---|
| **点赞** | **不能做（需登录 + 需签名）** | `webcast/room/digg/` GET 与 OPTIONS 均 → `status_code=20003`，`data.message="User doesn't login"`（路由存在，卡在鉴权） |
| **送礼** | **不能做（需登录 + 需签名）**；但**礼物面板匿名可取** | `webcast/gift/send/` → `20003 "User doesn't login"`。`webcast/gift/list/` → HTTP 200 / **3587320B** / `status_code=0`，`data.gifts` **1289 条** + `gift_group_infos` 6 组，字段含 `id,name,diamond_count,icon.url_list,for_linkmic,for_fansclub,combo,type,primary_effect_id,special_effects,region,manual…`（样例 `id=21021 name="芦花剑影" diamond_count=8999`） |
| **发弹幕** | **不能做（路由未证实 + 需登录）** | `webcast/room/chat/send/` GET/OPTIONS → `"url doesn't match"`（该域无此路径）；`webcast/room/chat/` → `20003 "User doesn't login" / "请登录后进入直播间"` |
| **关注** | **不能做（未找到可用路由）** | `webcast/room/follow/` → `"url doesn't match"`；App 域 `aweme/v1/commit/follow/user/` → `status_code=8 "用户未登录"`（存在但需登录+签名） |
| 房间弹幕开关（只读） | **能做** | feed 里 `comment_box.placeholder="说点什么..."`、`webcast_comment_tcs=0`、`comment_name_mode=0`、`filter_words=[]`、`paid_live_data.paid_type=0`（非付费房） |
| 历史弹幕兜底 | **不能做** | 见 §5.5 |

→ **UI 建议**：点赞/送礼/关注/发弹幕四个按钮一律置灰 + 说明「需登录，且平台要求远程下发签名（本项目不实现）」。送礼面板可以做**只读预览**（礼物名 + 抖币价 + 图标，匿名可得 1289 条），但绝不能给出"发送"入口。

---

## 8. 短视频侧顺带确认（Q8）

### 结论：README 的「抖音应用内播放 ✅」**成立**，但 Dart 缺一个过滤

```
GET https://api.amemv.com/aweme/v1/feed/?aid=1128&app_name=douyin_lite&device_platform=android
    &version_code=400701&count=8&type=0&device_id=…
user-agent: com.ss.android.ugc.aweme/400701 (…)     （无 Cookie、无签名、无 X-Argus）
→ HTTP=200  len=386141  status_code=0  aweme_list=6
```

真视频条目逐字段实测（2 条，探测 28 个地址）：

```
video.bit_rate[0].play_addr.url_list[0..3]  HTTP=206 ct=video/mp4  ftyp brand=isom (视频)
  hex=00 00 00 1c 66 74 79 70 69 73 6f 6d 00 00 02 00 69 73 6f 6d 69 73 6f 32 6d 70 34 31
      └ box size ┘└ ftyp ┘└ major=isom ┘      └ compatible: isom/iso2/mp41 ┘
video.play_addr.url_list[0]                 HTTP=206 ct=video/mp4  ftyp brand=isom (视频)
  hex=00 00 00 20 66 74 79 70 69 73 6f 6d 00 00 02 00 69 73 6f 6d 69 73 6f 32 61 76 63 31 6d 70 34 31
video.download_addr.url_list[0..2]          HTTP=206 ct=video/mp4  ftyp brand=isom (视频)
video.cover.url_list[0..1]                  HTTP=206 ct=image/webp RIFF…WEBP（封面，正常）
→ 视频容器 16 个 / 音频容器 0 个
```

字段存在性：`play_addr`、`play_addr_h264`、`play_addr_265`、`play_addr_lowbr`、`download_addr`、`download_suffix_logo_addr`、`bit_rate[]` 全在；**`video.dashed` / `video.dash` = ABSENT**（App 端 feed 不给 DASH）；`decode_key` 无、`blob_type` null（无加密）。

### ⚠️ 混发图文帖 —— 这才是"有声音、画面黑"的真因

```
media_type=4  → 真视频：duration>0、images=0、play_addr 是 video/mp4
media_type=42 → 图文帖：duration=0、images=2、play_addr 指向 .mp3 / audio/mp4（ID3 头 49 44 33）
同一次请求里两类混着来（实测一批 5 条：4 条 42 + 1 条 4）
```

`douyin_adapter.dart:1618` `_cachePlayback` 取 `video['play_addr']['url_list']` 的 first；`:1238` 读了 `video['duration']` 但**只用于算时长，没有过滤**。`_awemeToVideo` 在 `duration=0` 时仍返回 `availability: available` 的 UnifiedVideo。
→ **图文帖被当视频渲染 = 播放器只拿到音频轨 = 画面区全黑但 position 前进。这与"模拟器 media_kit 强制软渲染"的现象高度重合，两者可能一直是不同的问题。**

其它短视频接口现在**匿名不可用**（不能当兜底）：

```
aweme/v1/search/suggested/    → status_code=1
general/search/single/        → status_code=2483 "请先登录，再继续搜索吧"
aweme/v1/challenge/detail/    → HTTP 200 len=0
aweme/v1/web/hot/search/list/ → HTTP 200 len=0
aweme/v1/user/                → status_code=0（但 user 为空，未登录）
```

---

## 9. 朝向判据（横竖屏）

```
8 个房间，ffprobe 实测帧尺寸 vs stream_orientation：
  stream_orientation=2  n=5  竖屏=0 横屏=5   (1440x1080, 1280x720, 960x720, 1440x1080, 960x720)
  stream_orientation=1  n=3  竖屏=3 横屏=0   (720x1280, 720x1280, 720x1280)
  带 rotation(Display Matrix) 的：0/8
  房间顶层 orientation：8/8 恒为 0 → 完全无区分度
```

**`stream_orientation: 1 = 竖屏，2 = 横屏`。**

- `git show HEAD:…douyin_adapter.dart` 里是 `isPortrait: _toInt(room['stream_orientation']) != 1` → **判反**（横屏游戏直播会被 `BoxFit.cover` 裁切）。
- 工作区当前已是 `== 1`（`:358`），且 `:351-352` 注释写对 → **该改动与实测一致，别回退**。
- 建议再加保险：朝向最终以播放器上报的真实帧尺寸（mpv `video-size` / `video.width/height`）为准，`stream_orientation` 只作首屏预判。`orientation`（顶层）与 `extra.width/height` 都不可当判据。

---

## 10. 未能完成的一项（如实报告，未继续试错）

**模拟器实机直播页 logcat 未拿到。**

已完成：`adb install -r build/app/outputs/flutter-apk/app-debug.apk` → `Success`（`com.example.video_fusion`），启动后 media_kit 确实初始化：

```
I/media_kit: package:media_kit_libs_android_video attached.
I/flutter  : media_kit: Emulator detected.  /  Enforcing S/W rendering.
I/VideoOutputManager: create … / setSurfaceSize … 853 480
I/flutter  : VF [INFO] feed page loaded | source=bilibili:rcmd | received=12 | total=12
I/flutter  : VF [INFO] player: media opened | host=xy116x196x140x7xy.mcdn.bilivideo.cn | hasAudio=true
```

卡点：无法导航到「直播」tab。

```
uiautomator dump 只有 12 个节点、text 全为空（Flutter 不暴露语义树）
按底部导航坐标 input touchscreen tap 675/637/945 2300 点 4 次 → logcat 新增 flutter/VF 行数 = 0
系统侧反复出现：
  W/ActivityTaskManager: Unable to send transaction to client proc com.example.video_fusion: no app thread
  W/ActivityManager: pid 611 system sent binder code 7 with flags 1 to frozen apps and got error -32
  W/WindowManager: Exception thrown during dispatchAppVisibility Window{…video_fusion… EXITING} DeadObjectException
→ App 被系统判为 frozen / 无 app thread，input tap 未投递到 Flutter
MediaCodec / HEVC 相关日志 0 行，是因为根本没进直播页，不是因为没走解码
```

需要人工在模拟器窗口点一下，或用 `flutter run -d emulator-5554` 直跳直播路由。**但"黑屏 ≠ 解码问题"这个结论不受影响**：§2.5 的 FFmpeg 解码成功 + 模拟器存在 `c2.goldfish.hevc.decoder` / `OMX.google.hevc.decoder` 两条证据是独立的。

---

## 11. Dart 实现建议

### 11.1 直播列表：端点与字段映射表

端点保持 `webcast/feed`（App 参数），**字段映射需要改的地方**：

| 响应字段（确切路径） | 目标模型字段 | 现状 | 建议 |
|---|---|---|---|
| `data[i].data.id_str` | `LiveRoomSummary.roomKey` | ✅ 已用 | 保持；**绝不要用 `id`**（19 位精度丢失） |
| `data[i].data.id` | `LiveRoomSummary.roomId` | 用 `int.tryParse` | 保持（抖音恒 0 或失真值，只用 roomKey） |
| `title` | `LiveRoomSummary.title` | ✅ | 保持 |
| `owner.nickname` | `LiveRoomSummary.uname` | ✅ | 保持 |
| `owner.avatar_thumb.url_list[0]` | `faceUrl` | ✅ | 保持 |
| `cover.url_list[0]` | `coverUrl` | ✅ | 保持 |
| `owner.id_str` | `uid` | ✅ | 保持 |
| `category` | `categoryCode` | ✅ | 保持 |
| **`game_data.game_tag_info.game_tag_name`** | `areaName` / `categoryLabel` | ❌ 未用 | **优先用它**（平台下发的真实中文分区名），`categoryLabel(code)` 手写表降为兜底 |
| **`room_view_stats.display_long`**（`"1万在线观众"`）或 `stats.user_count_str` | 展示用人数 | ❌ 未用 | **新增字段** `onlineText`；数值仍用 `user_count` |
| `user_count` | `online` | ✅ | 保持 |
| `stats.total_user` | — | 部分用 | 可作"累计观看"次要展示 |
| `like_count` | — | ❌ | 可选新增 |
| `status` | `LiveRoomInfo.liveStatus` | `status==2?1:0` ✅ | 保持；**修 `models/live.dart:126` 注释**（抖音 2=直播中，不是轮播） |
| `stream_url.stream_orientation` | `LiveRoomInfo.isPortrait` | 工作区已改对 `==1` | 保持；`orientation`（顶层）不要用 |
| `im_info.welcome_messages[0]` | 弹幕区首条 `LiveMessage(type: system)` | ❌ | 弹幕不可用期间，用它当**真实**的房间公告展示（不是模拟数据） |
| `comment_box.placeholder` | 输入框提示 | ❌ | 可选 |
| `share_url` | 外部打开链接 | ❌ | 用于"在原平台打开" |

### 11.2 列表请求：重试与去重策略（必须改）

```dart
// 1) 空 body 重试：保留现有 5 次（实测 71% 空 body 率，5 次是下限不是上限）
// 2) 分页：offset 不是真游标；"加载更多"= 重复请求 + 本地 Set<String> 按 id_str 去重
//    实测 6 次同参数请求累计 17 个不重复房间（6→9→12→13→16→17）
// 3) 用 extra.has_more 与 extra.total 决定"是否继续显示加载更多"（extra.total 实测=6）
// 4) 不要向平台请求"某分区的房间"：partition_id/category_id/secondary_category_id/type
//    实测全部无效（返回的 category 依然混合）→ 分区筛选只能本地按 categoryCode 过滤
```

### 11.3 进直播间该调什么（新增，替换 `findRoomInFeed`）

```dart
/// 新：按 room_id 直查（匿名可用，165 字段，不间歇，无需重试）
/// GET https://webcast.amemv.com/webcast/room/info/
///     ?aid=6383&device_platform=web&version_code=180800&room_id=<id_str>
///     （app_name/channel/browser_*/screen_* 可选，device_platform 必须是 web 或 webapp）
/// UA  浏览器形态（App UA 也实测可通，但建议与参数集一致用浏览器 UA）
/// Referer https://live.douyin.com/
/// 不带任何 Cookie
///
/// 失败判据：
///   status_code==30001 → 房间不存在/已关闭（"该直播室不存在"）
///   status_code==10011 → 参数错误（检查是否误用 room_id_str / 是否传了精度丢失的 number）
///   status_code==20003 → 需登录
///   len==0 && HTTP==200 → 缺 device_platform=web 或 aid 不对（不是网络失败）
///   status_msg=="url doesn't match" → 路径错（50 字节）
```

`DouyinLiveClient.findRoomInFeed()` 应改为：**先调 `room/info`，只有查不到才回退 feed 扫描**。当前"找不到就抛 videoNotFound"是错的——实测房间离开 feed 后 `room/info` 仍返回 `status=2` 且地址可播。

### 11.4 播放地址：多档取法（修正现有三级回退 + 档位表）

**实测 6 个房间的档位真实质量（`hls_pull_url_map` 档位 → `stream_data.sdk_key` → 分辨率/码率/帧率）：**

```
房间 …0852658  FULL_HD1->uhd=1440x1080/蓝光/60fps/8536k   HD1->hd=1440x1080/超清/60fps/4000k
               SD2->sd=1440x1080/高清/60fps/3000k          SD1->ld=720x540/标清/25fps/1000k
房间 …1723273  FULL_HD1->uhd=1920x1080/蓝光/59fps/6015k   HD1->hd=1280x720/超清/59fps/4200k
               SD2->sd=1280x720/高清/59fps/2400k           SD1->ld=960x540/标清/25fps/1000k
房间 …3190463  FULL_HD1->uhd=1920x1080/蓝光/59fps/7855k   HD1->hd=1280x720/超清/59fps/6600k
               SD2->sd=1280x720/高清/30fps/2400k           SD1->ld=960x540/标清/25fps/1000k
房间 …7331215  HD1->hd=960x720/超清/59fps/4000k  SD2->sd=1024x768/高清/30fps/3000k  SD1->ld=720x540/标清/25fps/1000k
房间 …5891107  HD1->hd=720x1280/超清/30fps/4000k SD2->sd=540x960/高清/30fps/2000k   SD1->ld=480x853/标清/25fps/1000k
（6/6 房间的 resolution_name 都是 SD1="标清"、SD2="高清"）
（FULL_HD1->uhd 在部分房间 options.qualities 里缺失，标 '?'，需兜底）
```

**→ 真实质量排序：`FULL_HD1 > HD1 ≈ SD2 > SD1`。SD2（高清）明显高于 SD1（标清）。**

```dart
// ⚠️ 仍存在的 BUG（live_client.dart 当前工作区实测，2026-10-19）：
//   1) _qualityValue(:556) 仍是 'SD1'=>2000, 'SD2'=>1000  ← **反了**
//      实测 SD2=高清/1440x1080/3000k 高于 SD1=标清/720x540/1000k
//      注释还写着"保留原有的相对顺序（FULL_HD1 > HD1 > SD1 > SD2）"—— 这个前提本身就是错的
//      应改为：FULL_HD1=4000, HD1=3000, SD2=2000, SD1=1000（ORIGION/ORIGIN 按平台语义插位）
//   2) parseStream 的档位优先序(:364 与 :396) 是 [... 'SD1', 'SD2']
//      ← 同样把标清排在高清前面，应改成 [... 'SD2', 'SD1']
//   3) 更稳的做法：不要靠档位名猜顺序，直接用
//      stream_url.live_core_sdk_data.pull_data.options.qualities[].level
//      （实测 ld=1 sd=2 hd=3 uhd=4 xuhd=7）+ v_bit_rate 排序，
//      并用 sdk_key 映射回 hls_pull_url_map 的档位名：
//        FULL_HD1→uhd  HD1→hd  SD2→sd  SD1→ld  ORIGION→origin
//
// ✅ 已被（另一代理）改对、不要重复改的：
//   - _qualityLabel(:465) 现在 'SD1'=>'标清'、'SD2'=>'高清'，与实测 resolution_name 一致
//   - codecName 不再硬写 'avc'，改用 _codecNameFor(:513)（实测 hls_map 四档确为 hevc）
//   - isPortrait 已改为 stream_orientation == 1（见 §9）
//
// 三级回退的适用场景（实测）：
//   列表页（feed 数据）：只能用 stream_url.hls_pull_url_map
//     —— 顶层 hls_pull_url 恒 ""（0/12）、flv_pull_url 恒 {}（0/12），
//        现有第 2/3 级回退在 feed 上永不命中
//   进房后（room/info 数据）：hls_pull_url_map 优先，其次顶层 hls_pull_url(235B 非空)、
//     flv_pull_url(4 档非空)
//
// 解码兜底档（模拟器/低端机无 HEVC 时）：
//   从 stream_url.live_core_sdk_data.pull_data.stream_data（**字符串化 JSON，需 jsonDecode**）
//   取 data.md.main.hls / data.md.main.flv —— 实测 ffprobe=h264,High,360x640/640x360
//   代价：仅 360p/15fps。options.qualities[].v_codec 全是 bytevc1，只有 md 是 h264
//   ⚠️ 结构是 stream_data.data.<sdk_key>.main|backup.{flv,hls,lls}
//      —— 不是 data.media_list.<sdk_key>（早先按 media_list 取会取到空）
//
// FLV 备选：同一 stream_data 的 data.<sdk_key>.main.flv（实测 FLV ver=1 可拉）
//   ⚠️ FLV 是无限流，探测/预取时不能读完整 body
//   ⚠️ lls 档 GET 会返回 {"code":400,"message":"body er…}（需 POST），不要用
//
// scheme：保持 _normalizeScheme（http→https 实测 206/200 可用）
// master/media 两种 playlist 都存在：部分房间 .m3u8 直接是 media playlist（1~3 分片），
//   部分是 master（含 EXT-X-STREAM-INF，需再取 variant）；media_kit 自己会处理，
//   但**自研解析器两种都要支持**，且 variant/分片的相对 base 必须是 variant 的 URL
//   （不是 master 的），且 master 里的 variant host 可能是**裸 IP**（实测 http://59.37.89.99/pull-hls-q1.douyincdn.com/…）
//   或带 hash 的域名（51aa161c….livehwc4.com），分片可能带 vhost/edge_slice/txspiseq 参数
```

### 11.5 下播 / 失效如何区分（按 §3.4 表实现）

```
HTTP 取不到（0/timeout/DNS/refused）      → 网络失败，可重试
HTTP 403（body 0 长度 或 146B nginx HTML）→ 地址失效 → 重取 room/info 一次再失败则提示"直播已结束或流已失效"
status_code 30001                         → 房间不存在/已关闭（终态，不重试）
status_code 20003                         → 需登录
status_code 10011                         → 参数错误（代码 bug，不提示用户重试）
status_msg "url doesn't match"            → 路径错误（终态）
data 为空对象 {}                          → 主播暂未开播
地址不可缓存：expire/sign 每次重新签发 → 每次进房重取，绝不持久化
expire 距今实测 +168 小时 → "地址过期"在实践中罕见，403 主要来自下播撤流
```

### 11.6 弹幕当前该显示什么

```
状态：不可用（不是"连接中"、不是空列表）
文案：「抖音弹幕暂不可用：需要平台远程下发的签名（webmssdk），本项目不实现。」
可选的真实内容展示（不是模拟数据）：
  - im_info.welcome_messages[0]  → 作为一条系统公告气泡
  - comment_box.placeholder      → 输入框提示（输入后禁用发送）
  - like_count / stats.follow_count → 作为静态"互动热度"展示，不要伪装成实时弹幕流
禁止：用随机文本、历史缓存或本地构造的消息填充弹幕区。
```

### 11.7 短视频 feed 过滤（独立于直播，但同源 bug）

```dart
// _awemeToVideo 开头加：
final mediaType = (raw['media_type'] as num?)?.toInt();
final durationMs = (video['duration'] as num?)?.toInt() ?? 0;
if (durationMs <= 0 || mediaType != 4) {
  // 图文帖/音乐帖：play_addr 指向 .mp3 或 audio/mp4，没有视频轨
  // → 不要返回 availability: available
  return null;   // 或返回带 availability: unavailable + 说明"图文内容，无可播放视频"
}
```

---

## 12. 探针清单

> 说明：`tool/` 下 `vf_dy_*` 由**两个代理并行写入**。下表标注归属，避免你重复跑或误认来源。
> 归属为"本报告"的是本代理产出；标注"另一代理"的是我在 `tool/` 里看到但**未由我编写**的同类探针（其中 `vf_dy_portrait.mjs` 的参数串正是 §6 分歧的来源，我读了它的源码来定位差异）。

| 文件 | 归属 | 覆盖 |
|---|---|---|
| `tool/vf_dy_feed.mjs` | 本报告 | Q1 列表 + 空 body 率 + 字段可用性统计 + 播放地址导出 |
| `tool/vf_dy_fields.mjs` | 本报告 | Q1 精确字段结构（stats / stream_url / im_info / owner / 互动开关） |
| `tool/vf_dy_core.mjs` | 本报告 | Q1 `live_core_sdk_data.stream_data` 结构 + 逐档协议字段 |
| `tool/vf_dy_feed_paging.mjs` | 本报告 | Q1 count/offset/type/partition 有效性 + gift/list |
| `tool/vf_dy_stream.mjs` | 本报告 | Q2 HLS master→variant→分片全链路 + https 对照 |
| `tool/vf_dy_ts_codec.mjs` | 本报告 | Q2 TS PAT/PMT 解析取 stream_type |
| `tool/vf_dy_flv_ts.mjs` | 本报告 | Q2 FLV 首字节（流式读）+ 每档 TS 编码 |
| `tool/vf_dy_h264_tier.mjs` | 本报告 | Q2 每档 ffprobe 真实 codec |
| `tool/vf_dy_decode.ps1` | 本报告 | Q2 下载+ffprobe+完整解码+出帧+YAVG；模拟器 HEVC 解码器 |
| `tool/vf_dy_offline.mjs` | 本报告 | Q3 status 分布 + 下播路径探测 + 地址篡改/分片过期 |
| `tool/vf_dy_cdn_auth.mjs` | 本报告 | Q3 三种 CDN 鉴权方案 + 403 两种指纹 |
| `tool/vf_dy_replay.mjs` | 本报告 | Q3 replay 语义 + 纵向复验 + 地址抖动 |
| `tool/vf_dy_creds.mjs` | 本报告 | Q4 cookie 存在性 + 匿名完整性 A/B |
| `tool/vf_dy_ws.mjs` | 本报告 | Q5 wss 三层尝试 + PushFrame 解帧 |
| `tool/vf_dy_ws_raw.mjs` | 本报告 | Q5 原始 TLS Upgrade 取证（状态行/头/机房/DNS） |
| `tool/vf_dy_imfetch.mjs` | 本报告 | Q5 im/fetch、ws:// 明文、签名换取接口枚举 |
| `tool/vf_dy_imfetch_body.mjs` | 本报告 | Q5 im/fetch 响应体结构穷举 |
| `tool/vf_dy_enter.mjs` | 本报告 | Q6 进房端点候选枚举 |
| `tool/vf_dy_roominfo.mjs` | 本报告 | Q6 `room/info_by_user` 深挖 + 未播语义 |
| `tool/vf_dy_roominfo_id.mjs` | 本报告 | Q6 `room/info` 参数矩阵 + 不存在指纹 + 地址抖动 |
| `tool/vf_dy_roominfo_ablate.mjs` | 本报告 | Q6 必需参数逐项消融 + cookie/UA/域名/稳定性 |
| `tool/vf_dy_roominfo_diff.mjs` | 本报告 | Q6 与另一探针的参数差异逐变量隔离 |
| `tool/vf_dy_roominfo_repro.mjs` | 本报告 | Q6 len=0 成因翻转复现 |
| `tool/vf_dy_webrid.mjs` / `webrid2` / `webrid3` | 本报告 | Q6 web_rid 可得性（reflow/SSR/短号） |
| `tool/vf_dy_interact.mjs` | 本报告 | Q7 写操作只读探测（GET/OPTIONS/只读伴生） |
| `tool/vf_dy_short.mjs` / `vf_dy_short_fields.mjs` | 本报告 | Q8 推荐流 + 逐字段容器判定 |
| `tool/vf_dy_orientation.mjs` | 本报告 | §9 朝向 vs 真实帧尺寸 |
| `tool/vf_dy_emu_live.mjs` / `vf_dy_emu_nav.mjs` | 本报告 | §10 模拟器驱动（安装/启动/点按/抓日志） |
| `vf_dy_portrait.mjs`、`vf_dy_orient.mjs`、`orient2/3/4.mjs`、`vf_dy_roominfo_matrix.mjs`、`vf_dy_roominfo_verify.mjs`、`vf_dy_aweme_mediatype.mjs`、`vf_dy_live_parse.mjs` | 另一代理 | 与本报告主题重叠，非我编写 |

依赖的本机工具：`node v22.23.3`、`ffmpeg/ffprobe`（`C:\Program Files\ffmpg\bin`）、`adb`（`D:\android-sdk\platform-tools`）。
`vf_dy_decode.ps1` 为 ASCII-only（PowerShell 5.1 会错解无 BOM 的 UTF-8 脚本），且注意 PowerShell 变量名大小写不敏感（参数名不要与局部变量同名）。

**范围合规**：本代理未修改 `lib/**`、`test/**`、`tool/vf_bili_*`；未执行 `git commit`。
`git status` 里 `lib/` 与 `test/` 的改动全部来自并行代理（含 `live_client.dart` 的档位标签/codec 修正、`douyin_adapter.dart` 的 `isPortrait` 修正）—— 其中与本报告结论一致的部分见 §9、§11.4。

