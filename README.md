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
| • Captures Pressure, Tilt, Angles  |   (Custom 32-byte protocol)   | • Synthetic Native Input Injection    |
| • Palm Rejection & EMA Smoothing   |                               | • Clamped Pressure & Coordinate Sync  |
+------------------------------------+                               +---------------------------------------+
```

| Platform | Role | Mode | Key Features |
|---|---|---|---|
| **🤖 Android** | Mobile Client / Tablet | **CLIENT Mode** | High-rate touch/stylus sampling, pressure sensitivity, tilt tracking, dynamic grid overlay. |
| **🍏 iOS** | Mobile Client / Tablet | **CLIENT Mode** | Apple Pencil integration, force touch pressure, high-FPS canvas renderer. |
| **💻 Windows** | Desktop Receiver | **SERVER Mode** | Windows `CreateSyntheticPointerDevice` native pen input injection with fallback `SendInput`. |
| **🍎 macOS** | Desktop Receiver | **SERVER Mode** | Native macOS server bridge, high-speed WebSocket listener with UDP Auto-Discovery. |
| **🐧 Linux** | Desktop Receiver | **SERVER Mode** | GTK Linux server receiver, auto UDP pairing pin authentication. |

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

- **Zero-Configuration Auto-Discovery**: Automatic UDP broadcast pairing across local WiFi.
- **Ultra-Low Latency Binary Protocol**: Custom packed binary packets containing 64-bit float coordinates, normalized pressure, tilt vectors, and checksum validation.
- **Native Pen Injection**: Translates tablet input into native Windows OS Pen events (recognized by Photoshop, Illustrator, Krita, Blender, etc.).
- **Hardware Acceleration**: GPU-accelerated drawing canvas with `RepaintBoundary` optimizations.

---

## 📜 License & Author

**Air Canvas** is developed by Hasib Core. All rights reserved.
