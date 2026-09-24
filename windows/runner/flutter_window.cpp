#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Reads a number from an EncodableMap (Dart ints arrive as int32 or int64).
std::optional<double> GetNumber(const flutter::EncodableMap& map,
                                const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return std::nullopt;
  const auto& v = it->second;
  if (auto p = std::get_if<int32_t>(&v)) return static_cast<double>(*p);
  if (auto p = std::get_if<int64_t>(&v)) return static_cast<double>(*p);
  if (auto p = std::get_if<double>(&v)) return *p;
  return std::nullopt;
}

std::optional<bool> GetBool(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return std::nullopt;
  if (auto p = std::get_if<bool>(&it->second)) return *p;
  return std::nullopt;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  ApplyWidgetStyle();
  ApplyCorners();

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "message_manager/window",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  Win32Window::OnDestroy();
}

// Remove the title bar and make it a tool window (not shown in the taskbar).
// WS_THICKFRAME is kept because SC_SIZE resizing needs it; the frame itself
// is hidden by returning 0 from WM_NCCALCSIZE.
void FlutterWindow::ApplyWidgetStyle() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;

  LONG_PTR style = ::GetWindowLongPtr(hwnd, GWL_STYLE);
  style &= ~(WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX);
  style |= WS_THICKFRAME | WS_POPUP;
  ::SetWindowLongPtr(hwnd, GWL_STYLE, style);

  LONG_PTR ex = ::GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  ex &= ~WS_EX_APPWINDOW;
  ex |= WS_EX_TOOLWINDOW;
  ::SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex);

  ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                     SWP_FRAMECHANGED);
}

// Rounded corners. Windows 11: ask DWM for smooth rounded corners.
// Layered (semi-transparent) windows are not rounded by DWM, so they
// (and Windows 10) get a rounded window region instead.
void FlutterWindow::ApplyCorners() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  DWORD pref = 2;  // DWMWCP_ROUND
  HRESULT hr = ::DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */,
                                       &pref, sizeof(pref));
  if (layered_ || FAILED(hr)) {
    RECT r;
    ::GetWindowRect(hwnd, &r);
    UINT dpi = ::GetDpiForWindow(hwnd);
    int d = ::MulDiv(16, dpi == 0 ? 96 : static_cast<int>(dpi), 96);
    HRGN rgn = ::CreateRoundRectRgn(0, 0, r.right - r.left + 1,
                                    r.bottom - r.top + 1, d, d);
    ::SetWindowRgn(hwnd, rgn, TRUE);  // the system owns rgn afterwards
  } else {
    ::SetWindowRgn(hwnd, nullptr, TRUE);
  }
}

void FlutterWindow::SendBoundsToDart() {
  if (!channel_) return;
  RECT r;
  if (!::GetWindowRect(GetHandle(), &r)) return;
  flutter::EncodableMap map{
      {flutter::EncodableValue("x"), flutter::EncodableValue(static_cast<int>(r.left))},
      {flutter::EncodableValue("y"), flutter::EncodableValue(static_cast<int>(r.top))},
      {flutter::EncodableValue("w"),
       flutter::EncodableValue(static_cast<int>(r.right - r.left))},
      {flutter::EncodableValue("h"),
       flutter::EncodableValue(static_cast<int>(r.bottom - r.top))},
  };
  channel_->InvokeMethod("boundsChanged",
                         std::make_unique<flutter::EncodableValue>(map));
}

