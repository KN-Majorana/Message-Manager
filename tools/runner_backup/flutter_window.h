#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// Window for Message Manager.
// - No title bar (move / resize are requested from Dart)
// - Hidden from taskbar and Alt+Tab (tool window)
// - "Pinned to desktop" mode keeps the window at the bottom of the Z order
// - Adjustable opacity
// Exposed to Dart via MethodChannel "message_manager/window".
class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void ApplyWidgetStyle();
  void ApplyCorners();
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void SendBoundsToDart();

  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  // When true, always stay below other windows (just above the wallpaper).
  bool pinned_to_desktop_ = false;

  // True while the window is semi-transparent (WS_EX_LAYERED).
  bool layered_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
