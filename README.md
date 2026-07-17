# 🎨 Air Canvas - High-Performance Wireless Graphics Tablet

**Air Canvas** transforms your Android phone/tablet or iOS device into a high-precision, low-latency wireless graphics tablet for Windows, macOS, and Linux over your local WiFi network.


---

## 📥 Downloads Center (All Platforms & Architectures)

> **Live GitHub Pages Download Landing Page**: [https://hasibcore.github.io/Air-Canvas/](https://hasibcore.github.io/Air-Canvas/)

### 💻 Windows PC (Desktop Server App)
| Architecture | Direct `.EXE` Installer | Portable `.ZIP` Package | Target System |
| :--- | :--- | :--- | :--- |
| **Windows x64 (64-bit)** | [💾 Download .EXE](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-win-x64.exe) | [📦 Download .ZIP](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-win-x64.zip) | Standard 64-bit Windows 10 & 11 PCs |
| **Windows x86 (32-bit)** | [💾 Download .EXE](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-win-x86.exe) | [📦 Download .ZIP](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-win-x86.zip) | Legacy 32-bit Windows PCs |
| **Windows ARM64 (ARM)** | [💾 Download .EXE](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-win-arm64.exe) | [📦 Download .ZIP](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-win-arm64.zip) | Surface Pro ARM & Snapdragon Laptops |

---

### 🍎 macOS / MacBook (Desktop Server App)
| System | `.DMG` Installer | `.ZIP` Archive | Compatibility |
| :--- | :--- | :--- | :--- |
| **macOS Universal** | [🍏 Download .DMG](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-mac-universal.dmg) | [📦 Download .ZIP](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-mac-universal.zip) | Intel & Apple Silicon (M1/M2/M3/M4) |

---

### 📱 Mobile Apps (Smartphones)
| Platform | Direct Download | Format | Description |
| :--- | :--- | :--- | :--- |
| **🤖 Android Phone** | [🤖 Download Android APK](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-android-phone.apk) | `.apk` | Android 7.0+ Smartphones |
| **🍎 Apple iOS / iPhone** | [🍎 Download iOS IPA](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-ios-iphone.ipa) | `.ipa` | iOS 14.0+ iPhones |

---

### 🖊️ Tablet Client Apps (Active Stylus Tablets)
| Platform | Direct Download | Format | Stylus / Pen Support |
| :--- | :--- | :--- | :--- |
| **🤖 Android Tablet** | [📱 Download Tablet APK](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-android-tablet.apk) | `.apk` | Samsung S-Pen, Xiaomi Pen, Active Stylus |
| **🍎 Apple iPad (iPadOS)** | [🖊️ Download iPad IPA](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-ipados.ipa) | `.ipa` | Apple Pencil 1, 2, Pro & USB-C |

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

## 🚀 Direct Downloads & Build Commands for Each Platform

### 1. Android App & Tablet (`.apk`)
> 📱 **Direct Download for Android Phone & Tablet**:
- [🤖 Download Android Phone APK (`.apk`)](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-android-phone.apk)
- [📱 Download Android Tablet APK (`.apk`)](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-android-tablet.apk)

```bash
# Developer Build Command (Generate release APK)
flutter build apk --release

# Output path: build/app/outputs/flutter-apk/app-release.apk
```

---

### 2. Windows PC Receiver (`.exe` & `.zip`)
> 💻 **Direct Downloads for Windows (Both EXE & ZIP Available)**:
- **Windows x64 (64-bit)**: [💾 Download `.EXE`](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-win-x64.exe) | [📦 Download `.ZIP`](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-win-x64.zip)
- **Windows x86 (32-bit)**: [💾 Download `.EXE`](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-win-x86.exe) | [📦 Download `.ZIP`](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-win-x86.zip)
- **Windows ARM64 (ARM)**: [💾 Download `.EXE`](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-win-arm64.exe) | [📦 Download `.ZIP`](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-win-arm64.zip)

```bash
# Developer Build Command (Generate Windows release binary)
flutter build windows --release

# Output path: build/windows/x64/runner/Release/
```

---

### 3. iOS / iPadOS & macOS (`.ipa` / `.dmg` / `.zip`)
> 🍎 **Direct Downloads for Apple Devices**:
- [🍎 Download iPhone iOS Package (`.ipa`)](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-ios-iphone.ipa)
- [🖊️ Download iPad iPadOS Package (`.ipa`)](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-ipados.ipa)
- [🍏 Download macOS Universal (`.dmg`)](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-mac-universal.dmg) | [📦 macOS (`.zip`)](https://github.com/hasibcore/Air-Canvas/releases/download/v1.0.0/AirCanvas-v1.0.0-mac-universal.zip)

```bash
# Developer Build Commands
flutter build ipa --release
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
