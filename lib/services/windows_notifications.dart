import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:xml/xml.dart';

/// Windows の通知 1 件（トースト）。
class RawNotification {
  RawNotification({
    required this.id,
    required this.appId,
    required this.time,
    required this.title,
    required this.body,
    required this.context,
    this.launch,
  });

  final String id;

  /// 通知を出したアプリの ID（AUMID）。例: "MSTeams_8wekyb3d8bbwe!MSTeams",
  /// "com.squirrel.slack.slack"
  final String appId;
  final DateTime time;
  final String title;
  final String body;
  final String context;

  /// トーストの launch 属性（アプリによっては URL が入っている）。
  final String? launch;
}

/// Windows が保存している通知履歴データベース（wpndatabase.db）を読む。
///
/// %LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db は
/// ログイン中のユーザー自身が読めるファイルなので、管理者権限・組織の承認・
/// 各サービスの API 登録なしに Teams / Slack / Outlook の通知内容を取得できる。
/// Windows 側で非公開の形式のため、将来の Windows 更新で変わる可能性はある。
class WindowsNotificationReader {
  WindowsNotificationReader(this.workDir);

  /// DB のコピーを置く作業フォルダ。
  final Directory workDir;

  DateTime? _lastDbStamp;
  List<RawNotification> _cache = const [];
  String? lastError;

  static String? get databasePath {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null) return null;
    return p.join(local, 'Microsoft', 'Windows', 'Notifications',
        'wpndatabase.db');
  }

  static bool get isSupported {
    final path = databasePath;
    return Platform.isWindows && path != null && File(path).existsSync();
  }

  /// 通知履歴を新しい順に返す。DB が更新されていなければ前回の結果を返す。
  Future<List<RawNotification>> read({int limit = 500}) async {
    final src = databasePath;
    if (src == null || !File(src).existsSync()) {
      lastError = '通知データベースが見つかりません（Windows 10/11 のみ対応）';
      return const [];
    }

    final stamp = _latestModified(src);
    if (_lastDbStamp != null && stamp == _lastDbStamp) return _cache;

    try {
      final rows = await _query(src, '''
        SELECT n.Id AS nid, n.Payload AS payload, n.ArrivalTime AS arrival,
               h.PrimaryId AS appId
        FROM Notification n
        JOIN NotificationHandler h ON n.HandlerId = h.RecordId
        WHERE lower(n.Type) = 'toast'
        ORDER BY n.ArrivalTime DESC
        LIMIT $limit
      ''');
      final out = <RawNotification>[];
      for (final r in rows) {
        final parsed = _parse(r);
        if (parsed != null) out.add(parsed);
      }
      _cache = out;
      _lastDbStamp = stamp;
      lastError = null;
      return out;
    } catch (e) {
      lastError = '通知データベースの読み取りに失敗: $e';
      return _cache;
    }
  }

  /// 通知を出したことのあるアプリ ID と件数の一覧（設定画面の確認用）。
  Future<List<MapEntry<String, int>>> listApps() async {
    final src = databasePath;
    if (src == null || !File(src).existsSync()) return const [];
    final rows = await _query(src, '''
      SELECT h.PrimaryId AS appId, COUNT(n.Id) AS cnt
      FROM NotificationHandler h
      LEFT JOIN Notification n ON n.HandlerId = h.RecordId
      GROUP BY h.PrimaryId
      ORDER BY cnt DESC
    ''');
    return [
      for (final r in rows)
        MapEntry((r['appId'] ?? '').toString(), (r['cnt'] as int?) ?? 0)
    ];
  }

  DateTime _latestModified(String src) {
    DateTime latest = DateTime.fromMillisecondsSinceEpoch(0);
    for (final suffix in ['', '-wal']) {
      final f = File('$src$suffix');
      if (f.existsSync()) {
        final m = f.lastModifiedSync();
        if (m.isAfter(latest)) latest = m;
      }
    }
    return latest;
  }

  /// 本体は Windows のサービスが開いたままなので、WAL ごと作業フォルダに
  /// コピーしてから読む。コピーできない場合は読み取り専用で直接開く。
  Future<List<Row>> _query(String src, String sql) async {
    if (!workDir.existsSync()) workDir.createSync(recursive: true);
    final dst = p.join(workDir.path, 'wpn_copy.db');
    Database db;
    try {
      for (final suffix in ['-wal', '-shm']) {
        final old = File('$dst$suffix');
        if (old.existsSync()) old.deleteSync();
      }
      await File(src).copy(dst);
      for (final suffix in ['-wal', '-shm']) {
        final f = File('$src$suffix');
        if (f.existsSync()) await f.copy('$dst$suffix');
      }
      db = sqlite3.open(dst);
    } catch (_) {
      db = sqlite3.open(src, mode: OpenMode.readOnly);
    }
    try {
      return db.select(sql).toList();
    } finally {
      db.dispose();
    }
  }

  static const _fileTimeUnixEpoch = 116444736000000000;

  RawNotification? _parse(Row r) {
    final payload = r['payload'];
    final String xmlText;
    if (payload is Uint8List) {
      xmlText = _decode(payload);
    } else if (payload is String) {
      xmlText = payload;
    } else {
      return null;
    }

    final arrival = r['arrival'];
    final time = arrival is int && arrival > _fileTimeUnixEpoch
        ? DateTime.fromMicrosecondsSinceEpoch(
                (arrival - _fileTimeUnixEpoch) ~/ 10,
                isUtc: true)
            .toLocal()
        : DateTime.now();

    try {
      final doc = XmlDocument.parse(xmlText);
      final toast = doc.findAllElements('toast').firstOrNull;
      if (toast == null) return null;

      final texts = <String>[];
      final attribution = <String>[];
      for (final t in toast.findAllElements('text')) {
        final s = t.innerText.trim();
        if (s.isEmpty) continue;
        if (t.getAttribute('placement') == 'attribution') {
          attribution.add(s);
        } else {
          texts.add(s);
        }
      }
      final header = toast.findAllElements('header').firstOrNull;
      final headerTitle = header?.getAttribute('title')?.trim();
      if (headerTitle != null && headerTitle.isNotEmpty) {
        attribution.insert(0, headerTitle);
      }
      if (texts.isEmpty && attribution.isEmpty) return null;

      return RawNotification(
        id: 'wpn:${r['nid']}:$arrival',
        appId: (r['appId'] ?? '').toString(),
        time: time,
        title: texts.isNotEmpty ? texts.first : '',
        body: texts.length > 1 ? texts.sublist(1).join('\n') : '',
        context: attribution.join(' / '),
        launch: toast.getAttribute('launch'),
      );
    } catch (_) {
      return null;
    }
  }

  String _decode(Uint8List bytes) {
    // UTF-16LE (BOM FF FE) の場合もあるので判定する。
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      final codes = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        codes.add(bytes[i] | (bytes[i + 1] << 8));
      }
      return String.fromCharCodes(codes);
    }
    var start = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      start = 3;
    }
    return utf8.decode(bytes.sublist(start), allowMalformed: true);
  }
}
