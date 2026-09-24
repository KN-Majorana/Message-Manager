import 'message_item.dart';

/// メッセージの取得方式。
enum FetchMode {
  /// Windows の通知履歴から拾う（管理者承認・API 登録が不要）。
  notification,

  /// 各サービスの API から取得する（Outlook = Microsoft Graph, Gmail = Gmail API）。
  api,

  /// PC 内のクラシック版 Outlook から受信トレイを直接読む（COM）。
  /// Teams フレームでは、Outlook に届いた Teams の通知メールを表示する。
  outlookApp,
}

extension FetchModeX on FetchMode {
  String labelFor(SourceKind k) => switch (this) {
        FetchMode.notification => 'Windows 通知',
        FetchMode.api => k == SourceKind.gmail ? 'Gmail API' : 'Microsoft Graph API',
        FetchMode.outlookApp =>
          k == SourceKind.teams ? 'Outlook に届く Teams の通知メール' : 'PC の Outlook',
      };
}

List<String> _strList(dynamic v) =>
    v is List ? v.map((e) => e.toString()).toList() : <String>[];

/// 設定ファイルの形式のバージョン。
const _schema = 2;

/// フレーム 1 つ分の設定。
class FrameSettings {
  FrameSettings({
    required this.kind,
    this.enabled = true,
    String? title,
    this.maxItems = 20,
    FetchMode? mode,
    List<String>? senderFilter,
    List<String>? contextFilter,
    List<String>? excludeWords,
    List<String>? appIdKeywords,
    String? defaultOpenTarget,
    this.folder = 'inbox',
    this.extraQuery = '',
    this.unreadOnly = false,
  })  : title = title ?? kind.label,
        mode = mode ?? defaultModeFor(kind),
        senderFilter = senderFilter ?? [],
        contextFilter = contextFilter ?? [],
        excludeWords = excludeWords ?? [],
        appIdKeywords = appIdKeywords ?? defaultAppKeywords(kind),
        defaultOpenTarget = defaultOpenTarget ?? defaultOpenFor(kind);

  final SourceKind kind;
  bool enabled;
  String title;
  int maxItems;
  FetchMode mode;

  /// 送信者（受信相手）でしぼり込む。いずれかを含めば表示。空なら全件。
  List<String> senderFilter;

  /// Teams: チーム名/チャンネル名、Slack: チャンネル名、
  /// Outlook: 分類(カテゴリ)、Gmail: ラベル名。いずれかに一致すれば表示。空なら全件。
  List<String> contextFilter;

  /// これらの語を含むものは表示しない。
  List<String> excludeWords;

  /// 通知方式のとき、通知元アプリを見分けるキーワード（アプリ ID の一部）。
  List<String> appIdKeywords;

  /// メッセージ固有の開き先が無いときに開くもの。
  String defaultOpenTarget;

  /// Outlook(API) のフォルダ名。"inbox" は受信トレイ。
  String folder;

  /// Gmail(API) の追加検索条件（Gmail の検索演算子そのまま）。
  String extraQuery;

  /// API 方式で未読だけを表示する。
  bool unreadOnly;

  static FetchMode defaultModeFor(SourceKind k) => switch (k) {
        SourceKind.teams || SourceKind.outlook => FetchMode.outlookApp,
        SourceKind.slack => FetchMode.notification,
        SourceKind.gmail => FetchMode.api,
      };

  /// その種類で選べる取得方式（先頭が既定）。
  static List<FetchMode> modesFor(SourceKind k) => switch (k) {
        SourceKind.teams => [FetchMode.outlookApp, FetchMode.notification],
        SourceKind.slack => [FetchMode.notification],
        SourceKind.outlook => [
            FetchMode.outlookApp,
            FetchMode.notification,
            FetchMode.api
          ],
        SourceKind.gmail => [FetchMode.api],
      };

