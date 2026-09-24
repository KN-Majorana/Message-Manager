import 'package:flutter/material.dart';

import '../models/message_item.dart';
import '../services/hub.dart';
import '../services/native_window.dart';
import 'frame_panel.dart';
import 'resize_frame.dart';
import 'settings_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.hub});

  final MessageHub hub;

  Future<void> _openSettings(BuildContext context) async {
    // 貼り付けモードのままだと文字入力しにくいので、設定中は前面に出す。
    await NativeWindow.setPinned(false);
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SettingsPage(hub: hub),
    ));
    await NativeWindow.setPinned(hub.settings.pinnedToDesktop);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ResizeFrame(
        child: ListenableBuilder(
          listenable: hub,
          builder: (context, _) {
            final frames =
                hub.settings.frames.where((f) => f.enabled).toList();
            return DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                border: null /* 角は Windows 側で丸め、枠線も Windows が描く */,
              ),
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TitleBar(
                  hub: hub,
                  onSettings: () => _openSettings(context),
                ),
                Expanded(
                  child: frames.isEmpty
                      ? const Center(child: Text('表示するフレームがありません（設定で有効にしてください）'))
                      : _Grid(
                          topRatio: hub.settings.topRowRatio,
                          children: [
                            for (final f in frames)
                              FramePanel(
                                hub: hub,
                                frame: f,
                                state: hub.states[f.kind]!,
                              ),
                          ],
                        ),
                ),
              ],
            ),
            );
          },
        ),
      ),
    );
  }
}

/// 2 列のグリッド。4 つなら 2×2、3 つなら上 2・下 1 に並べる。
class _Grid extends StatelessWidget {
  const _Grid({required this.children, this.topRatio = 0.5});

  final List<Widget> children;

  /// 上段の高さの割合（配置案 3 では Teams・Slack の段を低くする）。
  final double topRatio;

  @override
  Widget build(BuildContext context) {
    // 案 A-2: 白いフレームの間を 1px の細い線で区切る
    const line = SizedBox(width: 1, height: 1);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      final pair = children.sublist(i, (i + 2).clamp(0, children.length));
      if (rows.isNotEmpty) rows.add(line);
      // 2 段のときだけ上段と下段の高さを変える
      final flex = children.length > 2
          ? (i == 0 ? (topRatio * 100).round() : ((1 - topRatio) * 100).round())
          : 1;
      rows.add(Expanded(
        flex: flex,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var j = 0; j < pair.length; j++) ...[
              if (j > 0) line,
              Expanded(child: pair[j]),
            ],
          ],
        ),
      ));
    }
    return ColoredBox(
      color: const Color(0xFFEFEFEF),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.hub, required this.onSettings});

  final MessageHub hub;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final total = SourceKind.values
        .where((k) => hub.settings.frame(k).enabled)
        .fold<int>(0, (sum, k) => sum + hub.unreadCount(k));
    final pinned = hub.settings.pinnedToDesktop;
    final times = hub.states.values
        .map((st) => st.updatedAt)
        .whereType<DateTime>()
        .toList()
      ..sort();
    String two(int v) => v.toString().padLeft(2, '0');
    final updated = times.isEmpty
        ? ''
        : '${two(times.last.hour)}:${two(times.last.minute)} 更新';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => NativeWindow.startDrag(),
      child: Container(
        height: 40,
        padding: const EdgeInsets.only(left: 18, right: 8),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xFFEFEFEF))),
        ),
        child: Row(
          children: [
            const Text('Message Manager',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                    color: Color(0xFF141414))),
            if (total > 0) ...[
              const SizedBox(width: 10),
              Text('新着 $total',
                  style: const TextStyle(
                      fontSize: 11, color: Color(0xFF8A8A8A))),
            ],
            const Spacer(),
            if (updated.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(updated,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFFA3A3A3))),
              ),
            _BarButton(
              icon: Icons.refresh,
              tooltip: '今すぐ更新',
              onPressed: hub.refreshAll,
            ),
            _BarButton(
              icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
              tooltip: pinned ? 'デスクトップに貼り付け中（クリックで解除）' : '通常表示中（クリックでデスクトップに貼り付け）',
              onPressed: () async {
                hub.settings.pinnedToDesktop = !pinned;
                await NativeWindow.setPinned(hub.settings.pinnedToDesktop);
                await hub.storage.saveSettings(hub.settings);
                hub.applySettings(hub.settings);
              },
            ),
            _BarButton(
              icon: Icons.settings_outlined,
              tooltip: '設定',
              onPressed: onSettings,
            ),
            _BarButton(
              icon: Icons.close,
              tooltip: '終了（予定のウィンドウも閉じます）',
              onPressed: () async {
                await NativeWindow.closeByTitle(NativeWindow.calendarTitle);
                await NativeWindow.close();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton(
      {required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      color: const Color(0xFF6B6B6B),
    );
  }
}