void FlutterWindow::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  HWND hwnd = GetHandle();
  const std::string& method = call.method_name();
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

  if (method == "setPinned") {
    bool pinned = args ? GetBool(*args, "pinned").value_or(false) : false;
    pinned_to_desktop_ = pinned;
    if (pinned) {
      ::SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    } else {
      ::SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
      ::SetForegroundWindow(hwnd);
    }
    result->Success();
  } else if (method == "setBounds") {
    if (!args) {
      result->Error("bad_args", "map required");
      return;
    }
    auto x = GetNumber(*args, "x");
    auto y = GetNumber(*args, "y");
    auto w = GetNumber(*args, "w");
    auto h = GetNumber(*args, "h");
    if (!x || !y || !w || !h || *w < 200 || *h < 150) {
      result->Error("bad_args", "x, y, w, h required");
      return;
    }
    RECT target{static_cast<LONG>(*x), static_cast<LONG>(*y),
                static_cast<LONG>(*x + *w), static_cast<LONG>(*y + *h)};
    // Ignore saved bounds that are not on any monitor (e.g. after the
    // monitor layout changed), so the window never ends up off-screen.
    if (::MonitorFromRect(&target, MONITOR_DEFAULTTONULL) == nullptr) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    ::SetWindowPos(hwnd, nullptr, target.left, target.top,
                   target.right - target.left, target.bottom - target.top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
    result->Success(flutter::EncodableValue(true));
  } else if (method == "getBounds") {
    RECT r;
    ::GetWindowRect(hwnd, &r);
    flutter::EncodableMap map{
        {flutter::EncodableValue("x"), flutter::EncodableValue(static_cast<int>(r.left))},
        {flutter::EncodableValue("y"), flutter::EncodableValue(static_cast<int>(r.top))},
        {flutter::EncodableValue("w"),
         flutter::EncodableValue(static_cast<int>(r.right - r.left))},
        {flutter::EncodableValue("h"),
         flutter::EncodableValue(static_cast<int>(r.bottom - r.top))},
    };
    result->Success(flutter::EncodableValue(map));
  } else if (method == "setOpacity") {
    double v = args ? GetNumber(*args, "value").value_or(1.0) : 1.0;
    if (v < 0.2) v = 0.2;
    if (v > 1.0) v = 1.0;
    LONG_PTR ex = ::GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    if (v >= 0.999) {
      // Fully opaque: drop WS_EX_LAYERED so DWM can draw smooth rounded corners.
      layered_ = false;
      ::SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex & ~WS_EX_LAYERED);
    } else {
      layered_ = true;
      ::SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED);
      ::SetLayeredWindowAttributes(hwnd, 0, static_cast<BYTE>(v * 255.0),
                                   LWA_ALPHA);
    }
    ApplyCorners();
    result->Success();
  } else if (method == "startDrag") {
    // Reply first: SendMessage does not return until the drag ends.
    result->Success();
    ::ReleaseCapture();
    ::SendMessage(hwnd, WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0);
  } else if (method == "startResize") {
    // edge: WMSZ_LEFT(1) ... WMSZ_BOTTOMRIGHT(8)
    int edge = args ? static_cast<int>(GetNumber(*args, "edge").value_or(8)) : 8;
    if (edge < 1 || edge > 8) edge = 8;
    result->Success();
    ::ReleaseCapture();
    ::SendMessage(hwnd, WM_SYSCOMMAND, SC_SIZE | edge, 0);
  } else if (method == "getWorkArea") {
    // Work area (screen minus taskbar) of the monitor this window is on.
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    HMONITOR mon = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY);
    ::GetMonitorInfoW(mon, &mi);
    const RECT& r = mi.rcWork;
    flutter::EncodableMap map{
        {flutter::EncodableValue("x"), flutter::EncodableValue(static_cast<int>(r.left))},
        {flutter::EncodableValue("y"), flutter::EncodableValue(static_cast<int>(r.top))},
        {flutter::EncodableValue("w"), flutter::EncodableValue(static_cast<int>(r.right - r.left))},
        {flutter::EncodableValue("h"), flutter::EncodableValue(static_cast<int>(r.bottom - r.top))},
    };
    result->Success(flutter::EncodableValue(map));
  } else if (method == "setBoundsOf" || method == "closeByTitle") {
    // Acts on another Message Manager window (e.g. the calendar window).
    std::string title;
    if (args) {
      auto it = args->find(flutter::EncodableValue("title"));
      if (it != args->end()) {
        if (auto p = std::get_if<std::string>(&it->second)) title = *p;
      }
    }
    std::wstring wtitle;
    if (!title.empty()) {
      int n = ::MultiByteToWideChar(CP_UTF8, 0, title.c_str(), -1, nullptr, 0);
      if (n > 0) {
        wtitle.resize(static_cast<size_t>(n));
        ::MultiByteToWideChar(CP_UTF8, 0, title.c_str(), -1, &wtitle[0], n);
        wtitle.resize(static_cast<size_t>(n - 1));
      }
    }
    HWND other = wtitle.empty()
                     ? nullptr
                     : ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", wtitle.c_str());
    if (!other || other == hwnd) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    if (method == "closeByTitle") {
      ::PostMessage(other, WM_CLOSE, 0, 0);
    } else {
      auto x = GetNumber(*args, "x");
      auto y = GetNumber(*args, "y");
      auto w = GetNumber(*args, "w");
      auto h = GetNumber(*args, "h");
      if (x && y && w && h) {
        ::SetWindowPos(other, nullptr, static_cast<int>(*x), static_cast<int>(*y),
                       static_cast<int>(*w), static_cast<int>(*h),
                       SWP_NOZORDER | SWP_NOACTIVATE);
      }
    }
    result->Success(flutter::EncodableValue(true));
  } else if (method == "close") {
    result->Success();
    ::PostMessage(hwnd, WM_CLOSE, 0, 0);
  } else {
    result->NotImplemented();
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  switch (message) {
    case WM_NCCALCSIZE:
      // Remove the non-client area (title bar and frame).
      if (wparam == TRUE) return 0;
      break;
    case WM_WINDOWPOSCHANGING:
      if (pinned_to_desktop_) {
        // Whatever tries to change the Z order, stay at the bottom.
        auto* pos = reinterpret_cast<WINDOWPOS*>(lparam);
        pos->hwndInsertAfter = HWND_BOTTOM;
        pos->flags &= ~static_cast<UINT>(SWP_NOZORDER);
      }
      break;
    case WM_SIZE:
      if (layered_) ApplyCorners();
      break;
    case WM_EXITSIZEMOVE:
      SendBoundsToDart();
      break;
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
