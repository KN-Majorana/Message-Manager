import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/message_item.dart';
import '../models/settings.dart';
import 'gmail.dart';
import 'graph_mail.dart';
import 'outlook_app.dart';
import 'storage.dart';
import 'system.dart';
import 'windows_notifications.dart';

/// フレーム 1 つ分の表示状態。
class FrameState {
  List<MessageItem> items = const [];
  String? error;
  DateTime? updatedAt;
  bool loading = false;
}

/// 4 つの取得元をまとめて定期更新し、フレームごとの表示リストを作る。
class MessageHub extends ChangeNotifier {
  MessageHub(this.storage, this.settings);

  final Storage storage;

  /// 現在の設定。applySettings で差し替わるので、各サービスには
  /// 「現在の設定を返す関数」を渡している。
  AppSettings settings;

  late final GraphMailService graph = GraphMailService(storage, () => settings);
  late final GmailService gmail = GmailService(storage, () => settings);
  final OutlookAppService outlookApp = OutlookAppService();
  late final WindowsNotificationReader notifications =
      WindowsNotificationReader(Directory(p.join(storage.dir.path, 'work')));

  final Map<SourceKind, FrameState> states = {
    for (final k in SourceKind.values) k: FrameState()
  };

  /// 通知方式で拾ったものは Windows 側で消されても残るよう、ここに蓄積する。
  final Map<SourceKind, Map<String, MessageItem>> _history = {
    for (final k in SourceKind.values) k: {}
  };
  static const _historyFile = 'history.json';
  static const _historyCap = 300;

  /// 既読（クリック済み）の ID。
  final Set<String> _read = {};

  /// これより前に届いたものは最初から既読扱い（初回起動時に全件が未読になるのを防ぐ）。
  DateTime _unreadBaseline = DateTime.now();

  Timer? _notifyTimer;
  Timer? _apiTimer;
  bool _disposed = false;

  Future<void> init() async {
    await Future.wait([graph.load(), gmail.load(), _loadHistory()]);
    _rebuildNotificationFrames();
    _restartTimers();
    unawaited(refreshAll());
  }

  void applySettings(AppSettings s) {
    settings = s;
    _rebuildNotificationFrames();
    _restartTimers();
    unawaited(refreshAll());
  }

  void _restartTimers() {
    _notifyTimer?.cancel();
    _apiTimer?.cancel();
    _notifyTimer = Timer.periodic(
        Duration(seconds: settings.notificationPollSeconds),
        (_) => refreshNotifications());
    _apiTimer = Timer.periodic(
        Duration(seconds: settings.apiPollSeconds), (_) => refreshApis());
  }

  Future<void> refreshAll() async {
    await Future.wait([refreshNotifications(), refreshApis()]);
  }

  bool isUnread(MessageItem m) =>
      !_read.contains(m.id) && m.time.isAfter(_unreadBaseline);

  int unreadCount(SourceKind k) =>
      states[k]!.items.where(isUnread).length;

  // ---------------------------------------------------------------- 通知方式

  List<FrameSettings> get _notificationFrames => settings.frames
      .where((f) => f.enabled && f.mode == FetchMode.notification)
      .toList();

  bool _notifBusy = false;

  Future<void> refreshNotifications() async {
    final frames = _notificationFrames;
    if (frames.isEmpty || _notifBusy) return;
    _notifBusy = true;
    try {
      await _refreshNotifications(frames);
    } finally {
      _notifBusy = false;
    }
  }

