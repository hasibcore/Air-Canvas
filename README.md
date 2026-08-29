# 🎨 Air Canvas - High-Performance Wireless Graphics Tablet

**Air Canvas** transforms your Android phone/tablet or iOS device into a high-precision, low-latency wireless graphics tablet for Windows, macOS, and Linux over your local WiFi network.

---

### 🌐 Live Links & Downloads

- 🔗 **Live Website:** **[https://hasibcore.github.io/Air-Canvas/](https://hasibcore.github.io/Air-Canvas/)**
- 🎨 **Web Studio & Simulator:** **[https://hasibcore.github.io/Air-Canvas/simulator.html](https://hasibcore.github.io/Air-Canvas/simulator.html)**
- 📦 **Download Releases (APK / Binaries):** **[https://github.com/hasibcore/Air-Canvas/releases](https://github.com/hasibcore/Air-Canvas/releases)**
- 📥 **Direct Full Source Code (.ZIP):** **[Air-Canvas-v1.1.0.zip](https://github.com/hasibcore/Air-Canvas/archive/refs/tags/v1.1.0.zip)**

---

## 📱 Platform Roles & Architecture

Air Canvas operates seamless cross-platform client-server communication:

```
+------------------------------------+          WiFi Network         +---------------------------------------+
|    📱 Mobile (Android / iOS)       |  ===========================> |      💻 Desktop (PC / Mac / Linux)     |
|   Role: High-Precision Tablet      |   WebSocket Binary Stream     |   Role: Input Receiver Host           |
| • Captures Pressure, Tilt, Angles  |  (13-byte packet, encrypted)  | • Synthetic Native Input Injection    |
| • EMA Pressure & Position Smoothing|                               | • Clamped Pressure & Coordinate Sync  |
+------------------------------------+                               +---------------------------------------+
```

| Platform | Role | Mode | Key Features |
|---|---|---|---|
| **🤖 Android** | Mobile Client / Tablet | **CLIENT Mode** | High-rate touch/stylus sampling, pressure sensitivity, tilt tracking, dynamic grid overlay. |
| **🍏 iOS** | Mobile Client / Tablet | **CLIENT Mode** | Apple Pencil integration, force touch pressure, high-FPS canvas renderer. |
| **💻 Windows** | Desktop Receiver | **SERVER Mode** | Windows `CreateSyntheticPointerDevice` native pen input injection with fallback `SendInput`. Fully supported. |
| **🍎 macOS** | Desktop Receiver | **SERVER Mode** | ⚠️ Networking, pairing and the debug canvas work; native pen injection (`CGEvent` / `IOHIDVirtualDevice`) is **not implemented yet** — strokes are received but not injected into other apps. |
| **🐧 Linux** | Desktop Receiver | **SERVER Mode** | ⚠️ Networking, pairing and the debug canvas work; native pen injection (`/dev/uinput`) is **not implemented yet** — strokes are received but not injected into other apps. |

---

## 🚀 How to Build & Run for Each Platform

### 1. Build for Android (`.apk`)
```bash
# Generate release APK
flutter build apk --release

# Output path: build/app/outputs/flutter-apk/app-release.apk
```

### 2. Build for Windows (`.exe`)
```bash
# Generate Windows 64-bit release binary
flutter build windows --release

# Output path: build/windows/x64/runner/Release/
```

### 3. Build for iOS / macOS (`.ipa` / `.app`)
```bash
# Build for iOS
flutter build ipa --release

# Build for macOS
flutter build macos --release
```

---

## 🛠 Features & Capabilities

- **Zero-Configuration Auto-Discovery**: UDP broadcast pairing on port 9091 across the local WiFi.
- **Compact Binary Protocol**: 13-byte packed input packets — event type, big-endian `uint16` normalized X/Y, single-byte normalized pressure, pointer type, pointer id, tilt X/Y, button mask, protocol version, and an additive checksum byte.
- **Encrypted by Default**: every post-pairing packet travels through Secure Channel v2 (see below). There is no unencrypted transport mode.
- **Palm Rejection**: while the pen is drawing, a resting palm or a second finger is ignored, and fingers stay ignored for 400 ms after the pen lifts. If a pen lands mid-finger-stroke the pen takes over and the finger's stroke is closed cleanly, so the desktop cursor never gets left with a button held down. Toggleable from the toolbar.
- **Native Pen Injection**: on Windows, translates tablet input into real OS pen events (recognized by Photoshop, Illustrator, Krita, Blender, etc.).
- **Hardware Acceleration**: GPU-accelerated drawing canvas with `RepaintBoundary` optimizations and a dedicated repaint notifier so the toolbar does not rebuild while you draw.

---

## 🔐 Security Model

- **Pairing PIN**: a fresh random 6-digit PIN is generated every time the server starts and shown in the server window. Nothing is hardcoded.
- **Brute-force throttle**: 5 consecutive wrong PINs trigger a 30-second lockout during which even the correct PIN is refused; every failed attempt also drops the connection.
- **Secure Channel v2**: `frame = IV(16) || AES-256-CBC(SEQ(4) || payload) || HMAC-SHA256(IV || CT)[0..16]`, Encrypt-then-MAC, minimum 48 bytes. Each direction derives its own encryption and MAC keys, so a captured server frame cannot be reflected back. The 4-byte sequence number must strictly increase, so replays are rejected.
- **Session key exchange**: the server generates a fresh 32-byte session key per successful authentication and delivers it sealed under `PBKDF2-HMAC-SHA1(pin, random 16-byte salt)`. The client refuses any `auth_success` that lacks the v2 fields, so a downgrade to plaintext key delivery is not possible.
- **Firewall scope**: `Fix_Firewall.bat` opens ports 9090/9091 on private/domain profiles only, restricted to `remoteip=LocalSubnet`.

CBC + HMAC is used rather than AES-GCM because the standalone C# server is compiled with the .NET Framework 4.0 `csc.exe`, which has no `AesGcm` class. Encrypt-then-MAC with a separate HMAC key is equivalent in security for this use.

### Not implemented yet

To be clear about what this project does **not** currently do: two-finger pan / pinch-to-zoom, pressure-curve calibration, stylus hover events, barrel-button mapping, and native pen injection on macOS and Linux.

---

## 📜 License & Author

**Air Canvas** is developed by Hasib Core. All rights reserved.
