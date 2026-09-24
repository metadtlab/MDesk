#include "flutter_window.h"

#include <desktop_drop/desktop_drop_plugin.h>
#include <desktop_multi_window/desktop_multi_window_plugin.h>
#include <texture_rgba_renderer/texture_rgba_renderer_plugin_c_api.h>
#include <flutter_gpu_texture_renderer/flutter_gpu_texture_renderer_plugin_c_api.h>

#include "flutter/generated_plugin_registrant.h"

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>

#include <optional>
#include <memory>

#include "win32_desktop.h"

namespace {
// Each Flutter engine owns a different client HWND. Convert desktop pixels at
// that HWND instead of using window frames (borders/DPI differ between monitors).
void RegisterPaneDragChannel(flutter::FlutterViewController* controller) {
  const HWND view = controller->view()->GetNativeWindow();
  flutter::MethodChannel<> channel(
      controller->engine()->messenger(), "mdesk/pane_drag",
      &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler(
      [view](const flutter::MethodCall<>& call,
             std::unique_ptr<flutter::MethodResult<>> result) {
        POINT point{};
        if (call.method_name() == "cursor") {
          if (!GetCursorPos(&point)) {
            result->Success();
            return;
          }
        } else if (call.method_name() == "hitTest") {
          const auto* args = call.arguments()
              ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
          if (!args) {
            result->Success();
            return;
          }
          const auto x = args->find(flutter::EncodableValue("x"));
          const auto y = args->find(flutter::EncodableValue("y"));
          if (x == args->end() || y == args->end() ||
              !std::holds_alternative<int32_t>(x->second) ||
              !std::holds_alternative<int32_t>(y->second)) {
            result->Success();
            return;
          }
          point.x = std::get<int32_t>(x->second);
          point.y = std::get<int32_t>(y->second);
          const HWND root = GetAncestor(view, GA_ROOT);
          RECT client{};
          if (!IsWindow(view) || !IsWindowVisible(root) || IsIconic(root) ||
              GetAncestor(WindowFromPoint(point), GA_ROOT) != root ||
              !ScreenToClient(view, &point) || !GetClientRect(view, &client) ||
              !PtInRect(&client, point)) {
            result->Success();
            return;
          }
        } else {
          result->NotImplemented();
          return;
        }
        result->Success(flutter::EncodableMap{
            {flutter::EncodableValue("x"),
             flutter::EncodableValue(static_cast<int32_t>(point.x))},
            {flutter::EncodableValue("y"),
             flutter::EncodableValue(static_cast<int32_t>(point.y))}});
      });
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  flutter::MethodChannel<> channel(
    flutter_controller_->engine()->messenger(),
    "org.rustdesk.rustdesk/host",
    &flutter::StandardMethodCodec::GetInstance());

  channel.SetMethodCallHandler(
    [](const flutter::MethodCall<>& call, std::unique_ptr<flutter::MethodResult<>> result) {
      if (call.method_name() == "bumpMouse") {
        auto arguments = call.arguments();

        int dx = 0, dy = 0;

        if (std::holds_alternative<flutter::EncodableMap>(*arguments)) {
          auto argsMap = std::get<flutter::EncodableMap>(*arguments);

          auto dxIt = argsMap.find(flutter::EncodableValue("dx"));
          auto dyIt = argsMap.find(flutter::EncodableValue("dy"));

          if ((dxIt != argsMap.end()) && std::holds_alternative<int>(dxIt->second)) {
            dx = std::get<int>(dxIt->second);
          }
          if ((dyIt != argsMap.end()) && std::holds_alternative<int>(dyIt->second)) {
            dy = std::get<int>(dyIt->second);
          }
        } else if (std::holds_alternative<flutter::EncodableList>(*arguments)) {
          auto argsList = std::get<flutter::EncodableList>(*arguments);

          if ((argsList.size() >= 1) && std::holds_alternative<int>(argsList[0])) {
            dx = std::get<int>(argsList[0]);
          }
          if ((argsList.size() >= 2) && std::holds_alternative<int>(argsList[1])) {
            dy = std::get<int>(argsList[1]);
          }
        }

        bool succeeded = Win32Desktop::BumpMouse(dx, dy);

        result->Success(succeeded);
      }
    });

  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    auto *registry = flutter_view_controller->engine();
    RegisterPaneDragChannel(flutter_view_controller);
    // Per-view HWND: pin only the report window, without taking keyboard focus
    // from the remote session. Do not use the main window_manager singleton.
    const HWND report_window = GetAncestor(
        flutter_view_controller->view()->GetNativeWindow(), GA_ROOT);
    flutter::MethodChannel<> report_channel(
        registry->messenger(), "mdesk/log_analysis_window",
        &flutter::StandardMethodCodec::GetInstance());
    report_channel.SetMethodCallHandler(
        [report_window](const flutter::MethodCall<>& call,
                        std::unique_ptr<flutter::MethodResult<>> result) {
          if (call.method_name() != "setAlwaysOnTop") {
            result->NotImplemented();
            return;
          }
          const auto* pinned = call.arguments()
              ? std::get_if<bool>(call.arguments()) : nullptr;
          if (!pinned || !IsWindow(report_window)) {
            result->Error("invalid_window", "Invalid report window or pin state");
            return;
          }
          if (!SetWindowPos(report_window, *pinned ? HWND_TOPMOST : HWND_NOTOPMOST,
                            0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)) {
            result->Error("pin_failed", "Could not update report window pin state");
            return;
          }
          result->Success();
        });
    DesktopDropPluginRegisterWithRegistrar(
        registry->GetRegistrarForPlugin("DesktopDropPlugin"));
    TextureRgbaRendererPluginCApiRegisterWithRegistrar(
        registry->GetRegistrarForPlugin("TextureRgbaRendererPlugin"));
    FlutterGpuTextureRendererPluginCApiRegisterWithRegistrar(
        registry->GetRegistrarForPlugin("FlutterGpuTextureRendererPluginCApi"));
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
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