  Future<void> _refreshNotifications(List<FrameSettings> frames) async {
    // 数秒おきに呼ばれ、ほぼ一瞬で終わるので読み込み中表示は出さない
    final raw = await notifications.read();
    var changed = false;
    for (final n in raw) {
      final appId = n.appId.toLowerCase();
      for (final f in frames) {
        if (!f.appIdKeywords
            .any((k) => k.trim().isNotEmpty && appId.contains(k.toLowerCase().trim()))) {
          continue;
        }
        final bucket = _history[f.kind]!;
        if (!bucket.containsKey(n.id)) {
          bucket[n.id] = MessageItem(
            id: n.id,
            kind: f.kind,
            sender: n.title,
            title: n.title,
            preview: n.body,
            context: n.context,
            time: n.time,
            openTarget: _safeLaunch(n.launch),
          );
          changed = true;
        }
        break; // 1 件の通知は最初に一致したフレームだけに入れる
      }
    }
    if (changed) {
      _trimHistory();
      unawaited(_saveHistory());
    }

    final now = DateTime.now();
    for (final f in frames) {
      final st = states[f.kind]!;
      st.items = _filter(f, _history[f.kind]!.values);
      st.error = notifications.lastError;
      st.updatedAt = now;
      st.loading = false;
    }
    _notify();
  }

  void _rebuildNotificationFrames() {
    for (final f in _notificationFrames) {
      states[f.kind]!.items = _filter(f, _history[f.kind]!.values);
    }
  }

  static const _allowedSchemes = {'https', 'msteams', 'slack'};

  /// 通知の launch 属性が安全な URL のときだけ開き先として使う。
  String? _safeLaunch(String? launch) {
    if (launch == null) return null;
    final uri = Uri.tryParse(launch.trim());
    if (uri == null || !_allowedSchemes.contains(uri.scheme.toLowerCase())) {
      return null;
    }
    return uri.toString();
  }

  // ---------------------------------------------------------------- API 方式

  Future<void> refreshApis() async {
    final frames = settings.frames
        .where((f) => f.enabled && f.mode != FetchMode.notification)
        .toList();
    await Future.wait(frames.map(_refreshApiFrame));
  }

  Future<void> _refreshApiFrame(FrameSettings f) async {
    final st = states[f.kind]!;
    if (st.loading) return;
    st.loading = true;
    _notify();
    try {
      final List<MessageItem> items;
      if (f.mode == FetchMode.outlookApp) {
        items = await _fromOutlookApp(f);
      } else {
      switch (f.kind) {
        case SourceKind.outlook:
          items = graph.signedIn
              ? await graph.fetch(f).timeout(const Duration(seconds: 60))
              : throw StateError('Outlook にサインインしていません（設定 → アカウント連携）');
        case SourceKind.gmail:
          items = gmail.signedIn
              ? await gmail.fetch(f).timeout(const Duration(seconds: 90))
              : throw StateError('Gmail にサインインしていません（設定 → アカウント連携）');
        case SourceKind.teams:
        case SourceKind.slack:
          items = const [];
      }
      }
      st.items = _filter(f, items);
      st.error = null;
      st.updatedAt = DateTime.now();
    } on TimeoutException {
      st.error = '${f.kind.label} の取得がタイムアウトしました（次の更新で再試行します）';
    } catch (e) {
      st.error = e is StateError ? e.message : e.toString();
    } finally {
      st.loading = false;
      _notify();
    }
  }

  /// PC の Outlook から読む。Teams フレームは Teams の通知メールだけ、
  /// Outlook フレームはそれ以外（Teams フレームが同じ方式のとき）を表示する。
  Future<List<MessageItem>> _fromOutlookApp(FrameSettings f) async {
    final folder = f.kind == SourceKind.outlook ? f.folder : 'inbox';
    final mails = await outlookApp
        .read(
            folder: folder,
            max: 150,
            readDetails: settings.outlookReadDetails)
        .timeout(const Duration(seconds: 100));
    final visible = f.unreadOnly ? mails.where((m) => m.unread) : mails;
    if (f.kind == SourceKind.teams) {
      return visible
          .where((m) => m.isTeamsNotification)
          .map(OutlookAppService.toTeamsItem)
          .toList();
    }
    final teams = settings.frame(SourceKind.teams);
    final teamsTakesThem = teams.enabled && teams.mode == FetchMode.outlookApp;
    return visible
        .where((m) => !(teamsTakesThem && m.isTeamsNotification))
        .map(OutlookAppService.toOutlookItem)
        .toList();
  }