  static List<String> defaultAppKeywords(SourceKind k) => switch (k) {
        SourceKind.teams => ['teams'],
        SourceKind.slack => ['slack'],
        SourceKind.outlook => ['outlook'],
        SourceKind.gmail => ['gmail'],
      };

  static String defaultOpenFor(SourceKind k) => switch (k) {
        SourceKind.teams => 'msteams:',
        SourceKind.slack => 'slack://open',
        SourceKind.outlook => 'outlook.exe',
        SourceKind.gmail => 'https://mail.google.com/',
      };

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'enabled': enabled,
        'title': title,
        'maxItems': maxItems,
        'mode': mode.name,
        'senderFilter': senderFilter,
        'contextFilter': contextFilter,
        'excludeWords': excludeWords,
        'appIdKeywords': appIdKeywords,
        'defaultOpenTarget': defaultOpenTarget,
        'folder': folder,
        'extraQuery': extraQuery,
        'unreadOnly': unreadOnly,
      };

  factory FrameSettings.fromJson(SourceKind kind, Map<String, dynamic> j,
      {int schema = _schema}) {
    FetchMode? mode;
    try {
      mode = FetchMode.values.byName(j['mode'] as String);
    } catch (_) {}
    // v1 の設定（Teams / Outlook が通知方式）は新しい既定の方式に切り替える
    if (schema < 2 && (kind == SourceKind.teams || kind == SourceKind.outlook)) {
      mode = null;
    }
    if (mode != null && !modesFor(kind).contains(mode)) mode = null;
    final kw = _strList(j['appIdKeywords']);
    return FrameSettings(
      kind: kind,
      enabled: j['enabled'] as bool? ?? true,
      title: j['title'] as String?,
      maxItems: ((j['maxItems'] as num?)?.toInt() ?? 20).clamp(1, 200),
      mode: mode,
      senderFilter: _strList(j['senderFilter']),
      contextFilter: _strList(j['contextFilter']),
      excludeWords: _strList(j['excludeWords']),
      appIdKeywords: kw.isEmpty ? null : kw,
      defaultOpenTarget: j['defaultOpenTarget'] as String?,
      folder: (j['folder'] as String?) ?? 'inbox',
      extraQuery: (j['extraQuery'] as String?) ?? '',
      unreadOnly: j['unreadOnly'] as bool? ?? false,
    );
  }
}

/// アプリ全体の設定。%APPDATA% 配下の settings.json に保存する。
class AppSettings {
  AppSettings({
    List<FrameSettings>? frames,
    this.pinnedToDesktop = true,
    this.autostart = true,
    this.opacity = 0.95,
    this.apiPollSeconds = 60,
    this.notificationPollSeconds = 10,
    this.graphClientId = '',
    this.graphTenant = 'organizations',
    this.googleClientId = '',
    this.googleClientSecret = '',
    this.outlookOpenInDesktop = true,
    this.outlookReadDetails = false,
    this.bounds,
    this.topRowRatio = 0.38,
    this.calendarEnabled = true,
    this.calendarDays = 2,
    this.calendarOpenTarget = 'notion',
  }) : frames = frames ??
            SourceKind.values.map((k) => FrameSettings(kind: k)).toList();

  final List<FrameSettings> frames;
  bool pinnedToDesktop;
  bool autostart;
  double opacity;
  int apiPollSeconds;
  int notificationPollSeconds;

  /// Microsoft Graph（Outlook の API 方式）用。Entra ID に登録したアプリのクライアント ID。
  String graphClientId;

  /// "organizations"（組織アカウント）またはテナント ID / ドメイン。
  String graphTenant;

  /// Gmail API 用。Google Cloud の「デスクトップ アプリ」OAuth クライアント。
  String googleClientId;
  String googleClientSecret;

  /// Outlook(API) のメッセージをデスクトップ版 Outlook で開く（false ならブラウザ）。
  bool outlookOpenInDesktop;

