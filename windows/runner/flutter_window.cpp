#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/encodable_value.h>

static double GetDouble(const flutter::EncodableMap& map, const std::string& key, double default_val) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it != map.end()) {
    if (auto* d = std::get_if<double>(&it->second)) {
      return *d;
    } else if (auto* i = std::get_if<int32_t>(&it->second)) {
      return static_cast<double>(*i);
    } else if (auto* l = std::get_if<int64_t>(&it->second)) {
      return static_cast<double>(*l);
    }
  }
  return default_val;
}

static int GetInt(const flutter::EncodableMap& map, const std::string& key, int default_val) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it != map.end()) {
    if (auto* i = std::get_if<int32_t>(&it->second)) {
      return *i;
    } else if (auto* l = std::get_if<int64_t>(&it->second)) {
      return static_cast<int>(*l);
    } else if (auto* d = std::get_if<double>(&it->second)) {
      return static_cast<int>(*d);
    }
  }
  return default_val;
}

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

  // Register our custom input injection channel
  auto input_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "com.superdisplay/input",
      &flutter::StandardMethodCodec::GetInstance());

  input_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "initializePointerDevice") {
          // Initialize pointer injection or just return true
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "injectPointerEvent") {
          const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!arguments) {
            result->Error("InvalidArguments", "Arguments must be a map");
            return;
          }

          int type = GetInt(*arguments, "type", 0);
          double x = GetDouble(*arguments, "x", 0.0);
          double y = GetDouble(*arguments, "y", 0.0);
          double pressure = GetDouble(*arguments, "pressure", 0.5);
          int buttons = GetInt(*arguments, "buttons", 0);

          // Map to screen coordinates
          int screen_width = GetSystemMetrics(SM_CXSCREEN);
          int screen_height = GetSystemMetrics(SM_CYSCREEN);
          int target_x = static_cast<int>(x * screen_width);
          int target_y = static_cast<int>(y * screen_height);

          // Move cursor
          SetCursorPos(target_x, target_y);

          // Send click/drag input
          INPUT input = {0};
          input.type = INPUT_MOUSE;
          input.mi.dx = static_cast<LONG>(x * 65535.0);
          input.mi.dy = static_cast<LONG>(y * 65535.0);
          input.mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE;

          if (type == 0) { // pointerDown
            input.mi.dwFlags |= MOUSEEVENTF_LEFTDOWN;
          } else if (type == 2) { // pointerUp
            input.mi.dwFlags |= MOUSEEVENTF_LEFTUP;
          }

          SendInput(1, &input, sizeof(INPUT));

          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "setScreenResolution") {
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "disposePointerDevice") {
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });

  // Keep a reference to the channel (in a real plugin, this would be a member, but here keeping it alive or registering it with messenger is enough)
  static auto static_channel = std::move(input_channel);

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

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