  // ---------------------------------------------------------------- 共通

  List<MessageItem> _filter(FrameSettings f, Iterable<MessageItem> items) {
    List<String> norm(List<String> l) => l
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toList();
    // Gmail は検索式（from: / label:）でサーバー側が絞り込み済みなので二重にしない
    final serverFiltered = f.kind == SourceKind.gmail;
    final senders = serverFiltered ? const <String>[] : norm(f.senderFilter);
    final contexts = serverFiltered ? const <String>[] : norm(f.contextFilter);
    final excludes = norm(f.excludeWords);

    final out = items.where((m) {
      final text = m.searchText;
      if (excludes.any(text.contains)) return false;
      if (senders.isNotEmpty) {
        final s = '${m.sender}\n${m.title}'.toLowerCase();
        // 通知方式では送信者名が本文側に入ることもあるので全文も見る
        final target = f.mode == FetchMode.notification ? text : s;
        if (!senders.any(target.contains)) return false;
      }
      if (contexts.isNotEmpty && !contexts.any(text.contains)) return false;
      if (f.unreadOnly &&
          f.mode == FetchMode.notification &&
          _read.contains(m.id)) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    return out.take(f.maxItems).toList();
  }

  Future<void> open(MessageItem m) async {
    final f = settings.frame(m.kind);
    markRead(m);
    final ok = await SystemIntegration.open(m.openTarget ?? f.defaultOpenTarget);
    if (!ok && m.openTarget != null) {
      await SystemIntegration.open(f.defaultOpenTarget);
    }
  }

  void markRead(MessageItem m) {
    if (_read.add(m.id)) {
      if (settings.frame(m.kind).unreadOnly) _rebuildNotificationFrames();
      _notify();
      unawaited(_saveHistory());
    }
  }

  void markAllRead(SourceKind k) {
    for (final m in states[k]!.items) {
      _read.add(m.id);
    }
    _notify();
    unawaited(_saveHistory());
  }

  void _trimHistory() {
    for (final bucket in _history.values) {
      if (bucket.length <= _historyCap) continue;
      final sorted = bucket.values.toList()
        ..sort((a, b) => b.time.compareTo(a.time));
      final keep = sorted.take(_historyCap).map((m) => m.id).toSet();
      bucket.removeWhere((id, _) => !keep.contains(id));
    }
  }

  Future<void> _loadHistory() async {
    final j = await storage.readJson(_historyFile);
    if (j == null) {
      _unreadBaseline = DateTime.now();
      unawaited(_saveHistory()); // 基準時刻を記録しておく
      return;
    }
    final base = j['baseline'];
    if (base is int) {
      _unreadBaseline = DateTime.fromMillisecondsSinceEpoch(base);
    }
    final items = j['items'];
    if (items is Map) {
      for (final k in SourceKind.values) {
        final list = items[k.name];
        if (list is! List) continue;
        for (final e in list) {
          if (e is! Map) continue;
          final m = MessageItem.fromJson(Map<String, dynamic>.from(e));
          if (m != null) _history[k]![m.id] = m;
        }
      }
    }
    final read = j['read'];
    if (read is List) _read.addAll(read.whereType<String>());
  }

  Future<void> _saveHistory() async {
    // 既読 ID は新しいものから 3000 件まで保持
    final readList = _read.toList();
    final trimmed = readList.length > 3000
        ? readList.sublist(readList.length - 3000)
        : readList;
    await storage.writeJson(_historyFile, {
      'baseline': _unreadBaseline.millisecondsSinceEpoch,
      'items': {
        for (final k in SourceKind.values)
          k.name: _history[k]!.values.map((m) => m.toJson()).toList(),
      },
      'read': trimmed,
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    _apiTimer?.cancel();
    super.dispose();
  }
}
