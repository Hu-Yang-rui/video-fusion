/// 互动 UI 组件：点赞按钮、投币弹层、收藏夹选择面板、评论面板。
///
/// 设计要点（短视频场景）：
///  - 按钮无底色，靠投影保证在任何画面上可读
///  - 状态变化有明确视觉反馈（实心/空心、颜色、缩放）
///  - 进行中显示进度，防止重复点击
///  - 未登录时点击给出登录引导，不静默失败
///
/// # 收藏夹面板为什么不是"确认一下就完事"
///
/// 面板只做**选择**，写入与校验全部在 [InteractionController.applyFavoriteFolders]：
///  - 勾选态来自服务端 `fav_state`，不是本地记忆
///  - 应用按钮 → 控制器发一次 add/del → **重新拉服务端归属** → 成功才 pop
///  - 失败/假成功（平台 code=0 但归属没变）时面板**不关闭**，
///    用户看得见错误并能原地重试，而不是"提示已收藏、按钮没高亮"
library;

import 'package:flutter/material.dart';

import '../../adapters/platform_adapter.dart';
import '../../design/apple_tokens.dart';
import '../../design/components/apple_layout.dart';
import '../../models/interaction.dart';
import 'interaction_controller.dart';

/// 短视频右侧栏的互动按钮。
class InteractionRailButton extends StatelessWidget {
  const InteractionRailButton({
    super.key,
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.active,
    required this.onTap,
    this.pending = false,
    this.activeColor = const Color(0xFFFF2D55),
    this.enabled = true,
    this.disabledReason,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;

  /// 是否处于"已激活"状态（已点赞/已收藏）。
  final bool active;

  final VoidCallback onTap;
  final bool pending;
  final Color activeColor;
  final bool enabled;

  /// [enabled] 为 false 时的说明文案（长按/点击提示，不让按钮看起来坏了）。
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (pending) return;
        if (!enabled) {
          if (disabledReason != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(disabledReason!),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          return;
        }
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 状态切换动画：图标轻微放大再回落
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 1, end: active ? 1.12 : 1),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            builder: (context, scale, child) => Transform.scale(
              scale: pending ? 1 : scale,
              child: child,
            ),
            child: pending
                ? const SizedBox(
                    width: 34,
                    height: 34,
                    child: Padding(
                      padding: EdgeInsets.all(6),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white70,
                      ),
                    ),
                  )
                : Opacity(
                    // 不可用时降透明度但仍可读，不是"消失"或"灰死"
                    opacity: enabled ? 1 : 0.55,
                    child: Icon(
                      active ? activeIcon : icon,
                      size: 34,
                      color: active ? activeColor : Colors.white,
                      shadows: const [
                        Shadow(color: Color(0xB3000000), blurRadius: 8),
                        Shadow(color: Color(0x80000000), blurRadius: 3),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              height: 1.2,
              shadows: [
                Shadow(color: Color(0xB3000000), blurRadius: 6),
                Shadow(color: Color(0x80000000), blurRadius: 2),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 投币选择弹层（B 站特有：1 枚或 2 枚）。
///
/// 余额来自 [InteractionController.loadCoinBalance]（平台真实接口），
/// 拿不到时显示"余额未知"而**不是**假装无限：
/// 实测本测试账号余额为 0，若不前置检查，用户点"投 1 枚"只会收到
/// 一条平台失败码，观感是"按钮坏了"。
class CoinSheet extends StatefulWidget {
  const CoinSheet({
    super.key,
    required this.controller,
    required this.coinBalance,
  });

  final InteractionController controller;

  /// 当前硬币余额（平台未提供时为 null，显示"未知"）。
  final int? coinBalance;

  @override
  State<CoinSheet> createState() => _CoinSheetState();
}

class _CoinSheetState extends State<CoinSheet> {
  int _count = 1;
  bool _alsoLike = false;
  bool _loadingBalance = false;

  @override
  void initState() {
    super.initState();
    // 余额未知时进面板就查一次，用户看到的是真实数字
    if (widget.coinBalance == null) {
      _refreshBalance();
    }
  }

  Future<void> _refreshBalance() async {
    setState(() => _loadingBalance = true);
    await widget.controller.loadCoinBalance();
    if (mounted) setState(() => _loadingBalance = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final ctrl = widget.controller;
    final alreadyCoined = ctrl.state.coined;
    final remaining = 2 - alreadyCoined;
    final balance = ctrl.coinBalance;
    final insufficient = balance != null && balance <= 0;

    return Container(
      decoration: BoxDecoration(
        color: c.secondaryGroupedBackground,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppleRadius.sheet),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppleSpace.sm),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: c.separator,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: AppleSpace.lg),

            Text(
              remaining <= 0 ? '已经投过币了' : '投币支持',
              style: AppleType.title3.copyWith(color: c.label),
            ),
            const SizedBox(height: AppleSpace.xs),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  remaining <= 0
                      ? '每个视频最多投 2 枚硬币'
                      : (balance != null
                          ? '当前硬币余额：$balance'
                          : '硬币余额：${_loadingBalance ? '查询中' : '未知'}'),
                  style: AppleType.footnote.copyWith(color: c.secondaryLabel),
                ),
                if (balance == null && !_loadingBalance)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: InkWell(
                      onTap: _refreshBalance,
                      child: Icon(
                        Icons.refresh_rounded,
                        size: 14,
                        color: c.secondaryLabel,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppleSpace.xl),

            if (remaining > 0 && !insufficient) ...[
              // 数量选择：不超过剩余额度，也不超过余额
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppleSpace.xxxl,
                ),
                child: Row(
                  children: [
                    for (var i = 1; i <= remaining; i++) ...[
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _count = i),
                          child: AnimatedContainer(
                            duration: AppleMotion.fast,
                            height: 64,
                            decoration: BoxDecoration(
                              color: _count == i
                                  ? c.blue.withValues(alpha: 0.12)
                                  : c.fill,
                              borderRadius:
                                  BorderRadius.circular(AppleRadius.sm),
                              border: Border.all(
                                color:
                                    _count == i ? c.blue : Colors.transparent,
                                width: 1.5,
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.monetization_on_rounded,
                                  size: 24,
                                  color: _count == i
                                      ? c.orange
                                      : c.secondaryLabel,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$i 枚',
                                  style: AppleType.footnoteEmphasized.copyWith(
                                    color: _count == i ? c.blue : c.label,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (i < remaining) const SizedBox(width: AppleSpace.md),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppleSpace.lg),

              // 同时点赞
              AppleCheckRow(
                label: '同时点赞',
                value: _alsoLike,
                onChanged: (v) => setState(() => _alsoLike = v),
              ),
              const SizedBox(height: AppleSpace.lg),

              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppleSpace.xxl,
                ),
                child: SizedBox(
                  width: double.infinity,
                  height: AppleSize.minTapTarget,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.pop(context);
                      // 写操作与状态刷新由控制器完成（含余额作废与复查）
                      widget.controller.giveCoin(
                        count: _count,
                        alsoLike: _alsoLike,
                      );
                    },
                    child: Text('投 $_count 枚'),
                  ),
                ),
              ),
            ] else if (remaining > 0 && insufficient) ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppleSpace.xxl,
                ),
                child: Text(
                  '硬币余额为 0，无法投币。\n硬币通过每日观看、点赞等行为获取。',
                  textAlign: TextAlign.center,
                  style: AppleType.footnote.copyWith(color: c.secondaryLabel),
                ),
              ),
            ],

            const SizedBox(height: AppleSpace.lg),
          ],
        ),
      ),
    );
  }
}

