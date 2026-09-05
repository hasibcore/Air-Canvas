#include "flutter_window.h"

#include <optional>
#include <cmath>
#include <algorithm>

#include "flutter/generated_plugin_registrant.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/encodable_value.h>

#include <windows.h>
#include <cstdio>

// Macro definitions for pointer injection (compatibility layer)
#ifndef PT_PEN
#define PT_PEN 3
#endif

#ifndef POINTER_FEEDBACK_DEFAULT
#define POINTER_FEEDBACK_DEFAULT 1
#endif

#ifndef POINTER_FLAG_INRANGE
#define POINTER_FLAG_INRANGE 0x00000002
#endif

#ifndef POINTER_FLAG_INCONTACT
#define POINTER_FLAG_INCONTACT 0x00000004
#endif

#ifndef POINTER_FLAG_DOWN
#define POINTER_FLAG_DOWN 0x00010000
#endif

#ifndef POINTER_FLAG_UPDATE
#define POINTER_FLAG_UPDATE 0x00020000
#endif

#ifndef POINTER_FLAG_UP
#define POINTER_FLAG_UP 0x00040000
#endif

#ifndef POINTER_FLAG_CANCELED
#define POINTER_FLAG_CANCELED 0x00080000
#endif

#ifndef POINTER_FLAG_FIRSTBUTTON
#define POINTER_FLAG_FIRSTBUTTON 0x00000010
#endif

#ifndef POINTER_FLAG_SECONDBUTTON
#define POINTER_FLAG_SECONDBUTTON 0x00000020
#endif

#ifndef PEN_FLAG_NONE
#define PEN_FLAG_NONE 0x00000000
#endif

#ifndef PEN_FLAG_BARREL
#define PEN_FLAG_BARREL 0x00000001
#endif

#ifndef PEN_FLAG_INVERTED
#define PEN_FLAG_INVERTED 0x00000002
#endif

#ifndef PEN_FLAG_ERASER
#define PEN_FLAG_ERASER 0x00000004
#endif

#ifndef PEN_MASK_PRESSURE
#define PEN_MASK_PRESSURE 0x00000001
#endif

#ifndef PEN_MASK_TILT_X
#define PEN_MASK_TILT_X 0x00000004
#endif

#ifndef PEN_MASK_TILT_Y
#define PEN_MASK_TILT_Y 0x00000008
#endif

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

// Custom resolution override parameters
static int g_customWidth = 0;
static int g_customHeight = 0;

// Pointer injection dynamic loader variables and functions
typedef HSYNTHETICPOINTERDEVICE(WINAPI* CreateSyntheticPointerDevice_t)(POINTER_INPUT_TYPE, ULONG, POINTER_FEEDBACK_MODE);
typedef BOOL(WINAPI* InjectSyntheticPointerInput_t)(HSYNTHETICPOINTERDEVICE, const POINTER_TYPE_INFO*, ULONG);
typedef void(WINAPI* DestroySyntheticPointerDevice_t)(HSYNTHETICPOINTERDEVICE);

static CreateSyntheticPointerDevice_t pCreateSyntheticPointerDevice = nullptr;
static InjectSyntheticPointerInput_t pInjectSyntheticPointerInput = nullptr;
static DestroySyntheticPointerDevice_t pDestroySyntheticPointerDevice = nullptr;

static HSYNTHETICPOINTERDEVICE g_penDevice = nullptr;
static bool g_apisAttempted = false;
static bool g_apisLoaded = false;

static bool LoadPointerInjectionAPIs() {
  if (g_apisAttempted) return g_apisLoaded;
  g_apisAttempted = true;
  
  HMODULE hUser32 = GetModuleHandleA("user32.dll");
  if (hUser32) {
    pCreateSyntheticPointerDevice = (CreateSyntheticPointerDevice_t)GetProcAddress(hUser32, "CreateSyntheticPointerDevice");
    pInjectSyntheticPointerInput = (InjectSyntheticPointerInput_t)GetProcAddress(hUser32, "InjectSyntheticPointerInput");
    pDestroySyntheticPointerDevice = (DestroySyntheticPointerDevice_t)GetProcAddress(hUser32, "DestroySyntheticPointerDevice");
  }
  g_apisLoaded = (pCreateSyntheticPointerDevice != nullptr && 
                  pInjectSyntheticPointerInput != nullptr && 
                  pDestroySyntheticPointerDevice != nullptr);
  return g_apisLoaded;
}

