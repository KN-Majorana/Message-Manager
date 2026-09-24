#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // "--calendar" starts the separate calendar window (same exe).
  const bool calendar_mode =
      command_line != nullptr && ::wcsstr(command_line, L"--calendar") != nullptr;
  const wchar_t* window_title =
      calendar_mode ? L"Message Manager Calendar" : L"Message Manager";

  // Single instance per mode: autostart + manual launch still gives one window.
  HANDLE instance_mutex = ::CreateMutexW(
      nullptr, TRUE,
      calendar_mode ? L"MessageManager.Calendar.SingleInstance"
                    : L"MessageManager.SingleInstance");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing =
        ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", window_title);
    if (existing) {
      ::ShowWindow(existing, SW_SHOWNOACTIVATE);
    }
    if (instance_mutex) ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Initial bounds. Dart restores the saved bounds right after startup.
  Win32Window::Point origin(40, 40);
  Win32Window::Size size(calendar_mode ? 574u : 864u, calendar_mode ? 300u : 704u);
  if (!window.Create(window_title, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex) {
    ::ReleaseMutex(instance_mutex);
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