/// 勾选行（Apple 风格）。
class AppleCheckRow extends StatelessWidget {
  const AppleCheckRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.trailing,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// 次级说明（如"32 个内容"）。
  final String? subtitle;

  /// 右侧附加控件（如「公开/私密」标记）。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppleSpace.xxl,
          vertical: 4,
        ),
        child: Row(
          children: [
            Icon(
              value
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 22,
              color: value ? c.blue : c.tertiaryLabel,
            ),
            const SizedBox(width: AppleSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppleType.body.copyWith(color: c.label),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: AppleType.caption2.copyWith(
                        color: c.tertiaryLabel,
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// 收藏夹选择面板。
///
/// # 行为契约（对应用户报的"无法选择收藏夹、收藏后不高亮"）
///
///  - 打开即调 [InteractionController.loadFavoriteFolders] 拿**真实夹列表**，
///    并通过逐夹扫描得到该视频的真实归属作为初始勾选态。
///    （B站的 `fav_state` 经实测与"该视频是否在此夹"无关，
///     所以归属必须扫描 `resource/list` —— 见控制器的说明。）
///  - 加载中 / 空列表 / 请求失败 / 登录失效 四种状态分别呈现，
///    不出现"点了没反应"。
///  - 「应用」是一次写请求（平台支持同时 add + del），
///    控制器写完会**重新扫描服务端归属**校验，确认生效才关闭面板。
///  - 取消（下拉关闭/关闭按钮）**不改任何数据**：选择只是本地草稿，
///    没点应用就丢弃 → 原状态完整保留。
class FavoriteSheet extends StatefulWidget {
  const FavoriteSheet({
    super.key,
    required this.controller,
  });

  final InteractionController controller;

  @override
  State<FavoriteSheet> createState() => _FavoriteSheetState();
}

class _FavoriteSheetState extends State<FavoriteSheet> {
  /// 用户的选择草稿（未点"应用"前不写服务端）。
  Set<int>? _draft;

  bool _applying = false;
  String? _applyError;

  @override
  void initState() {
    super.initState();
    // 每次打开都重新拉：收藏夹可被改名/新建，归属也可能在别的设备上变过
    widget.controller.loadFavoriteFolders();
  }

  /// 服务端真实归属（逐夹扫描结果），不是本地记忆。
  Set<int> get _serverIds => widget.controller.favoritedFolderIds;

  Set<int> get _selected => _draft ?? _serverIds;

  bool get _changed {
    final d = _selected;
    final s = _serverIds;
    return d.length != s.length || !d.containsAll(s);
  }

  /// 归属扫描是否只核对了一部分夹。
  ///
  /// 逐夹扫描有请求预算（实测 B站 连发 6 个请求就返回 HTTP 412
  /// 触发验证码），所以"某个夹既不在已收藏、也没被核对过"时
  /// 状态是**不知道**，必须显示出来，不能渲染成未勾选 ——
  /// 那是假的否定，用户会因此重复收藏。
  bool get _partialScan {
    final ctrl = widget.controller;
    // 平台根本不提供归属查询时不打"未核对"：那是"平台没这个信息"，
    // 不是"我没查完"，两者对用户是完全不同的事。
    if (!ctrl.supportsFolderOwnershipScan) return false;
    final folders = ctrl.favoriteFolders;
    if (folders.isEmpty) return false;
    return folders.any((f) => !ctrl.folderChecked(f.id));
  }

  Future<void> _apply() async {
    if (_applying) return;
    setState(() {
      _applying = true;
      _applyError = null;
    });
    final ok = await widget.controller.applyFavoriteFolders(_selected);
    if (!mounted) return;
    setState(() => _applying = false);
    if (ok) {
      Navigator.pop(context);
    } else {
      // 失败不关面板：让用户看到具体原因并能原地重试
      setState(() => _applyError = widget.controller.lastMessage);
      widget.controller.clearMessage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final ctrl = widget.controller;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, sheetScroll) {
        return Container(
          decoration: BoxDecoration(
            color: c.secondaryGroupedBackground,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppleRadius.sheet),
            ),
          ),
          child: ListenableBuilder(
            listenable: ctrl,
            builder: (context, _) {
              final folders = ctrl.favoriteFolders;
              return Column(
                children: [
                  const SizedBox(height: AppleSpace.sm),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: c.separator,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppleSpace.lg,
                      AppleSpace.md,
                      AppleSpace.sm,
                      AppleSpace.xs,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '收藏到',
                            style: AppleType.title3.copyWith(color: c.label),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(
                            Icons.close_rounded,
                            color: c.secondaryLabel,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ── 状态区：加载 / 错误 / 空 / 列表 ──────────
                  Expanded(
                    child: _buildBody(c, ctrl, folders, sheetScroll),
                  ),

                  // ── 底部操作条 ─────────────────────────────
                  if (folders.isNotEmpty) _buildFooter(c),
                  const SizedBox(height: AppleSpace.sm),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildBody(
    AppleColors c,
    InteractionController ctrl,
    List<FavoriteFolder> folders,
    ScrollController sheetScroll,
  ) {
    if (ctrl.favoriteFoldersLoading && folders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: AppleSpace.md),
            // 归属要逐夹扫描，145 条大夹可能要几秒，说清楚在做什么
            Text(
              ctrl.favoriteFoldersLoadedOnce
                  ? '正在核对已收藏的收藏夹…'
                  : '正在读取收藏夹…',
              style: AppleType.footnote.copyWith(color: c.secondaryLabel),
            ),
          ],
        ),
      );
    }

    if (ctrl.favoriteFoldersError != null && folders.isEmpty) {
      final e = ctrl.favoriteFoldersError!;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppleSpace.xxxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 34, color: c.red),
              const SizedBox(height: AppleSpace.md),
              Text(
                e.presentation.title,
                style: AppleType.bodyEmphasized.copyWith(color: c.label),
              ),
              const SizedBox(height: AppleSpace.xs),
              Text(
                e.userMessage,
                textAlign: TextAlign.center,
                style: AppleType.footnote.copyWith(color: c.secondaryLabel),
              ),
              const SizedBox(height: AppleSpace.lg),
              FilledButton(
                onPressed: () => ctrl.loadFavoriteFolders(),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (folders.isEmpty && ctrl.favoriteFoldersLoadedOnce) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppleSpace.xxxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.bookmark_add_outlined,
                size: 34,
                color: c.tertiaryLabel,
              ),
              const SizedBox(height: AppleSpace.md),
              Text(
                '还没有收藏夹',
                style: AppleType.bodyEmphasized.copyWith(color: c.label),
              ),
              const SizedBox(height: AppleSpace.xs),
              Text(
                '当前账号在该平台上没有可用的收藏夹，'
                '请先在平台内创建一个再回来。',
                textAlign: TextAlign.center,
                style: AppleType.footnote.copyWith(color: c.secondaryLabel),
              ),
            ],
          ),
        ),
      );
    }

    if (folders.isEmpty) return const SizedBox.shrink();

    return ListView(
      controller: sheetScroll,
      padding: const EdgeInsets.only(bottom: AppleSpace.md),
      children: [
        // 部分核对提示：逐夹扫描有请求预算（B站 连发 6 个请求即 412
        // 触发验证码），所以可能有些夹没核对完。
        //
        // 这里必须如实说"有些收藏夹还没核对完"，并把**未核对的行**
        // 标出来。不能把它们渲染成未勾选 —— 那是假的否定，
        // 用户会以为自己没收藏进去，进而重复收藏。
        if (_partialScan)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppleSpace.pageInset,
              AppleSpace.sm,
              AppleSpace.pageInset,
              0,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 13, color: c.orange),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '为避让人机验证限制，部分收藏夹尚未核对完；'
                    '标注「未核对」的收藏夹状态未知（不代表未收藏）。'
                    '勾选新收藏夹仍可正常收藏。',
                    style: AppleType.caption2.copyWith(
                      color: c.secondaryLabel,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        for (final f in folders)
          AppleCheckRow(
            label: f.title,
            subtitle: [
              if (f.isDefault) '默认',
              if (f.mediaCount != null) '${f.mediaCount} 个内容',
            ].join(' · '),
            value: _selected.contains(f.id),
            onChanged: (v) => setState(() {
              final next = _selected.toSet();
              if (v) {
                next.add(f.id);
              } else {
                next.remove(f.id);
              }
              _draft = next;
            }),
            trailing: _deltaBadge(c, f.id),
          ),
        if (_applyError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppleSpace.xxl,
              AppleSpace.md,
              AppleSpace.xxl,
              0,
            ),
            child: Text(
              _applyError!,
              style: AppleType.footnote.copyWith(color: c.red),
            ),
          ),
      ],
    );
  }

  /// 相对服务端归属的状态标记。
  ///
  /// 四种状态必须区分开：
  ///  - 服务端已确认包含 → 无标记（已勾选即可）
  ///  - 已核对但不包含 + 用户勾上 → 「将收藏」
  ///  - 服务端包含 + 用户取消 → 「将移出」
  ///  - **未核对** → 「未核对」：既不能说"将收藏"也不能显示成未收藏，
  ///    因为平台侧状态未知（扫描预算用尽或被限流中断）。
  Widget? _deltaBadge(AppleColors c, int id) {
    final ctrl = widget.controller;
    final inServer = _serverIds.contains(id);
    final inDraft = _selected.contains(id);

    if (!ctrl.supportsFolderOwnershipScan) {
      // 平台不提供归属：不显示"未核对"，只显示用户将要做的动作
      if (inDraft && !inServer) {
        return Text('将收藏', style: AppleType.caption2.copyWith(color: c.blue));
      }
      return null;
    }
    if (!ctrl.folderChecked(id) && !inServer) {
      // 未核对：只有用户勾了才提示会发生什么
      if (inDraft) {
        return Text(
          '将收藏（状态未核对）',
          style: AppleType.caption2.copyWith(color: c.orange),
        );
      }
      return Text(
        '未核对',
        style: AppleType.caption2.copyWith(color: c.tertiaryLabel),
      );
    }
    if (!inServer && inDraft) {
      return Text('将收藏', style: AppleType.caption2.copyWith(color: c.blue));
    }
    if (inServer && !inDraft) {
      return Text('将移出', style: AppleType.caption2.copyWith(color: c.orange));
    }
    return null;
  }

  Widget _buildFooter(AppleColors c) {
    return Container(
      decoration: BoxDecoration(
        color: c.secondaryGroupedBackground,
        border: Border(top: BorderSide(color: c.separator, width: 0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppleSpace.pageInset,
        AppleSpace.md,
        AppleSpace.pageInset,
        0,
      ),
      child: Row(
        children: [
          // 从所有收藏夹移除：明确区别于"取消勾选某一个"
          TextButton(
            onPressed: (_applying || _serverIds.isEmpty)
                ? null
                : () => setState(() => _draft = const {}),
            child: Text(
              '取消收藏',
              style: TextStyle(
                color: _serverIds.isEmpty ? c.tertiaryLabel : c.red,
              ),
            ),
          ),
          const Spacer(),
          FilledButton(
            onPressed: (_applying || !_changed) ? null : _apply,
            child: _applying
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(_confirmLabel),
          ),
        ],
      ),
    );
  }

  String get _confirmLabel {
    final added = _selected.difference(_serverIds).length;
    final removed = _serverIds.difference(_selected).length;
    if (added > 0 && removed > 0) return '更新收藏';
    if (added > 0) return '收藏到 $added 个';
    if (removed > 0) return '移出 $removed 个';
    return '无需更改';
  }
}


/// 评论面板（底部弹层，可滚动分页）。
class CommentSheet extends StatefulWidget {
  const CommentSheet({
    super.key,
    required this.controller,
  });

  final InteractionController controller;

  @override
  State<CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends State<CommentSheet> {
  // 注意：这里**不**自建 ScrollController。
  //
  // DraggableScrollableSheet 要求内部的滚动组件使用它通过 builder
  // 传进来的 controller，否则拖拽与滚动的坐标是两套，会出现
  // "拖不动"、"滚到顶不接管" 之类的交互冲突。
  //
  // 之前这里用独立的 _scroll，既和 sheetScroll 打架，
  // 又额外注册了一个每像素触发的监听器。现在改为：
  //  - ListView 直接用 sheetScroll
  //  - 触底加载改由 NotificationListener<ScrollNotification> 驱动

  @override
  void initState() {
    super.initState();
    if (!widget.controller.commentsLoadedOnce) {
      widget.controller.loadComments();
    }
  }

  /// 触底加载。由滚动通知驱动，不再每帧轮询位置。
  bool _onScrollNotification(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final remaining = n.metrics.maxScrollExtent - n.metrics.pixels;
    if (remaining < 400) {
      widget.controller.loadMoreComments();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, sheetScroll) {
        return Container(
          decoration: BoxDecoration(
            color: c.secondaryGroupedBackground,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppleRadius.sheet),
            ),
          ),
          // 用 ListenableBuilder 把"数据变化"的重建范围限制在内容区，
          // 不再用 setState 重建整个 DraggableScrollableSheet。
          //
          // 之前 _onChanged 里 setState(() {}) 会在每次
          // notifyListeners（含加载更多、点赞状态刷新）时重建
          // sheet 几何 + 标题 + 整个列表，滚动中触发会明显掉帧。
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final ctrl = widget.controller;
              return Column(
                children: [
                  // 拖拽条 + 标题
                  const SizedBox(height: AppleSpace.sm),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: c.separator,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppleSpace.lg,
                      AppleSpace.md,
                      AppleSpace.sm,
                      AppleSpace.sm,
                    ),
                    child: Row(
                      children: [
                        Text(
                          ctrl.commentTotal > 0
                              ? '评论 ${_fmtCount(ctrl.commentTotal)}'
                              : '评论',
                          style: AppleType.title3.copyWith(color: c.label),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(
                            Icons.close_rounded,
                            color: c.secondaryLabel,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const AppleDivider(indent: 0),

                  // IP 属地缺失时给一句明确说明（面板级，不是每条评论）。
                  if (_ipLocationNotice(ctrl) != null)
                    _IpLocationNotice(text: _ipLocationNotice(ctrl)!),

                  Expanded(
                    child: _buildBody(c, ctrl, sheetScroll),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// 属地缺失说明文案。可得时不返回内容（不占位、不空行）。
  ///
  /// 三种缺失原因分开表述：未登录是可以改变的状态，
  /// 已登录仍无则是平台限制——混为一谈会让用户反复登录却始终拿不到。
  static String? _ipLocationNotice(InteractionController ctrl) {
    return switch (ctrl.ipLocationAvailability) {
      IpLocationAvailability.unavailableAnonymous =>
        '评论 IP 属地暂不可用：未登录时平台不下发该字段。登录后可能可得。',
      IpLocationAvailability.unavailableLoggedIn =>
        '评论 IP 属地暂不可用：当前账号下平台未下发该字段。',
      IpLocationAvailability.available ||
      IpLocationAvailability.unknown =>
        null,
    };
  }

  Widget _buildBody(
    AppleColors c,
    InteractionController ctrl,
    ScrollController sheetScroll,
  ) {
    // 首次加载中
    if (ctrl.commentsLoading && ctrl.comments.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    // 加载失败：明确报错 + 重试
    if (ctrl.commentsError != null && ctrl.comments.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppleSpace.xxxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 36, color: c.red),
              const SizedBox(height: AppleSpace.md),
              Text(
                ctrl.commentsError!.presentation.title,
                style: AppleType.bodyEmphasized.copyWith(color: c.label),
              ),
              const SizedBox(height: AppleSpace.xs),
              Text(
                ctrl.commentsError!.userMessage,
                textAlign: TextAlign.center,
                style: AppleType.footnote.copyWith(color: c.secondaryLabel),
              ),
              const SizedBox(height: AppleSpace.lg),
              FilledButton(
                onPressed: () => ctrl.loadComments(refresh: true),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    // 空评论
    if (ctrl.comments.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 40,
              color: c.tertiaryLabel,
            ),
            const SizedBox(height: AppleSpace.md),
            Text(
              '还没有评论',
              style: AppleType.body.copyWith(color: c.secondaryLabel),
            ),
          ],
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: ListView.separated(
        controller: sheetScroll,
        padding: const EdgeInsets.only(bottom: AppleSpace.xxxl),
        itemCount: ctrl.comments.length + (ctrl.commentsHasMore ? 1 : 0),
        separatorBuilder: (_, _) => const AppleDivider(indent: 60),
        itemBuilder: (context, index) {
          if (index >= ctrl.comments.length) {
            return Padding(
              padding: const EdgeInsets.all(AppleSpace.lg),
              child: Center(
                child: ctrl.commentsLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: ctrl.loadMoreComments,
                        child: const Text('加载更多'),
                      ),
              ),
            );
          }
          final comment = ctrl.comments[index];
          // 稳定的 Key：翻页追加时 Flutter 能复用已构建的 element，
          // 而不是按位置错配导致整屏重建。
          return _CommentTile(
            key: ValueKey<String>(comment.id),
            comment: comment,
          );
        },
      ),
    );
  }

  static String _fmtCount(int n) {
    if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }
}

/// 单条评论。
///
/// 性能说明（列表滚动的关键路径）：
///  - 头像用 [ResizeImage] 限制解码宽度。评论头像原图常见 200×200，
///    不限制的话每条评论解码后占 160KB，滚动时内存与解码开销叠加明显。
///    限制到 64px 后单条约 16KB。
///  - 头像首字母在构造时算一次，避免每帧调用 `characters.first`
///    （字形簇分析，比取首个 code unit 贵得多）。
class _CommentTile extends StatelessWidget {
  _CommentTile({super.key, required this.comment})
      : _avatarInitial = _initialOf(comment.authorName);

  final VideoComment comment;

  /// 昵称首字（构造时计算一次）。
  final String _avatarInitial;

  static String _initialOf(String name) {
    if (name.isEmpty) return '?';
    return name.characters.first;
  }

  /// 头像解码目标宽度（逻辑像素 32 → 按 2x 屏取 64）。
  static const int _avatarDecodeWidth = 64;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppleSpace.lg,
        vertical: AppleSpace.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像
          CircleAvatar(
            radius: 16,
            backgroundColor: c.fill,
            backgroundImage: comment.authorAvatarUrl == null
                ? null
                : ResizeImage.resizeIfNeeded(
                    _avatarDecodeWidth,
                    _avatarDecodeWidth,
                    NetworkImage(
                      comment.authorAvatarUrl!,
                      headers: const {'Referer': 'https://www.bilibili.com/'},
                    ),
                  ),
            child: comment.authorAvatarUrl == null
                ? Text(
                    _avatarInitial,
                    style: AppleType.caption1.copyWith(color: c.secondaryLabel),
                  )
                : null,
          ),
          const SizedBox(width: AppleSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.authorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppleType.footnoteEmphasized.copyWith(
                          color: c.secondaryLabel,
                        ),
                      ),
                    ),
                    if (comment.isUpAuthor) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: c.blue.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          'UP',
                          style: AppleType.caption2.copyWith(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: c.blue,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ],
                    if (comment.isPinned) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.push_pin_rounded,
                        size: 11,
                        color: c.orange,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  comment.message,
                  style: AppleType.footnote.copyWith(
                    color: c.label,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      _relativeTime(comment.createdAt),
                      style: AppleType.caption2.copyWith(
                        color: c.tertiaryLabel,
                      ),
                    ),
                    // IP 属地：与时间同权重，不额外加底色或徽标。
                    // 仅在平台确实返回时显示，缺失时整段不渲染。
                    if (comment.ipLocation != null) ...[
                      const SizedBox(width: AppleSpace.sm),
                      Text(
                        comment.ipLocation!,
                        style: AppleType.caption2.copyWith(
                          color: c.tertiaryLabel,
                        ),
                      ),
                    ],
                    if (comment.likeCount != null && comment.likeCount! > 0) ...[
                      const SizedBox(width: AppleSpace.md),
                      Icon(
                        Icons.thumb_up_outlined,
                        size: 11,
                        color: c.tertiaryLabel,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '${comment.likeCount}',
                        style: AppleType.caption2.copyWith(
                          color: c.tertiaryLabel,
                        ),
                      ),
                    ],
                    if (comment.replyCount != null &&
                        comment.replyCount! > 0) ...[
                      const SizedBox(width: AppleSpace.md),
                      Text(
                        '${comment.replyCount} 条回复',
                        style: AppleType.caption2.copyWith(
                          color: c.tertiaryLabel,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _relativeTime(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final diff = DateTime.now().toUtc().difference(dt.toUtc());
    if (diff.inDays > 365) return '${diff.inDays ~/ 365} 年前';
    if (diff.inDays > 30) return '${diff.inDays ~/ 30} 个月前';
    if (diff.inDays > 0) return '${diff.inDays} 天前';
    if (diff.inHours > 0) return '${diff.inHours} 小时前';
    if (diff.inMinutes > 0) return '${diff.inMinutes} 分钟前';
    return '刚刚';
  }
}

/// 评论面板顶部的属地缺失说明条。
///
/// 刻意做得轻：一行小字 + 信息图标，不占卡片、不加重底色。
/// 它的作用是"如实告知"，不是提醒用户去做什么。
class _IpLocationNotice extends StatelessWidget {
  const _IpLocationNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppleSpace.lg,
        AppleSpace.sm,
        AppleSpace.lg,
        AppleSpace.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1.5),
            child: Icon(
              Icons.info_outline_rounded,
              size: 13,
              color: c.tertiaryLabel,
            ),
          ),
          const SizedBox(width: AppleSpace.xs),
          Expanded(
            child: Text(
              text,
              style: AppleType.caption2.copyWith(
                color: c.tertiaryLabel,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
