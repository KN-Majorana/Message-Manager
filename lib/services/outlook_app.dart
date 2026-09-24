import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/message_item.dart';

/// PC 内の Outlook から読み取ったメール 1 通。
class OutlookMail {
  OutlookMail({
    required this.entryId,
    required this.subject,
    required this.senderName,
    required this.senderAddress,
    required this.time,
    required this.unread,
    required this.categories,
    required this.body,
  });

  final String entryId;
  final String subject;
  final String senderName;
  final String senderAddress;
  final DateTime time;
  final bool unread;
  final String categories;
  final String body;

  /// Teams が送ってくる通知メール（不在時のアクティビティ等）かどうか。
  /// 差出人アドレスは読まない設定でも判定できるよう、差出人名と件名も見る。
  bool get isTeamsNotification {
    final a = senderAddress.toLowerCase();
    final n = senderName.toLowerCase();
    if (a.contains('teams.microsoft.com') || a.contains('teams.mail.microsoft')) {
      return true;
    }
    if (n.contains('microsoft teams') || n == 'teams') return true;
    return _teamsSubject.hasMatch(subject);
  }

  static final _teamsSubject = RegExp(
    r'さんがメッセージを送信しました|さんが.*(メンション|返信|投稿)しました|'
    r'不在時のアクティビティ|Teams で.*(見逃|アクティビティ)|'
    r'sent you a message|mentioned you|replied to|posted in|missed activity',
    caseSensitive: false,
  );
}

/// クラシック版 Outlook（デスクトップアプリ）の受信トレイを、
/// Outlook 自身のオートメーション（COM）で読み取る。
///
/// Windows 標準の cscript（JScript）経由で呼ぶので追加のライブラリは不要。大学の管理者承認や
/// アプリ登録も要らない。Outlook が起動していなければ裏で起動される。
/// PC の電源が切れていた間に届いたメールも、Outlook が同期すれば読める。
class OutlookAppService {
  List<OutlookMail> _cache = const [];
  DateTime? _cachedAt;
  String _cachedKey = '';
  Future<List<OutlookMail>>? _running;

  /// [folder] は "inbox"（受信トレイ）または受信トレイ直下／最上位のフォルダ名。
  /// 同じ条件なら 20 秒以内の呼び出しは前回の結果を返す
  /// （Teams と Outlook の 2 フレームで同じ受信トレイを読むため）。
  /// [readDetails] が false のときは差出人アドレスと本文を読まない
  /// （Outlook の「プログラムによるアクセス」の確認が出ないようにするため）。
  Future<List<OutlookMail>> read(
      {String folder = 'inbox', int max = 150, bool readDetails = false}) {
    final key = '$folder|$max|$readDetails';
    final at = _cachedAt;
    if (key == _cachedKey &&
        at != null &&
        DateTime.now().difference(at) < const Duration(seconds: 20)) {
      return Future.value(_cache);
    }
    final running = _running;
    if (running != null && key == _cachedKey) return running;
    _cachedKey = key;
    final f = _run(folder, max, readDetails).whenComplete(() => _running = null);
    _running = f;
    return f;
  }

  Future<List<OutlookMail>> _run(
      String folder, int max, bool readDetails) async {
    if (!Platform.isWindows) {
      throw StateError('PC の Outlook 読み取りは Windows のみ対応です');
    }
    final dir = Directory('${Directory.systemTemp.path}\\message_manager');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final scriptFile = File('${dir.path}\\read_outlook.js');
    final outFile = File('${dir.path}\\outlook_${DateTime.now().microsecondsSinceEpoch}.json');

    String jsString(String v) => v
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\r', '')
        .replaceAll('\n', '');
    final script = _script
        .replaceAll('__FOLDER__', jsString(folder))
        .replaceAll('__OUT__', jsString(outFile.path))
        .replaceAll('__MAX__', '${max.clamp(10, 500)}')
        .replaceAll('__DETAILS__', readDetails ? 'true' : 'false');

    // cscript は BOM 付き UTF-16LE のスクリプトなら日本語を正しく読める
    final bytes = <int>[0xFF, 0xFE];
    for (final u in script.codeUnits) {
      bytes
        ..add(u & 0xFF)
        ..add(u >> 8);
    }
    await scriptFile.writeAsBytes(bytes, flush: true);

    final r = await Process.run(
      'cscript',
      ['//nologo', '//E:jscript', scriptFile.path],
    ).timeout(const Duration(seconds: 90));

    if (!outFile.existsSync()) {
      final err = '${r.stdout}\n${r.stderr}'.trim();
      throw StateError(
          'Outlook の読み取りに失敗しました${err.isEmpty ? '' : ': ${_short(err)}'}');
    }
    var text = await outFile.readAsString();
    try {
      outFile.deleteSync();
    } catch (_) {}
    if (text.startsWith('﻿')) text = text.substring(1);

    final j = jsonDecode(text) as Map<String, dynamic>;
    if (j['error'] != null) throw StateError(j['error'].toString());

    final raw = j['items'];
    final list = raw is List ? raw : const [];
    final mails = <OutlookMail>[];
    for (final e in list) {
      if (e is! Map) continue;
      final ms = e['time'];
      mails.add(OutlookMail(
        entryId: (e['id'] ?? '').toString(),
        subject: (e['subject'] ?? '').toString(),
        senderName: (e['name'] ?? '').toString(),
        senderAddress: (e['addr'] ?? '').toString(),
        time: ms is num
            ? DateTime.fromMillisecondsSinceEpoch(ms.toInt())
            : DateTime.now(),
        unread: e['unread'] == true,
        categories: (e['categories'] ?? '').toString(),
        body: (e['body'] ?? '').toString(),
      ));
    }
    _cache = mails;
    _cachedAt = DateTime.now();
    return mails;
  }