static bool InitializePenDevice() {
  if (!LoadPointerInjectionAPIs()) return false;
  if (g_penDevice) return true;
  
  g_penDevice = pCreateSyntheticPointerDevice(PT_PEN, 1, POINTER_FEEDBACK_DEFAULT);
  return g_penDevice != nullptr;
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
      "com.aircanvas/input",
      &flutter::StandardMethodCodec::GetInstance());

  input_channel->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        try {
          if (call.method_name() == "initializePointerDevice") {
            bool init_success = InitializePenDevice();
            result->Success(flutter::EncodableValue(init_success));
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
            int pointerType = GetInt(*arguments, "pointerType", 0);
            int pointerId = GetInt(*arguments, "pointerId", 0);
            double tiltX = GetDouble(*arguments, "tiltX", 0.0);
            double tiltY = GetDouble(*arguments, "tiltY", 0.0);
            int buttons = GetInt(*arguments, "buttons", 0);

            // Clamp inputs to safe bounds (Bug 60)
            double clamped_x = std::max(0.0, std::min(1.0, x));
            double clamped_y = std::max(0.0, std::min(1.0, y));
            double clamped_pressure = std::max(0.0, std::min(1.0, pressure));

            // Get active monitor info (DPI-aware and multi-monitor support)
            RECT monitor_rect;
            monitor_rect.left = 0;
            monitor_rect.top = 0;
            monitor_rect.right = GetSystemMetrics(SM_CXSCREEN);
            monitor_rect.bottom = GetSystemMetrics(SM_CYSCREEN);

            HWND hwnd = GetHandle();
            if (hwnd) {
              HMONITOR hMonitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY);
              MONITORINFO mi = { 0 };
              mi.cbSize = sizeof(mi);
              if (GetMonitorInfo(hMonitor, &mi)) {
                monitor_rect = mi.rcMonitor;
              }
            }

            // Map normalized coords using std::lround for sub-pixel accuracy and boundary clamping
            int target_x = 0;
            int target_y = 0;
            if (g_customWidth > 0 && g_customHeight > 0) {
              int max_w = std::max(1, g_customWidth - 1);
              int max_h = std::max(1, g_customHeight - 1);
              target_x = static_cast<int>(std::lround(clamped_x * max_w));
              target_y = static_cast<int>(std::lround(clamped_y * max_h));
            } else {
              int monitor_width = monitor_rect.right - monitor_rect.left;
              int monitor_height = monitor_rect.bottom - monitor_rect.top;
              int max_w = std::max(1, monitor_width - 1);
              int max_h = std::max(1, monitor_height - 1);
              target_x = monitor_rect.left + static_cast<int>(std::lround(clamped_x * max_w));
              target_y = monitor_rect.top + static_cast<int>(std::lround(clamped_y * max_h));
            }

            // Try pointer injection if available
            if (InitializePenDevice()) {
              POINTER_TYPE_INFO pointerInfo = {};
              pointerInfo.type = PT_PEN;

              POINTER_PEN_INFO& penInfo = pointerInfo.penInfo;
              penInfo.pointerInfo.pointerType = PT_PEN;
              // Synthethic devices with maxContacts=1 require pointerId to be exactly 0.
              // Passing Flutter's raw pointerId (>0) causes ERROR_INVALID_PARAMETER (87).
              penInfo.pointerInfo.pointerId = 0;
              penInfo.pointerInfo.ptPixelLocation.x = target_x;
              penInfo.pointerInfo.ptPixelLocation.y = target_y;

              DWORD pointerFlags = POINTER_FLAG_INRANGE;

              // type mapping: 0 = down, 1 = move, 2 = up, 3 = cancel, 4 = hover
              if (type == 0) {
                pointerFlags |= POINTER_FLAG_DOWN | POINTER_FLAG_INCONTACT | POINTER_FLAG_FIRSTBUTTON;
              } else if (type == 1) {
                pointerFlags |= POINTER_FLAG_UPDATE | POINTER_FLAG_INCONTACT;
                if (buttons & 1) {
                  pointerFlags |= POINTER_FLAG_FIRSTBUTTON;
                }
              } else if (type == 2) {
                pointerFlags |= POINTER_FLAG_UP;
              } else if (type == 3) {
                pointerFlags |= POINTER_FLAG_UP | POINTER_FLAG_CANCELED;
              } else if (type == 4) {
                pointerFlags |= POINTER_FLAG_UPDATE;
              }

              if (buttons & 2) {
                pointerFlags |= POINTER_FLAG_SECONDBUTTON;
                penInfo.penFlags |= PEN_FLAG_BARREL;
              }

              if (pointerType == 3) { // Eraser
                penInfo.penFlags |= PEN_FLAG_ERASER | PEN_FLAG_INVERTED;
              }

              penInfo.pointerInfo.pointerFlags = pointerFlags;

              // Set Pressure (Pro 1024-level high-precision rounding)
              penInfo.pressure = static_cast<UINT32>(std::lround(clamped_pressure * 1024.0));
              penInfo.penMask |= PEN_MASK_PRESSURE;

              // Set Tilt
              penInfo.tiltX = static_cast<INT32>(tiltX);
              penInfo.tiltY = static_cast<INT32>(tiltY);
              penInfo.penMask |= PEN_MASK_TILT_X | PEN_MASK_TILT_Y;

              BOOL success = pInjectSyntheticPointerInput(g_penDevice, &pointerInfo, 1);
              if (success) {
                result->Success(flutter::EncodableValue(true));
                return;
              } else {
                char dbg[256];
                sprintf_s(dbg, "InjectSyntheticPointerInput failed. Error: %lu\n", GetLastError());
                OutputDebugStringA(dbg);
              }
            }

            // Fallback to SendInput mouse emulation (Bug 65, 66, 67)
            INPUT input = {};
            input.type = INPUT_MOUSE;

            int virtual_left = GetSystemMetrics(SM_XVIRTUALSCREEN);
            int virtual_top = GetSystemMetrics(SM_YVIRTUALSCREEN);
            int virtual_width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
            int virtual_height = GetSystemMetrics(SM_CYVIRTUALSCREEN);

            double normalized_x = 0.0;
            double normalized_y = 0.0;
            if (virtual_width > 1 && virtual_height > 1) {
              normalized_x = static_cast<double>(target_x - virtual_left) / (virtual_width - 1);
              normalized_y = static_cast<double>(target_y - virtual_top) / (virtual_height - 1);
            }

            input.mi.dx = static_cast<LONG>(std::lround(normalized_x * 65535.0));
            input.mi.dy = static_cast<LONG>(std::lround(normalized_y * 65535.0));
            input.mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESKTOP;

            if (type == 0) {
              if (buttons & 1) input.mi.dwFlags |= MOUSEEVENTF_LEFTDOWN;
              if (buttons & 2) input.mi.dwFlags |= MOUSEEVENTF_RIGHTDOWN;
              if (buttons & 4) input.mi.dwFlags |= MOUSEEVENTF_MIDDLEDOWN;
              if (input.mi.dwFlags == (MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESKTOP)) {
                input.mi.dwFlags |= MOUSEEVENTF_LEFTDOWN;
              }
            } else if (type == 2 || type == 3) {
              // Release all buttons for up/cancel
              input.mi.dwFlags |= MOUSEEVENTF_LEFTUP | MOUSEEVENTF_RIGHTUP | MOUSEEVENTF_MIDDLEUP;
            } else {
              input.mi.dwFlags |= MOUSEEVENTF_MOVE;
            }

            UINT sent = SendInput(1, &input, sizeof(INPUT));
            if (sent == 0) {
              char dbg[256];
              sprintf_s(dbg, "SendInput failed. Error: %lu\n", GetLastError());
              OutputDebugStringA(dbg);
            }
            result->Success(flutter::EncodableValue(sent > 0));
          } else if (call.method_name() == "setScreenResolution") {
            const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
            if (arguments) {
              g_customWidth = GetInt(*arguments, "width", 0);
              g_customHeight = GetInt(*arguments, "height", 0);
            }
            result->Success(flutter::EncodableValue(true));
          } else if (call.method_name() == "disposePointerDevice") {
            if (g_penDevice && pDestroySyntheticPointerDevice) {
              pDestroySyntheticPointerDevice(g_penDevice);
              g_penDevice = nullptr;
            }
            // Release mouse buttons fallback on dispose to prevent stuck state
            INPUT release_input = {};
            release_input.type = INPUT_MOUSE;
            release_input.mi.dwFlags = MOUSEEVENTF_LEFTUP | MOUSEEVENTF_RIGHTUP | MOUSEEVENTF_MIDDLEUP;
            SendInput(1, &release_input, sizeof(INPUT));

            result->Success(flutter::EncodableValue(true));
          } else {
            result->NotImplemented();
          }
        } catch (const std::exception& e) {
          result->Error("NativeException", e.what());
        } catch (...) {
          result->Error("NativeException", "Unknown native error occurred");
        }
      });

  // Keep a reference to the channel
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
  if (g_penDevice && pDestroySyntheticPointerDevice) {
    pDestroySyntheticPointerDevice(g_penDevice);
    g_penDevice = nullptr;
  }
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