  /// PC の Outlook から差出人アドレスと本文も読む。Outlook の設定によっては
  /// 「プログラムによるアクセス」の確認が出るので既定はオフ。
  bool outlookReadDetails;

  /// ウィンドウ位置（物理ピクセル）。{x, y, w, h}
  Map<String, int>? bounds;

  /// 4 分割のうち上段（Teams・Slack）の高さの割合。
  double topRowRatio;

  /// 予定（Google カレンダー）のウィンドウを表示する。
  bool calendarEnabled;

  /// 何日分の予定を表示するか（今日から）。
  int calendarDays;

  /// 予定をクリックしたときに開くもの。"notion" = Notion カレンダーのアプリ、
  /// "google" = ブラウザの Google カレンダー。
  String calendarOpenTarget;

  FrameSettings frame(SourceKind k) => frames.firstWhere((f) => f.kind == k);

  Map<String, dynamic> toJson() => {
        'schema': _schema,
        'frames': {for (final f in frames) f.kind.name: f.toJson()},
        'pinnedToDesktop': pinnedToDesktop,
        'autostart': autostart,
        'opacity': opacity,
        'apiPollSeconds': apiPollSeconds,
        'notificationPollSeconds': notificationPollSeconds,
        'graphClientId': graphClientId,
        'graphTenant': graphTenant,
        'googleClientId': googleClientId,
        'googleClientSecret': googleClientSecret,
        'outlookOpenInDesktop': outlookOpenInDesktop,
        'outlookReadDetails': outlookReadDetails,
        'bounds': bounds,
        'topRowRatio': topRowRatio,
        'calendarEnabled': calendarEnabled,
        'calendarDays': calendarDays,
        'calendarOpenTarget': calendarOpenTarget,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) {
    final fj = j['frames'];
    final frames = SourceKind.values.map((k) {
      final m = fj is Map ? fj[k.name] : null;
      return m is Map
          ? FrameSettings.fromJson(k, Map<String, dynamic>.from(m),
              schema: (j['schema'] as num?)?.toInt() ?? 1)
          : FrameSettings(kind: k);
    }).toList();
    Map<String, int>? bounds;
    final b = j['bounds'];
    if (b is Map &&
        ['x', 'y', 'w', 'h'].every((k) => b[k] is num)) {
      bounds = {for (final k in ['x', 'y', 'w', 'h']) k: (b[k] as num).toInt()};
    }
    return AppSettings(
      frames: frames,
      pinnedToDesktop: j['pinnedToDesktop'] as bool? ?? true,
      autostart: j['autostart'] as bool? ?? true,
      opacity: ((j['opacity'] as num?)?.toDouble() ?? 0.95).clamp(0.2, 1.0),
      apiPollSeconds:
          ((j['apiPollSeconds'] as num?)?.toInt() ?? 60).clamp(15, 3600),
      notificationPollSeconds:
          ((j['notificationPollSeconds'] as num?)?.toInt() ?? 10).clamp(3, 600),
      graphClientId: (j['graphClientId'] as String?) ?? '',
      graphTenant: (j['graphTenant'] as String?) ?? 'organizations',
      googleClientId: (j['googleClientId'] as String?) ?? '',
      googleClientSecret: (j['googleClientSecret'] as String?) ?? '',
      outlookOpenInDesktop: j['outlookOpenInDesktop'] as bool? ?? true,
      outlookReadDetails: j['outlookReadDetails'] as bool? ?? false,
      topRowRatio:
          ((j['topRowRatio'] as num?)?.toDouble() ?? 0.38).clamp(0.2, 0.8),
      calendarEnabled: j['calendarEnabled'] as bool? ?? true,
      calendarDays: ((j['calendarDays'] as num?)?.toInt() ?? 2).clamp(1, 21),
      calendarOpenTarget: (j['calendarOpenTarget'] as String?) ?? 'notion',
      bounds: bounds,
    );
  }

  AppSettings copy() => AppSettings.fromJson(toJson());
}