  static String _short(String s) {
    final line = s.split('\n').firstWhere((l) => l.trim().isNotEmpty,
        orElse: () => s);
    return line.length > 160 ? '${line.substring(0, 160)}…' : line;
  }

  static final _space = RegExp(r'\s+');
  static final _teamsLink =
      RegExp(r'https://teams\.microsoft\.com/l/[^\s"<>]+');

  /// Outlook フレーム用の表示データに変換する。
  static MessageItem toOutlookItem(OutlookMail m) => MessageItem(
        id: 'olk:${m.entryId}',
        kind: SourceKind.outlook,
        sender: m.senderAddress.isNotEmpty && !m.senderAddress.startsWith('/')
            ? '${m.senderName} <${m.senderAddress}>'
            : m.senderName,
        title: m.subject.isEmpty ? '(件名なし)' : m.subject,
        preview: _preview(m.body),
        context: m.categories,
        time: m.time,
        openTarget: 'outlook-entry:${m.entryId}',
      );

  /// Teams フレーム用。メール本文にある Teams のリンクを開き先にする
  /// （無ければそのメール自体を Outlook で開く）。
  static MessageItem toTeamsItem(OutlookMail m) {
    final link = _teamsLink.firstMatch(m.body)?.group(0);
    return MessageItem(
      id: 'olk-teams:${m.entryId}',
      kind: SourceKind.teams,
      sender: m.subject.isEmpty ? 'Microsoft Teams' : m.subject,
      title: m.subject,
      preview: _preview(m.body.replaceAll(_teamsLink, '')),
      context: '',
      time: m.time,
      openTarget: link ?? 'outlook-entry:${m.entryId}',
    );
  }

  static String _preview(String body) {
    final t = body.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(_space, ' ').trim();
    return t.length > 300 ? t.substring(0, 300) : t;
  }

  /// Outlook に IDispatch（遅延バインディング）で話しかける JScript。
  /// PowerShell は Office の型ライブラリ経由で接続するため、型ライブラリの登録が
  /// 壊れている PC（Office 更新後によくある）では失敗する。JScript はその影響を受けない。
  static const _script = r'''
var folderName = "__FOLDER__";
var outPath = "__OUT__";
var max = __MAX__;
var readDetails = __DETAILS__;

function esc(v) {
  var s = (v === null || v === undefined) ? "" : String(v);
  var r = "";
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i);
    var ch = s.charAt(i);
    if (ch == '"') r += '\\"';
    else if (ch == '\\') r += '\\\\';
    else if (c < 0x20) r += '\\u' + ('0000' + c.toString(16)).slice(-4);
    else r += ch;
  }
  return '"' + r + '"';
}
function save(text) {
  var st = new ActiveXObject("ADODB.Stream");
  st.Type = 2;
  st.Charset = "utf-8";
  st.Open();
  st.WriteText(text);
  st.SaveToFile(outPath, 2);
  st.Close();
}
function fail(msg) {
  save('{"error":' + esc(msg) + '}');
  WScript.Quit(0);
}

var ol, ns, inbox;
try {
  ol = new ActiveXObject("Outlook.Application");
  ns = ol.GetNamespace("MAPI");
  inbox = ns.GetDefaultFolder(6);
} catch (e) {
  fail("PC の Outlook に接続できません（クラシック版 Outlook が必要です）: " + e.message);
}

var folder = inbox;
if (folderName != "" && folderName != "inbox") {
  folder = null;
  var k, f;
  for (k = 1; k <= inbox.Folders.Count; k++) {
    f = inbox.Folders.Item(k);
    if (f.Name == folderName) { folder = f; break; }
  }
  if (folder == null) {
    var top = inbox.Parent.Folders;
    for (k = 1; k <= top.Count; k++) {
      f = top.Item(k);
      if (f.Name == folderName) { folder = f; break; }
    }
  }
  if (folder == null) fail("Outlook のフォルダ「" + folderName + "」が見つかりません");
}

var items = folder.Items;
items.Sort("[ReceivedTime]", true);
var parts = [];
var n = 0;
var it = items.GetFirst();
while (it != null && n < max) {
  try {
    if (it.Class == 43) {
      var addr = "";
      // SenderEmailAddress と Body は Outlook の保護対象（確認ダイアログが出ることがある）
      if (readDetails) { try { if (it.SenderEmailType != "EX") addr = it.SenderEmailAddress; } catch (e1) {} }
      var body = "";
      if (readDetails) { try { body = String(it.Body); if (body.length > 2000) body = body.substr(0, 2000); } catch (e2) {} }
      var ms = 0;
      try { ms = new Date(it.ReceivedTime).getTime(); } catch (e3) {}
      parts.push('{"id":' + esc(it.EntryID) +
        ',"subject":' + esc(it.Subject) +
        ',"name":' + esc(it.SenderName) +
        ',"addr":' + esc(addr) +
        ',"time":' + ms +
        ',"unread":' + (it.UnRead ? 'true' : 'false') +
        ',"categories":' + esc(it.Categories) +
        ',"body":' + esc(body) + '}');
      n++;
    }
  } catch (e4) {}
  it = items.GetNext();
}
save('{"items":[' + parts.join(',') + ']}');
''';
}
