import 'dart:async';

import 'gmail.dart';

/// Google カレンダーの予定 1 件。
class CalendarEvent {
  CalendarEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
    required this.location,
    required this.color,
    required this.calendarName,
    required this.link,
  });

  final String id;
  final String title;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String location;

  /// カレンダーの色（#RRGGBB）。
  final String color;
  final String calendarName;

  /// ブラウザの Google カレンダーでこの予定を開く URL。
  final String link;

  bool isOngoing(DateTime now) =>
      !allDay && !now.isBefore(start) && now.isBefore(end);
}

/// Google カレンダーの予定を読む。Notion カレンダーに表示されている
/// Google カレンダーの予定と同じもの（表示中のカレンダーすべて）を取得する。
class CalendarService {
  CalendarService(this._google);

  final GmailService _google;
  static const _api = 'https://www.googleapis.com/calendar/v3';

  List<({String id, String name, String color})>? _calendars;
  DateTime? _calendarsAt;

  Future<List<CalendarEvent>> fetch({int days = 2}) async {
    // Message Manager 側で（再）サインインした直後でも拾えるよう、
    // 権限が足りないときはトークンを読み直す
    if (!_google.signedIn || !_google.hasCalendarScope) {
      await _google.load();
    }
    if (!_google.signedIn) {
      throw StateError('Google にサインインしていません（Message Manager の設定 → アカウント連携）');
    }
    if (!_google.hasCalendarScope) {
      throw StateError(
          'カレンダーの権限がありません。Message Manager の設定 → アカウント連携 で Google に「再サインイン」してください');
    }

    final cals = await _loadCalendars();
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day);
    final to = from.add(Duration(days: days.clamp(1, 21)));

    final lists = await Future.wait(cals.map((c) async {
      final j = await _google.getJson(
          '$_api/calendars/${Uri.encodeComponent(c.id)}/events', {
        'timeMin': from.toUtc().toIso8601String(),
        'timeMax': to.toUtc().toIso8601String(),
        'singleEvents': 'true',
        'orderBy': 'startTime',
        'maxResults': '250',
      });
      final out = <CalendarEvent>[];
      for (final e in (j['items'] as List? ?? const [])) {
        if (e is! Map) continue;
        if (e['status'] == 'cancelled') continue;
        // 自分が「辞退」した予定は出さない
        final attendees = e['attendees'];
        if (attendees is List &&
            attendees.any((a) =>
                a is Map &&
                a['self'] == true &&
                a['responseStatus'] == 'declined')) {
          continue;
        }
        final start = e['start'] as Map? ?? const {};
        final end = e['end'] as Map? ?? const {};
        final allDay = start['date'] != null;
        final s = DateTime.tryParse(
                (start['dateTime'] ?? start['date'] ?? '').toString())
            ?.toLocal();
        final en = DateTime.tryParse(
                (end['dateTime'] ?? end['date'] ?? '').toString())
            ?.toLocal();
        if (s == null) continue;
        out.add(CalendarEvent(
          id: '${c.id}/${e['id']}',
          title: (e['summary'] ?? '(タイトルなし)').toString(),
          start: s,
          end: en ?? s.add(const Duration(hours: 1)),
          allDay: allDay,
          location: (e['location'] ?? '').toString(),
          color: c.color,
          calendarName: c.name,
          link: (e['htmlLink'] ?? '').toString(),
        ));
      }
      return out;
    }));

    final all = lists.expand((l) => l).toList()
      ..sort((a, b) {
        if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
        return a.start.compareTo(b.start);
      });
    return all;
  }

  /// Google カレンダーで「表示」にしているカレンダーの一覧（1 時間キャッシュ）。
  Future<List<({String id, String name, String color})>> _loadCalendars() async {
    final at = _calendarsAt;
    final cached = _calendars;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(hours: 1)) {
      return cached;
    }
    final j = await _google.getJson('$_api/users/me/calendarList',
        {'minAccessRole': 'reader', 'maxResults': '250'});
    final list = <({String id, String name, String color})>[];
    for (final c in (j['items'] as List? ?? const [])) {
      if (c is! Map) continue;
      if (c['selected'] != true && c['primary'] != true) continue;
      if (c['hidden'] == true) continue;
      list.add((
        id: c['id'].toString(),
        name: (c['summaryOverride'] ?? c['summary'] ?? '').toString(),
        color: (c['backgroundColor'] ?? '#0f6cbd').toString(),
      ));
    }
    _calendars = list;
    _calendarsAt = DateTime.now();
    return list;
  }
}
