import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/settings.dart';
import '../services/calendar.dart';
import '../services/native_window.dart';
import '../services/storage.dart';
import '../services/system.dart';
import 'resize_frame.dart';

const _ink = Color(0xFF141414);
const _muted = Color(0xFFA0A0A0);
const _secondary = Color(0xFF6E6E6E);
const _line = Color(0xFFEFEFEF);
const _accent = Color(0xFF0F6CBD);

String _two(int v) => v.toString().padLeft(2, '0');
String _hm(DateTime t) => '${t.hour}:${_two(t.minute)}';
const _week = ['月', '火', '水', '木', '金', '土', '日'];
String _md(DateTime d) => '${d.month}/${d.day}（${_week[d.weekday - 1]}）';

Color _parseColor(String hex) {
  final h = hex.replaceAll('#', '');
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? _accent : Color(v);
}

/// 予定のウィンドウ（Google カレンダーの今日〜数日分）。案 A-2 と同じ白基調。
class CalendarPage extends StatefulWidget {
  const CalendarPage({
    super.key,
    required this.storage,
    required this.settings,
    required this.service,
  });

  final Storage storage;
  final AppSettings settings;
  final CalendarService service;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late AppSettings _settings = widget.settings;
  List<CalendarEvent> _events = const [];
  String? _error;
  bool _loading = false;
  DateTime? _updatedAt;
  Timer? _poll;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(minutes: 5), (_) => _refresh());
    // 「進行中」「次」の表示を更新するため 30 秒ごとに描き直す
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() => _loading = true);
    // Message Manager 側で変えた設定（表示日数・貼り付け・透明度）を取り込む
    final latest = await widget.storage.loadSettings();
    if (!latest.calendarEnabled) {
      await NativeWindow.close();
      return;
    }
    if (latest.pinnedToDesktop != _settings.pinnedToDesktop) {
      await NativeWindow.setPinned(latest.pinnedToDesktop);
    }
    if (latest.opacity != _settings.opacity) {
      await NativeWindow.setOpacity(latest.opacity);
    }
    _settings = latest;
    try {
      final ev = await widget.service
          .fetch(days: latest.calendarDays)
          .timeout(const Duration(seconds: 60));
      _events = ev;
      _error = null;
      _updatedAt = DateTime.now();
    } on TimeoutException {
      _error = '予定の取得がタイムアウトしました（5 分後に再試行します）';
    } catch (e) {
      _error = e is StateError ? e.message : e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(CalendarEvent? e) async {
    if (_settings.calendarOpenTarget == 'notion') {
      if (await SystemIntegration.openNotionCalendar()) return;
    }
    final url = e?.link.isNotEmpty == true
        ? e!.link
        : 'https://calendar.google.com/calendar/r';
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = List.generate(
        _settings.calendarDays, (i) => today.add(Duration(days: i)));

    // 次の予定（今日の、まだ始まっていない最初の時刻つき予定）
    final next = _events
        .where((e) => !e.allDay && e.start.isAfter(now))
        .fold<CalendarEvent?>(null, (a, e) => a ?? e);

    // 日ごとのまとまり（見出し＋予定の行）
    final groups = <({Widget header, List<Widget> rows})>[];
    for (final d in days) {
      final end = d.add(const Duration(days: 1));
      final evs = _events
          .where((e) => e.start.isBefore(end) && e.end.isAfter(d))
          .toList();
      // 予定がない日は見出しごと表示しない
      if (evs.isEmpty) continue;
      final label = d == today
          ? '今日'
          : d == today.add(const Duration(days: 1))
              ? '明日'
              : '';
      groups.add((
        header: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(
            children: [
              if (label.isNotEmpty) ...[
                Text(label,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700, color: _ink)),
                const SizedBox(width: 6),
              ],
              Text(_md(d),
                  style: const TextStyle(fontSize: 11.5, color: _secondary)),
            ],
          ),
        ),
        rows: [
          for (final e in evs)
            _EventRow(
              event: e,
              now: now,
              isNext: identical(e, next),
              onTap: () => _open(e),
            ),
        ],
      ));
    }

    Widget emptyMessage() => Padding(
          padding: const EdgeInsets.only(top: 40),
          child: Center(
            child: Text(
              _settings.calendarDays == 1
                  ? '今日の予定はありません'
                  : 'この ${_settings.calendarDays} 日間の予定はありません',
              style: const TextStyle(fontSize: 11.5, color: _muted),
            ),
          ),
        );

    // 1 列：上から順に並べる
    Widget oneColumn() => ListView(
          padding: const EdgeInsets.only(bottom: 8),
          children: [
            for (final g in groups) ...[g.header, ...g.rows],
            if (groups.isEmpty && _updatedAt != null) emptyMessage(),
          ],
        );

    // 2 列：上から順に左の列を埋め、残りを右の列へ。
    // 日の途中で右の列に移るときは、右の列の先頭にもその日の見出しを出す。
    Widget twoColumns() {
      final units = <({Widget w, bool isHeader, Widget header})>[
        for (final g in groups) ...[
          (w: g.header, isHeader: true, header: g.header),
          for (final r in g.rows) (w: r, isHeader: false, header: g.header),
        ],
      ];
      var split = (units.length / 2).ceil();
      // 左の列が見出しだけで終わらないようにする
      if (split > 0 && split < units.length && units[split - 1].isHeader) {
        split -= 1;
      }
      final left = [for (final u in units.take(split)) u.w];
      final rest = units.skip(split).toList();
      final right = <Widget>[
        if (rest.isNotEmpty && !rest.first.isHeader) rest.first.header,
        for (final u in rest) u.w,
      ];
      // 左右の列はそれぞれ独立してスクロールする
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 8),
              children: left,
            ),
          ),
          const VerticalDivider(width: 1, thickness: 1, color: _line),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 8),
              children: right,
            ),
          ),
        ],
      );
    }

    return Scaffold(
      body: ResizeFrame(
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration:
              BoxDecoration(border: null /* 角は Windows 側で丸め、枠線も Windows が描く */),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => NativeWindow.startDrag(),
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.only(left: 16, right: 8),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(bottom: BorderSide(color: _line)),
                  ),
                  child: Row(
                    children: [
                      const Text('予定',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: _accent)),
                      const SizedBox(width: 8),
                      if (_loading)
                        const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.5, color: _muted),
                        ),
                      const Spacer(),
                      if (_updatedAt != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Text(
                              '${_updatedAt!.hour}:${_two(_updatedAt!.minute)} 更新',
                              style: const TextStyle(
                                  fontSize: 11, color: Color(0xFFA3A3A3))),
                        ),
                      _Btn(
                          icon: Icons.refresh,
                          tooltip: '今すぐ更新',
                          onPressed: _refresh),
                      _Btn(
                          icon: Icons.open_in_new,
                          tooltip: _settings.calendarOpenTarget == 'notion'
                              ? 'Notion カレンダーを開く'
                              : 'Google カレンダーを開く',
                          onPressed: () => _open(null)),
                      _Btn(
                          icon: Icons.close,
                          tooltip: '閉じる',
                          onPressed: NativeWindow.close),
                    ],
                  ),
                ),
              ),
              if (_error != null)
                Container(
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDECEC),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(_error!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFFB42318))),
                ),
              Expanded(
                child: _updatedAt == null && _error == null
                    ? const Center(
                        child: Text('読み込み中…',
                            style: TextStyle(fontSize: 11.5, color: _muted)))
                    : groups.isEmpty
                        ? oneColumn()
                        // 幅が十分あれば 2 列、狭ければ 1 列
                        : LayoutBuilder(
                            builder: (context, c) => c.maxWidth >= 600
                                ? twoColumns()
                                : oneColumn(),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.event,
    required this.now,
    required this.isNext,
    required this.onTap,
  });

  final CalendarEvent event;
  final DateTime now;
  final bool isNext;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final ongoing = e.isOngoing(now);
    final past = !e.allDay && !e.end.isAfter(now);
    final color = _parseColor(e.color);
    final badge = ongoing ? '進行中' : (isNext ? '次' : '');

    final row = InkWell(
      onTap: onTap,
      hoverColor: const Color(0xFFF7F7F7),
      child: Container(
        color: ongoing ? const Color(0xFFF3F8FD) : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 44,
              child: e.allDay
                  ? const Text('終日',
                      style: TextStyle(fontSize: 11, color: _secondary))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_hm(e.start),
                            style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: _ink)),
                        Text(_hm(e.end),
                            style:
                                const TextStyle(fontSize: 10.5, color: _muted)),
                      ],
                    ),
            ),
            Container(
              width: 3,
              height: 30,
              margin: const EdgeInsets.only(right: 10, top: 1),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: _ink,
                      fontWeight: ongoing || isNext
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                  if (e.location.isNotEmpty || e.calendarName.isNotEmpty)
                    Text(
                      e.location.isNotEmpty ? e.location : e.calendarName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: _secondary),
                    ),
                ],
              ),
            ),
            if (badge.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(left: 6, top: 1),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                  color: ongoing ? _accent : const Color(0xFFF2F2F2),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(badge,
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: ongoing ? Colors.white : const Color(0xFF3A3A3A))),
              ),
          ],
        ),
      ),
    );
    return past ? Opacity(opacity: 0.45, child: row) : row;
  }
}

class _Btn extends StatelessWidget {
  const _Btn(
      {required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(icon, size: 16),
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        color: const Color(0xFF6B6B6B),
      );
}
