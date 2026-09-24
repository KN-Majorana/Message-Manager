/// フレームの種類（画面上の配置順もこの順）。
enum SourceKind { teams, slack, outlook, gmail }

extension SourceKindX on SourceKind {
  String get label => switch (this) {
        SourceKind.teams => 'Teams',
        SourceKind.slack => 'Slack',
        SourceKind.outlook => 'Outlook',
        SourceKind.gmail => 'Gmail',
      };
}

/// 4 つのフレームに並べる 1 件分のメッセージ。取得元に関係なくこの形に揃える。
class MessageItem {
  MessageItem({
    required this.id,
    required this.kind,
    required this.sender,
    required this.title,
    required this.preview,
    required this.context,
    required this.time,
    this.openTarget,
  });

  /// 取得元の中で一意な ID（既読管理と重複排除に使う）。
  final String id;
  final SourceKind kind;

  /// 送信者の表示名（わからなければ空）。
  final String sender;

  /// 件名、または通知のタイトル行。
  final String title;

  /// 本文の抜粋。
  final String preview;

  /// チャンネル名・チーム名・ラベルなど、補足情報。
  final String context;

  final DateTime time;

  /// クリック時に開く対象。URL / プロトコル（msteams: など）/ 特殊指定
  /// （"outlook-entry:<hex>"）。null ならフレーム設定の既定の開き先を使う。
  final String? openTarget;

  /// フィルタ判定に使う連結テキスト（小文字）。
  String get searchText =>
      '$sender\n$title\n$preview\n$context'.toLowerCase();

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'sender': sender,
        'title': title,
        'preview': preview,
        'context': context,
        'time': time.millisecondsSinceEpoch,
        'openTarget': openTarget,
      };

  static MessageItem? fromJson(Map<String, dynamic> j) {
    try {
      return MessageItem(
        id: j['id'] as String,
        kind: SourceKind.values.byName(j['kind'] as String),
        sender: (j['sender'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        preview: (j['preview'] ?? '') as String,
        context: (j['context'] ?? '') as String,
        time: DateTime.fromMillisecondsSinceEpoch(j['time'] as int),
        openTarget: j['openTarget'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
