import 'dart:async';

import 'package:flutter/material.dart';

import 'services/calendar.dart';
import 'services/gmail.dart';
import 'services/hub.dart';
import 'services/layout.dart';
import 'services/native_window.dart';
import 'services/storage.dart';
import 'services/system.dart';
import 'ui/calendar_page.dart';
import 'ui/home_page.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await Storage.open();

  // 同じ exe を "--calendar" 付きで起動すると、予定のウィンドウになる。
  if (args.contains('--calendar')) {
    await _runCalendar(storage);
    return;
  }

  final settings = await storage.loadSettings();

  // 最初のフレームが描かれる（= ウィンドウが表示される）前に位置と見た目を整える。
  final bounds = settings.bounds;
  if (bounds != null) await NativeWindow.setBounds(bounds);
  await NativeWindow.setOpacity(settings.opacity);
  await NativeWindow.setPinned(settings.pinnedToDesktop);
  unawaited(SystemIntegration.setAutostart(settings.autostart));

  final hub = MessageHub(storage, settings);

  // ユーザーが移動・リサイズしたら位置を保存する。
  NativeWindow.onBoundsChanged((b) {
    hub.settings.bounds = b;
    storage.saveSettings(hub.settings);
  });

  runApp(MessageManagerApp(hub: hub));
  await hub.init();

  // 予定のウィンドウも一緒に開く（すでに開いていれば何も起きない）
  if (settings.calendarEnabled) {
    unawaited(SystemIntegration.launchCalendarWindow());
  }
}

const calendarWindowFile = 'calendar_window.json';

Future<void> _runCalendar(Storage storage) async {
  final settings = await storage.loadSettings();
  if (!settings.calendarEnabled) {
    await NativeWindow.close();
    return;
  }

  // 位置：保存済みならそこへ、無ければ「右上」（配置案 3）に置く
  final saved = await storage.readJson(calendarWindowFile);
  Map<String, int>? bounds;
  if (saved != null && ['x', 'y', 'w', 'h'].every((k) => saved[k] is num)) {
    bounds = {for (final k in ['x', 'y', 'w', 'h']) k: (saved[k] as num).toInt()};
  } else {
    final wa = await NativeWindow.getWorkArea();
    if (wa != null) bounds = cornerLayout(wa).calendar;
  }
  if (bounds != null) await NativeWindow.setBounds(bounds);
  await NativeWindow.setOpacity(settings.opacity);
  await NativeWindow.setPinned(settings.pinnedToDesktop);
  NativeWindow.onBoundsChanged((b) => storage.writeJson(calendarWindowFile, b));

  final google = GmailService(storage, () => settings);
  await google.load();
  runApp(MaterialApp(
    title: 'Message Manager Calendar',
    debugShowCheckedModeBanner: false,
    theme: appTheme(),
    home: CalendarPage(
      storage: storage,
      settings: settings,
      service: CalendarService(google),
    ),
  ));
}

ThemeData appTheme() => ThemeData(
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF0F6CBD),
        brightness: Brightness.light,
        surface: Colors.white,
      ),
      fontFamily: 'Yu Gothic UI',
      fontFamilyFallback: const ['Meiryo UI', 'Meiryo', 'Segoe UI'],
      scaffoldBackgroundColor: Colors.white,
      dividerColor: const Color(0xFFEFEFEF),
      visualDensity: VisualDensity.compact,
      useMaterial3: true,
    );

class MessageManagerApp extends StatelessWidget {
  const MessageManagerApp({super.key, required this.hub});

  final MessageHub hub;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Message Manager',
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      home: HomePage(hub: hub),
    );
  }
}
