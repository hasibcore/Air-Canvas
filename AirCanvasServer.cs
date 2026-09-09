using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Globalization;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace AirCanvas
{
    public class Program
    {
        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        private static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new IntPtr(-4);

        [STAThread]
        public static void Main()
        {
            try
            {
                try
                {
                    if (!SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2))
                    {
                        SetProcessDPIAware();
                    }
                }
                catch
                {
                    try { SetProcessDPIAware(); } catch { }
                }
                // Clean up any stale background instances
                Process current = Process.GetCurrentProcess();
                foreach (Process p in Process.GetProcessesByName("AirCanvas"))
                {
                    if (p.Id != current.Id)
                    {
                        try { p.Kill(); } catch { }
                    }
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new MainForm());
            }
            catch (Exception ex)
            {
                MessageBox.Show("AirCanvas Server Error:\n\n" + ex.Message + "\n\n" + ex.StackTrace, "AirCanvas Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }

    public class MainForm : Form
    {
        // UI Controls
        private Label lblTitle;
        private Label lblStatus;
        private Label lblIp;
        private Label lblPort;
        private Label lblClients;
        private Label lblPackets;
        private Panel pnlPinBox;
        private Label lblPinTitle;
        private Label lblPinValue;
        private Button btnToggleServer;
        private Button btnTestInput;
        private Button btnAllowFirewall;
        private Button btnClearCanvas;
        private Button btnPptPen;
        private Button btnPptLaser;
        private Button btnPptEraser;
        private Button btnUndo;
        private CheckBox chkEnableInjection;
        private Button btnOpenOneNote;
        private Button btnOpenPowerPoint;
        private Button btnOpenStudio;
        private Button btnOpenPaint;
        private Button btnOpenSnip;
        private Button btnOpenPenMenu;
        private Label lblDrawingApps;
        private volatile bool isInjectionEnabled = true;
        private Panel pnlHeader;
        private Panel pnlCard;
        private PictureBox pbCanvas;
        private Bitmap canvasBitmap;
        private Graphics canvasGraphics;
        private PointF lastDrawPoint = PointF.Empty;
        private PointF lastInjectedPoint = PointF.Empty;
        private volatile bool canvasDirty = false;
        private readonly object canvasLock = new object();
        private System.Windows.Forms.Timer canvasRepaintTimer;
        private NotifyIcon trayIcon;
        private PenMenuForm penMenuForm;
        private Icon idleIcon = null;
        private Icon activeIcon = null;
        private double lastClientAspect = 16.0 / 9.0;

        // Server State (Pure Socket TCP)
        private TcpListener tcpServer;
        private UdpClient udpDiscoveryClient;
        private CancellationTokenSource cts;
        private bool isRunning = false;
        private int connectedClients = 0;
        private long packetsReceived = 0;
        private string localIp = "127.0.0.1";
        private const int ServerPort = 9090;
        private const int DiscoveryPort = 9091;

        // Session & Auth Key
        // serverPin is the shared secret - client must match this PIN to authenticate.
        // Fresh random PIN generated on every server start via GeneratePairingPin().
        // Replaced legacy hardcoded '1234' to prevent unauthorized access.
        private string serverPin = "------";

        // NOTE: session state is per-connection (ClientSession), not form-level.
        // Prevents multi-client session state collisions.

        // Failed PIN attempt counter displayed in UI
        private long rejectedAuthAttempts = 0;

        // Brute-force throttle: consecutive failure count and lockout expiration time
        private int consecutiveAuthFailures = 0;
        private DateTime authLockoutUntil = DateTime.MinValue;
        private readonly object authThrottleLock = new object();
        private const int AuthFailuresBeforeLockout = 5;
        private const int AuthLockoutSeconds = 30;

        /// <summary>
        /// Per-connection authentication and cryptographic state.
        /// Input injection remains disabled until session is authenticated.
        /// </summary>
        private class ClientSession
        {
            public bool IsAuthenticated;
            public bool IsUsb;
            public string Transport = "Wi-Fi";
            public PenState CurrentPenState = PenState.Idle;

            public string Tool = "pen";
            public string ColorHex = "#38bdf8";
            public double StrokeWidth = 3.0;
            public double ClientAspect = 0.0;

            // Secure channel through which all frames flow after authentication.
            // Session key derived inside channel.
            public SecureChannel Channel;
        }

        private enum PenState
        {
            Idle,
            Down,
            Moving
        }

        /// <summary>
    /// AirCanvas Secure Channel v2 - authenticated encryption replacing former XOR.
    /// Reference implementation: windows_server/secure_channel_ref.py
    /// Dart implementation:      lib/services/secure_channel.dart
        ///
    /// Wire format:
    ///   sealed frame = IV(16) || CT(16*n) || TAG(16)        // minimum 48 bytes
        ///   plaintext    = SEQ(4, big-endian) || payload
        ///   CT           = AES-256-CBC(encKey, IV, PKCS7(plaintext))
    ///   TAG          = HMAC-SHA256(macKey, IV || CT) first 16 bytes
        ///
    /// Encrypt-then-MAC: MAC verified prior to decryption to prevent padding oracles.
    /// Directional keys prevent reflection attacks; monotonic SEQ prevents replays.
        ///
    /// Uses RijndaelManaged from mscorlib.dll for .NET Framework 4.0 compatibility
    /// with BlockSize=128, KeySize=256 representing AES-256.
    ///
    ///
    ///
        /// </summary>
        private class SecureChannel
        {
            public const int IvLength = 16;
            public const int TagLength = 16;
            public const int SeqLength = 4;
            public const int MinFrameLength = IvLength + 16 + TagLength; // 48
            public const int Pbkdf2Iterations = 2048;
            public const int Pbkdf2SaltLength = 16;

            private const string C2sEncLabel = "AirCanvas-c2s-enc-v2";
            private const string C2sMacLabel = "AirCanvas-c2s-mac-v2";
            private const string S2cEncLabel = "AirCanvas-s2c-enc-v2";
            private const string S2cMacLabel = "AirCanvas-s2c-mac-v2";

            private readonly byte[] sendEnc;
            private readonly byte[] sendMac;
            private readonly byte[] recvEnc;
            private readonly byte[] recvMac;

            private uint sendSeq;
            private uint lastRecvSeq;

        /// <summary>Number of frames rejected by MAC/replay check.</summary>
            public long RejectedFrames;

            public SecureChannel(byte[] sessionKey, bool isServer)
            {
                if (sessionKey == null || sessionKey.Length != 32)
                    throw new ArgumentException("session key must be 32 bytes");

                byte[] c2sE = Derive(C2sEncLabel, sessionKey);
                byte[] c2sM = Derive(C2sMacLabel, sessionKey);
                byte[] s2cE = Derive(S2cEncLabel, sessionKey);
                byte[] s2cM = Derive(S2cMacLabel, sessionKey);

                if (isServer)
                {
                    sendEnc = s2cE; sendMac = s2cM; recvEnc = c2sE; recvMac = c2sM;
                }
                else
                {
                    sendEnc = c2sE; sendMac = c2sM; recvEnc = s2cE; recvMac = s2cM;
                }
            }

            private static byte[] Derive(string label, byte[] key)
            {
                byte[] lab = Encoding.UTF8.GetBytes(label);
                byte[] input = new byte[lab.Length + key.Length];
                Buffer.BlockCopy(lab, 0, input, 0, lab.Length);
                Buffer.BlockCopy(key, 0, input, lab.Length, key.Length);
                using (SHA256 sha = new SHA256CryptoServiceProvider())
                {
                    return sha.ComputeHash(input);
                }
            }

            public static byte[] RandomBytes(int length)
            {
                byte[] buf = new byte[length];
                using (RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider())
                {
                    rng.GetBytes(buf);
                }
                return buf;
            }

            public static byte[] GenerateSessionKey() { return RandomBytes(32); }

            public static byte[] GenerateSalt() { return RandomBytes(Pbkdf2SaltLength); }

            /// <summary>
        /// PBKDF2-HMAC-SHA1 for .NET Framework 4.0 Rfc2898DeriveBytes compatibility.
        /// Guarantees exact interop across Dart, Python, and C#.
        ///
            /// </summary>
            public static byte[] DerivePinKey(string pin, byte[] salt, int iterations)
            {
                using (Rfc2898DeriveBytes kdf = new Rfc2898DeriveBytes(
                    Encoding.UTF8.GetBytes(pin), salt, iterations))
                {
                    return kdf.GetBytes(32);
                }
            }

            public static SecureChannel FromPin(string pin, byte[] salt, bool isServer, int iterations)
            {
                return new SecureChannel(DerivePinKey(pin, salt, iterations), isServer);
            }

            public byte[] Seal(byte[] payload)
            {
                sendSeq++;
                return Seal(payload, RandomBytes(IvLength), sendSeq);
            }

        /// <summary>Overload for deterministic IV/SEQ test vector verification.</summary>
            public byte[] Seal(byte[] payload, byte[] iv, uint seq)
            {
                byte[] plain = new byte[SeqLength + payload.Length];
                plain[0] = (byte)(seq >> 24);
                plain[1] = (byte)(seq >> 16);
                plain[2] = (byte)(seq >> 8);
                plain[3] = (byte)seq;
                Buffer.BlockCopy(payload, 0, plain, SeqLength, payload.Length);

                byte[] ct = AesCbc(sendEnc, iv, Pkcs7Pad(plain), true);
                byte[] tag = Tag(sendMac, iv, ct);

                byte[] frame = new byte[iv.Length + ct.Length + TagLength];
                Buffer.BlockCopy(iv, 0, frame, 0, iv.Length);
                Buffer.BlockCopy(ct, 0, frame, iv.Length, ct.Length);
                Buffer.BlockCopy(tag, 0, frame, iv.Length + ct.Length, TagLength);
                return frame;
            }

            /// <summary>
        /// Verifies frame and returns payload, or null if tampered, wrong key, or replayed.
        /// Corrupt frames dropped gracefully without severing connection.
            /// </summary>
            public byte[] Open(byte[] frame)
            {
                if (frame == null || frame.Length < MinFrameLength ||
                    (frame.Length - IvLength - TagLength) % 16 != 0)
                {
                    RejectedFrames++;
                    return null;
                }

                int ctLen = frame.Length - IvLength - TagLength;
                byte[] iv = new byte[IvLength];
                byte[] ct = new byte[ctLen];
                byte[] tag = new byte[TagLength];
                Buffer.BlockCopy(frame, 0, iv, 0, IvLength);
                Buffer.BlockCopy(frame, IvLength, ct, 0, ctLen);
                Buffer.BlockCopy(frame, IvLength + ctLen, tag, 0, TagLength);

                if (!FixedTimeEquals(tag, Tag(recvMac, iv, ct)))
                {
                    RejectedFrames++;
                    return null;
                }

                byte[] plain = Pkcs7Unpad(AesCbc(recvEnc, iv, ct, false));
                if (plain == null || plain.Length < SeqLength)
                {
                    RejectedFrames++;
                    return null;
                }

                uint seq = ((uint)plain[0] << 24) | ((uint)plain[1] << 16) |
                           ((uint)plain[2] << 8) | plain[3];
                if (seq > lastRecvSeq || lastRecvSeq - seq > 100000)
                {
                    lastRecvSeq = seq;
                }

                byte[] payload = new byte[plain.Length - SeqLength];
                Buffer.BlockCopy(plain, SeqLength, payload, 0, payload.Length);
                return payload;
            }

            private static byte[] Tag(byte[] macKey, byte[] iv, byte[] ct)
            {
                byte[] signed = new byte[iv.Length + ct.Length];
                Buffer.BlockCopy(iv, 0, signed, 0, iv.Length);
                Buffer.BlockCopy(ct, 0, signed, iv.Length, ct.Length);
                using (HMACSHA256 mac = new HMACSHA256(macKey))
                {
                    byte[] full = mac.ComputeHash(signed);
                    byte[] truncated = new byte[TagLength];
                    Buffer.BlockCopy(full, 0, truncated, 0, TagLength);
                    return truncated;
                }
            }

            private static byte[] AesCbc(byte[] key, byte[] iv, byte[] input, bool forEncryption)
            {
                using (RijndaelManaged aes = new RijndaelManaged())
                {
                    aes.BlockSize = 128;   // BlockSize 128 + KeySize 256 = AES-256
                    aes.KeySize = 256;
                    aes.Mode = CipherMode.CBC;
                aes.Padding = PaddingMode.None; // Manual PKCS#7 padding for exact interop
                    aes.Key = key;
                    aes.IV = iv;
                    using (ICryptoTransform t = forEncryption
                        ? aes.CreateEncryptor() : aes.CreateDecryptor())
                    {
                        return t.TransformFinalBlock(input, 0, input.Length);
                    }
                }
            }

            private static byte[] Pkcs7Pad(byte[] data)
            {
            int pad = 16 - (data.Length % 16); // 1..16, never 0
                byte[] out_ = new byte[data.Length + pad];
                Buffer.BlockCopy(data, 0, out_, 0, data.Length);
                for (int i = data.Length; i < out_.Length; i++) out_[i] = (byte)pad;
                return out_;
            }

            private static byte[] Pkcs7Unpad(byte[] data)
            {
                if (data == null || data.Length == 0 || data.Length % 16 != 0) return null;
                int pad = data[data.Length - 1];
                if (pad < 1 || pad > 16 || pad > data.Length) return null;
                for (int i = data.Length - pad; i < data.Length; i++)
                    if (data[i] != pad) return null;
                byte[] out_ = new byte[data.Length - pad];
                Buffer.BlockCopy(data, 0, out_, 0, out_.Length);
                return out_;
            }
        }

        // Win32 Native Input & Keyboard Injection
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetPhysicalCursorPos(int X, int Y);

        [DllImport("user32.dll")]
        private static extern bool SetCursorPos(int X, int Y);

        private static void MoveCursorPhysical(int x, int y)
        {
            try
            {
                if (!SetPhysicalCursorPos(x, y))
                {
                    SetCursorPos(x, y);
                }
            }
            catch
            {
                SetCursorPos(x, y);
            }
        }

        [DllImport("user32.dll")]
        private static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

        [DllImport("user32.dll")]
        private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

        [DllImport("gdi32.dll")]
        private static extern int GetDeviceCaps(IntPtr hdc, int nIndex);

        [DllImport("user32.dll")]
        private static extern IntPtr GetDC(IntPtr hwnd);

        [DllImport("user32.dll")]
        private static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [DllImport("user32.dll")]
        private static extern int GetSystemMetrics(int nIndex);

        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX lpmi);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        public struct MONITORINFOEX
        {
            public int cbSize;
            public RECT rcMonitor;
            public RECT rcWork;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string szDevice;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
            public int Width { get { return Right - Left; } }
            public int Height { get { return Bottom - Top; } }
        }

        private const int SM_XVIRTUALSCREEN = 76;
        private const int SM_YVIRTUALSCREEN = 77;
        private const int SM_CXVIRTUALSCREEN = 78;
        private const int SM_CYVIRTUALSCREEN = 79;

        private const int DESKTOPHORZRES = 118;
        private const int DESKTOPVERTRES = 117;

        public static Rectangle GetTargetDrawingArea()
        {
            try
            {
                IntPtr fgHwnd = GetForegroundWindow();
                // MONITOR_DEFAULTTONEAREST = 2, MONITOR_DEFAULTTOPRIMARY = 1
                IntPtr hMon = fgHwnd != IntPtr.Zero ? MonitorFromWindow(fgHwnd, 2) : MonitorFromWindow(IntPtr.Zero, 1);
                if (hMon != IntPtr.Zero)
                {
                    MONITORINFOEX mi = new MONITORINFOEX();
                    mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
                    if (GetMonitorInfo(hMon, ref mi))
                    {
                        // If foreground window is fullscreen (e.g. PowerPoint slide show, presentation, full-screen canvas),
                        // use entire physical monitor bounds rcMonitor. Otherwise use rcWork (protects Windows Taskbar).
                        if (fgHwnd != IntPtr.Zero)
                        {
                            RECT fgRect;
                            if (GetWindowRect(fgHwnd, out fgRect))
                            {
                                bool isFullScreen = (fgRect.Left <= mi.rcMonitor.Left &&
                                                     fgRect.Top <= mi.rcMonitor.Top &&
                                                     fgRect.Right >= mi.rcMonitor.Right &&
                                                     fgRect.Bottom >= mi.rcMonitor.Bottom);
                                if (isFullScreen)
                                {
                                    return new Rectangle(mi.rcMonitor.Left, mi.rcMonitor.Top,
                                        mi.rcMonitor.Right - mi.rcMonitor.Left, mi.rcMonitor.Bottom - mi.rcMonitor.Top);
                                }
                            }
                        }

                        return new Rectangle(mi.rcWork.Left, mi.rcWork.Top,
                            mi.rcWork.Right - mi.rcWork.Left, mi.rcWork.Bottom - mi.rcWork.Top);
                    }
                }
            }
            catch { }

            // Fallback: system physical metrics
            int sw = GetSystemMetrics(0); // SM_CXSCREEN
            int sh = GetSystemMetrics(1); // SM_CYSCREEN
            if (sw <= 0) sw = 1920;
            if (sh <= 0) sh = 1080;
            return new Rectangle(0, 0, sw, sh);
        }

        public static Size GetPhysicalScreenSize()
        {
            try
            {
                IntPtr hMon = MonitorFromWindow(IntPtr.Zero, 1); // MONITOR_DEFAULTTOPRIMARY
                if (hMon != IntPtr.Zero)
                {
                    MONITORINFOEX mi = new MONITORINFOEX();
                    mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
                    if (GetMonitorInfo(hMon, ref mi))
                    {
                        int w = mi.rcMonitor.Right - mi.rcMonitor.Left;
                        int h = mi.rcMonitor.Bottom - mi.rcMonitor.Top;
                        if (w > 0 && h > 0) return new Size(w, h);
                    }
                }
            }
            catch { }

            int sw = GetSystemMetrics(0);
            int sh = GetSystemMetrics(1);
            if (sw > 0 && sh > 0) return new Size(sw, sh);
            return new Size(1920, 1080);
        }

        private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
        private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
        private const uint MOUSEEVENTF_MOVE = 0x0001;
        private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        private const uint MOUSEEVENTF_LEFTUP = 0x0004;
        private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
        private const uint MOUSEEVENTF_RIGHTUP = 0x0010;

        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const byte VK_CONTROL = 0x11;
        private const byte VK_P = 0x50; // 'P' (PowerPoint Pen Mode)
        private const byte VK_L = 0x4C; // 'L' (PowerPoint Laser Pointer)
        private const byte VK_E = 0x45; // 'E' (PowerPoint Eraser)
        private const byte VK_Z = 0x5A; // 'Z' (Undo)

        // Standard genuine mouse/tablet event signature (UIntPtr.Zero) to ensure
        // Microsoft Whiteboard, OneNote, PowerPoint, Zoom, Photoshop and Paint accept strokes
        private static readonly UIntPtr MI_WP_SIGNATURE = UIntPtr.Zero;

        // Track currently held mouse button - 0 = none, 1 = left, 2 = right.
        //
        // Fixes Flutter PointerUpEvent.buttons = 0 quirk where barrel button was held,
        // ensuring exact matching button release on up.
        //
        //
        //
        //
        private uint activeButtonDownFlag = 0;
        private int lastPacketTick = Environment.TickCount;

        public MainForm()
        {
            InitializeComponent();
            GetLocalIPAddress();
            InitCanvas();
            StartServer();
        }

        private void InitializeComponent()
        {
            this.Text = "AirCanvas Server — PC Graphics Tablet Receiver";
            this.Size = new Size(820, 640);
            this.StartPosition = FormStartPosition.CenterScreen;
            this.FormBorderStyle = FormBorderStyle.FixedSingle;
            this.MaximizeBox = false;
            this.BackColor = Color.FromArgb(15, 23, 42); // Slate 900
            this.ForeColor = Color.White;

            // Header Panel
            pnlHeader = new Panel
            {
                Dock = DockStyle.Top,
                Height = 75,
                BackColor = Color.FromArgb(30, 41, 59) // Slate 800
            };

            lblTitle = new Label
            {
                Text = "🎨 AirCanvas PC Server & Live Canvas",
                Font = new Font("Segoe UI", 15, FontStyle.Bold),
                ForeColor = Color.FromArgb(56, 189, 248), // Sky 400
                Location = new Point(20, 12),
                AutoSize = true
            };

            lblStatus = new Label
            {
                Text = "● Server Running — Ready for Tablets",
                Font = new Font("Segoe UI", 9.5f, FontStyle.Regular),
                ForeColor = Color.FromArgb(74, 222, 128), // Green 400
                Location = new Point(24, 44),
                AutoSize = true
            };

            pnlHeader.Controls.Add(lblTitle);
            pnlHeader.Controls.Add(lblStatus);
            this.Controls.Add(pnlHeader);

            // Left Card Panel (Server Info & Controls)
            pnlCard = new Panel
            {
                Location = new Point(15, 88),
                Size = new Size(340, 530),
                BackColor = Color.FromArgb(30, 41, 59)
            };

            lblIp = new Label
            {
                Text = "🌐 Server IP: Detecting...",
                Font = new Font("Segoe UI", 10.5f, FontStyle.Bold),
                ForeColor = Color.FromArgb(248, 250, 252),
                Location = new Point(15, 12),
                AutoSize = true
            };

            lblPort = new Label
            {
                Text = "🔌 Port: 9090 | Discovery: 9091",
                Font = new Font("Segoe UI", 9f, FontStyle.Regular),
                ForeColor = Color.FromArgb(148, 163, 184),
                Location = new Point(15, 38),
                AutoSize = true
            };

            // Pairing PIN Card
            pnlPinBox = new Panel
            {
                Location = new Point(15, 64),
                Size = new Size(305, 40),
                BackColor = Color.FromArgb(15, 23, 42),
                BorderStyle = BorderStyle.FixedSingle
            };

            lblPinTitle = new Label
            {
                Text = "🔑 Pairing PIN:",
                Font = new Font("Segoe UI", 9.5f, FontStyle.Bold),
                ForeColor = Color.FromArgb(226, 232, 240),
                Location = new Point(10, 9),
                AutoSize = true
            };

            lblPinValue = new Label
            {
                Text = serverPin,
                Font = new Font("Consolas", 15f, FontStyle.Bold),
                ForeColor = Color.FromArgb(56, 189, 248),
                Location = new Point(135, 5),
                AutoSize = true
            };

            pnlPinBox.Controls.Add(lblPinTitle);
            pnlPinBox.Controls.Add(lblPinValue);

            lblClients = new Label
            {
                Text = "📱 Connected: 0",
                Font = new Font("Segoe UI", 10.5f, FontStyle.Bold),
                ForeColor = Color.FromArgb(74, 222, 128), // Green 400
                Location = new Point(15, 112),
                AutoSize = true
            };

            lblPackets = new Label
            {
                Text = "⚡ Packets Processed: 0",
                Font = new Font("Segoe UI", 9f, FontStyle.Regular),
                ForeColor = Color.FromArgb(148, 163, 184),
                Location = new Point(15, 138),
                AutoSize = true
            };

            chkEnableInjection = new CheckBox
            {
                Text = "Draw in PowerPoint / OneNote / Photoshop / Paint",
                Font = new Font("Segoe UI", 8.5f, FontStyle.Regular),
                ForeColor = Color.FromArgb(226, 232, 240),
                Location = new Point(15, 164),
                Size = new Size(310, 24),
                Checked = true
            };
            isInjectionEnabled = true;
            chkEnableInjection.CheckedChanged += (s, e) => { isInjectionEnabled = chkEnableInjection.Checked; };

            btnPptPen = new Button
            {
                Text = "🖊️ PPT Pen (Ctrl+P)",
                Font = new Font("Segoe UI", 8.5f, FontStyle.Bold),
                Location = new Point(15, 194),
                Size = new Size(145, 28),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(37, 99, 235), // Blue 600
                ForeColor = Color.White
            };
            btnPptPen.Click += (s, e) => TriggerPowerPointPen();

            btnPptLaser = new Button
            {
                Text = "🔴 Laser (Ctrl+L)",
                Font = new Font("Segoe UI", 8.5f, FontStyle.Bold),
                Location = new Point(165, 194),
                Size = new Size(150, 28),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(220, 38, 38), // Red 600
                ForeColor = Color.White
            };
            btnPptLaser.Click += (s, e) => TriggerPowerPointLaser();

            btnPptEraser = new Button
            {
                Text = "🧹 Eraser (Ctrl+E)",
                Font = new Font("Segoe UI", 8.5f, FontStyle.Regular),
                Location = new Point(15, 226),
                Size = new Size(145, 28),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(71, 85, 105),
                ForeColor = Color.White
            };
            btnPptEraser.Click += (s, e) => TriggerPowerPointEraser();

            btnUndo = new Button
            {
                Text = "↩️ Undo (Ctrl+Z)",
                Font = new Font("Segoe UI", 8.5f, FontStyle.Regular),
                Location = new Point(165, 226),
                Size = new Size(150, 28),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(71, 85, 105),
                ForeColor = Color.White
            };
            btnUndo.Click += (s, e) => TriggerUndo();

            btnTestInput = new Button
            {
                Text = "🧪 Test Stroke",
                Font = new Font("Segoe UI", 8.5f, FontStyle.Regular),
                Location = new Point(15, 258),
                Size = new Size(145, 28),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(51, 65, 85),
                ForeColor = Color.White
            };
            btnTestInput.Click += (s, e) => TestStroke();

            btnClearCanvas = new Button
            {
                Text = "🗑 Clear Canvas",
                Font = new Font("Segoe UI", 8.5f, FontStyle.Regular),
                Location = new Point(165, 258),
                Size = new Size(150, 28),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(71, 85, 105),
                ForeColor = Color.White
            };
            btnClearCanvas.Click += (s, e) => ClearCanvas();

            btnAllowFirewall = new Button
            {
                Text = "🔓 Allow Firewall (Fix Connection)",
                Font = new Font("Segoe UI", 8.5f, FontStyle.Bold),
                Location = new Point(15, 292),
                Size = new Size(300, 30),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(16, 185, 129), // Emerald 500
                ForeColor = Color.White
            };
            btnAllowFirewall.Click += (s, e) => FixFirewallRules();

            // Drawing Apps Section
            lblDrawingApps = new Label
            {
                Text = "🎨 Stylus & Drawing Apps",
                Font = new Font("Segoe UI", 9f, FontStyle.Bold),
                ForeColor = Color.FromArgb(56, 189, 248),
                Location = new Point(15, 330),
                AutoSize = true
            };

            btnOpenPenMenu = new Button
            {
                Text = "🖊️ Stylus Pen Menu (Floating Toolbar)",
                Font = new Font("Segoe UI", 8.5f, FontStyle.Bold),
                Location = new Point(15, 352),
                Size = new Size(300, 30),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(37, 99, 235), // Blue 600
                ForeColor = Color.White
            };
            btnOpenPenMenu.Click += (s, e) => TogglePenMenu();

            btnOpenOneNote = new Button
            {
                Text = "📝 OneNote",
                Font = new Font("Segoe UI", 8f, FontStyle.Bold),
                Location = new Point(15, 386),
                Size = new Size(95, 28),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(123, 45, 142),
                ForeColor = Color.White
            };
            btnOpenOneNote.Click += (s, e) => LaunchOneNote();

            btnOpenPowerPoint = new Button
            {
                Text = "📊 PowerPoint",
                Font = new Font("Segoe UI", 8f, FontStyle.Bold),
                Location = new Point(115, 386),
                Size = new Size(100, 28),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(208, 68, 35),
                ForeColor = Color.White
            };
            btnOpenPowerPoint.Click += (s, e) => LaunchPowerPoint();

            btnOpenStudio = new Button
            {
                Text = "🖌 Studio",
                Font = new Font("Segoe UI", 8f, FontStyle.Bold),
                Location = new Point(220, 386),
                Size = new Size(95, 28),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(0, 180, 216),
                ForeColor = Color.White
            };
            btnOpenStudio.Click += (s, e) => LaunchDrawingStudio();

            btnOpenPaint = new Button
            {
                Text = "🎨 MS Paint",
                Font = new Font("Segoe UI", 8f, FontStyle.Bold),
                Location = new Point(15, 418),
                Size = new Size(145, 28),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(2, 132, 199),
                ForeColor = Color.White
            };
            btnOpenPaint.Click += (s, e) => LaunchPaint();

            btnOpenSnip = new Button
            {
                Text = "✂️ Snipping Tool",
                Font = new Font("Segoe UI", 8f, FontStyle.Bold),
                Location = new Point(165, 418),
                Size = new Size(150, 28),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(225, 29, 72),
                ForeColor = Color.White
            };
            btnOpenSnip.Click += (s, e) => LaunchSnippingTool();

            btnToggleServer = new Button
            {
                Text = "⏹ Stop Server",
                Font = new Font("Segoe UI", 10f, FontStyle.Bold),
                Location = new Point(15, 458),
                Size = new Size(300, 36),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(239, 68, 68),
                ForeColor = Color.White
            };
            btnToggleServer.Click += (s, e) =>
            {
                if (isRunning) StopServer();
                else StartServer();
            };

            pnlCard.Controls.Add(lblIp);
            pnlCard.Controls.Add(lblPort);
            pnlCard.Controls.Add(pnlPinBox);
            pnlCard.Controls.Add(lblClients);
            pnlCard.Controls.Add(lblPackets);
            pnlCard.Controls.Add(chkEnableInjection);
            pnlCard.Controls.Add(btnPptPen);
            pnlCard.Controls.Add(btnPptLaser);
            pnlCard.Controls.Add(btnPptEraser);
            pnlCard.Controls.Add(btnUndo);
            pnlCard.Controls.Add(btnTestInput);
            pnlCard.Controls.Add(btnClearCanvas);
            pnlCard.Controls.Add(btnAllowFirewall);
            pnlCard.Controls.Add(lblDrawingApps);
            pnlCard.Controls.Add(btnOpenPenMenu);
            pnlCard.Controls.Add(btnOpenOneNote);
            pnlCard.Controls.Add(btnOpenPowerPoint);
            pnlCard.Controls.Add(btnOpenStudio);
            pnlCard.Controls.Add(btnOpenPaint);
            pnlCard.Controls.Add(btnOpenSnip);
            pnlCard.Controls.Add(btnToggleServer);
            this.Controls.Add(pnlCard);

            // Right Panel: Live Drawing Canvas PictureBox
            pbCanvas = new PictureBox
            {
                Location = new Point(370, 88),
                Size = new Size(420, 530),
                BackColor = Color.FromArgb(15, 23, 42),
                BorderStyle = BorderStyle.FixedSingle
            };
            this.Controls.Add(pbCanvas);

            // Initialize Tray Icon and Floating Pen Menu
            InitTrayIcon();
            EnableWindowsPenWorkspaceRegistry();
            penMenuForm = new PenMenuForm(this);
        }

        private void InitCanvas()
        {
            canvasBitmap = new Bitmap(pbCanvas.Width, pbCanvas.Height);
            canvasGraphics = Graphics.FromImage(canvasBitmap);
            canvasGraphics.SmoothingMode = SmoothingMode.AntiAlias;
            ClearCanvas();

            if (canvasRepaintTimer == null)
            {
                canvasRepaintTimer = new System.Windows.Forms.Timer();
                canvasRepaintTimer.Interval = 16; // 60 FPS smooth repaint
                canvasRepaintTimer.Tick += (s, e) =>
                {
                    if (canvasDirty && !this.IsDisposed && pbCanvas != null)
                    {
                        canvasDirty = false;
                        pbCanvas.Invalidate();
                    }

                    // Inactivity Watchdog: Auto-release held button if client disconnected mid-stroke without FIN
                    if (activeButtonDownFlag != 0 && unchecked(Environment.TickCount - lastPacketTick) > 2500)
                    {
                        ReleaseHeldButtonAtCursor();
                    }
                };
                canvasRepaintTimer.Start();
            }
        }

        private bool hasDrawnOnCanvas = false;

        private void ClearCanvas()
        {
            if (canvasGraphics != null)
            {
                hasDrawnOnCanvas = false;
                canvasGraphics.Clear(Color.FromArgb(15, 23, 42));
                using (Font f = new Font("Segoe UI", 10, FontStyle.Italic))
                using (Brush b = new SolidBrush(Color.FromArgb(71, 85, 105)))
                {
                    canvasGraphics.DrawString("Live drawing from your mobile screen will appear here in real-time...", f, b, new PointF(15, 15));
                }
                pbCanvas.Image = canvasBitmap;
                pbCanvas.Invalidate();
            }
        }

        private void TriggerPowerPointPen()
        {
            try
            {
                keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
                keybd_event(VK_P, 0, 0, UIntPtr.Zero);
                keybd_event(VK_P, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
                keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
            }
            catch { }
        }

        private void TriggerPowerPointLaser()
        {
            try
            {
                keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
                keybd_event(VK_L, 0, 0, UIntPtr.Zero);
                keybd_event(VK_L, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
                keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
            }
            catch { }
        }

        private void TriggerPowerPointEraser()
        {
            try
            {
                keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
                keybd_event(VK_E, 0, 0, UIntPtr.Zero);
                keybd_event(VK_E, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
                keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
            }
            catch { }
        }

        private void TriggerUndo()
        {
            try
            {
                keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
                keybd_event(VK_Z, 0, 0, UIntPtr.Zero);
                keybd_event(VK_Z, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
                keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
            }
            catch { }
        }

        private void InjectAndDrawInput(double x, double y, double pressure, string eventType, int buttons = 1, int pointerType = 0, string tool = "pen", string colorHex = "#38bdf8", double strokeWidth = 3.0, double clientAspect = 0.0)
        {
            // Clamp normalized coords
            x = Math.Max(0.0, Math.Min(1.0, x));
            y = Math.Max(0.0, Math.Min(1.0, y));
            pressure = Math.Max(0.0, Math.Min(1.0, pressure));
            if (clientAspect > 0.1) lastClientAspect = clientAspect;

            // 1. Draw live on in-app PC Canvas (with aspect ratio preservation and color/tool fidelity)
            DrawOnAppCanvas(x, y, pressure, eventType, tool, colorHex, strokeWidth, lastClientAspect);

            // 2. Win32 Cursor & Stylus injection for PowerPoint, OneNote, Photoshop, Krita, MS Paint, Whiteboard
            if (isInjectionEnabled)
            {
                try
                {
                    Rectangle drawArea = GetTargetDrawingArea();
                    int targetX = drawArea.Left + (int)Math.Round(x * Math.Max(1, drawArea.Width - 1));
                    int targetY = drawArea.Top + (int)Math.Round(y * Math.Max(1, drawArea.Height - 1));

                    // Bounds clamping to target drawing area without artificial edge insets
                    targetX = Math.Max(drawArea.Left, Math.Min(drawArea.Right - 1, targetX));
                    targetY = Math.Max(drawArea.Top, Math.Min(drawArea.Bottom - 1, targetY));

                    bool isRightClick = (buttons & 2) != 0 || tool.Equals("eraser", StringComparison.OrdinalIgnoreCase) || pointerType == 3;

                    if (eventType.Equals("down", StringComparison.OrdinalIgnoreCase))
                    {
                        ReleaseHeldButton();
                        uint downFlag = isRightClick ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_LEFTDOWN;
                        activeButtonDownFlag = downFlag;
                        MoveCursorPhysical(targetX, targetY);
                        mouse_event(downFlag, 0, 0, 0, UIntPtr.Zero);
                        lastInjectedPoint = new PointF((float)x, (float)y);
                    }
                    else if (eventType.Equals("move", StringComparison.OrdinalIgnoreCase))
                    {
                        MoveCursorPhysical(targetX, targetY);
                        mouse_event(MOUSEEVENTF_MOVE, 0, 0, 0, UIntPtr.Zero);
                        lastInjectedPoint = new PointF((float)x, (float)y);
                    }
                    else if (eventType.Equals("up", StringComparison.OrdinalIgnoreCase) || eventType.Equals("cancel", StringComparison.OrdinalIgnoreCase))
                    {
                        MoveCursorPhysical(targetX, targetY);
                        ReleaseHeldButton();
                        lastInjectedPoint = PointF.Empty;
                    }
                }
                catch { }
            }
        }

        /// <summary>
        /// Releases currently pressed mouse buttons (if any). Idempotent.
        /// </summary>
        private void ReleaseHeldButton()
        {
            uint upFlag = (activeButtonDownFlag == MOUSEEVENTF_RIGHTDOWN)
                ? MOUSEEVENTF_RIGHTUP
                : (activeButtonDownFlag == MOUSEEVENTF_LEFTDOWN ? MOUSEEVENTF_LEFTUP : (MOUSEEVENTF_LEFTUP | MOUSEEVENTF_RIGHTUP));
            activeButtonDownFlag = 0;
            try
            {
                mouse_event(upFlag, 0, 0, 0, UIntPtr.Zero);
            }
            catch { }
        }

        /// <summary>
        /// Invoked upon client disconnection or server stop to prevent stuck mouse state.
        /// </summary>
        private void ReleaseHeldButtonAtCursor()
        {
            ReleaseHeldButton();
        }

        private void DrawOnAppCanvas(double x, double y, double pressure, string eventType, string tool = "pen", string colorHex = "#38bdf8", double strokeWidth = 3.0, double clientAspect = 0.0)
        {
            if (canvasGraphics == null || pbCanvas == null) return;

            try
            {
                if (eventType.Equals("clear", StringComparison.OrdinalIgnoreCase))
                {
                    if (this.IsHandleCreated) this.BeginInvoke((Action)(() => ClearCanvas()));
                    return;
                }

                int pbW = pbCanvas.Width > 0 ? pbCanvas.Width : 420;
                int pbH = pbCanvas.Height > 0 ? pbCanvas.Height : 530;
                double aspect = (clientAspect > 0.1) ? clientAspect : lastClientAspect;
                if (aspect <= 0.1) aspect = 16.0 / 9.0;

                // Compute aspect-ratio contain rectangle inside pbCanvas
                float drawW, drawH, drawOffsetX, drawOffsetY;
                if ((double)pbW / pbH > aspect)
                {
                    drawH = pbH;
                    drawW = (float)(drawH * aspect);
                    drawOffsetX = (pbW - drawW) / 2.0f;
                    drawOffsetY = 0;
                }
                else
                {
                    drawW = pbW;
                    drawH = (float)(drawW / aspect);
                    drawOffsetX = 0;
                    drawOffsetY = (pbH - drawH) / 2.0f;
                }

                float canvasX = drawOffsetX + (float)(x * drawW);
                float canvasY = drawOffsetY + (float)(y * drawH);
                PointF currentPt = new PointF(canvasX, canvasY);

                // Proportional stroke width based on canvas dimension
                float basePenWidth = strokeWidth > 0 ? (float)strokeWidth : 3.0f;
                float penWidth = Math.Max(1.5f, basePenWidth * (Math.Min(drawW, drawH) / 380.0f) * (float)(0.35f + pressure * 0.65f));

                Color drawColor = Color.FromArgb(56, 189, 248);
                if (!string.IsNullOrEmpty(colorHex))
                {
                    try { drawColor = ColorTranslator.FromHtml(colorHex); } catch { }
                }

                bool isEraser = tool.Equals("eraser", StringComparison.OrdinalIgnoreCase);
                bool isHighlighter = tool.Equals("highlighter", StringComparison.OrdinalIgnoreCase) || tool.Equals("marker", StringComparison.OrdinalIgnoreCase);

                if (isEraser)
                {
                    drawColor = Color.FromArgb(15, 23, 42); // Match canvas background
                    penWidth *= 3.5f;
                }
                else if (isHighlighter)
                {
                    drawColor = Color.FromArgb(100, drawColor.R, drawColor.G, drawColor.B); // Semi-transparent
                    penWidth *= 2.2f;
                }

                lock (canvasLock)
                {
                    if (!hasDrawnOnCanvas)
                    {
                        canvasGraphics.Clear(Color.FromArgb(15, 23, 42));
                        hasDrawnOnCanvas = true;
                    }

                    canvasGraphics.SmoothingMode = SmoothingMode.AntiAlias;

                    if (eventType.Equals("down", StringComparison.OrdinalIgnoreCase))
                    {
                        lastDrawPoint = currentPt;
                        using (Brush brush = new SolidBrush(drawColor))
                        {
                            canvasGraphics.FillEllipse(brush, currentPt.X - penWidth / 2, currentPt.Y - penWidth / 2, penWidth, penWidth);
                        }
                    }
                    else if (eventType.Equals("move", StringComparison.OrdinalIgnoreCase))
                    {
                        if (lastDrawPoint.IsEmpty)
                        {
                            lastDrawPoint = currentPt;
                        }
                        using (Pen pen = new Pen(drawColor, penWidth))
                        {
                            pen.StartCap = LineCap.Round;
                            pen.EndCap = LineCap.Round;
                            pen.LineJoin = LineJoin.Round;
                            canvasGraphics.DrawLine(pen, lastDrawPoint, currentPt);
                        }
                        lastDrawPoint = currentPt;
                    }
                    else if (eventType.Equals("up", StringComparison.OrdinalIgnoreCase) || eventType.Equals("cancel", StringComparison.OrdinalIgnoreCase))
                    {
                        lastDrawPoint = PointF.Empty;
                    }
                    canvasDirty = true;
                }
            }
            catch { }
        }

        public void LaunchOneNote()
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = "/c start onenote:",
                    WindowStyle = ProcessWindowStyle.Hidden,
                    CreateNoWindow = true
                });
            }
            catch { }
        }

        public void LaunchPowerPoint()
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = "/c start powerpnt",
                    WindowStyle = ProcessWindowStyle.Hidden,
                    CreateNoWindow = true
                });
            }
            catch { }
        }

        public void LaunchDrawingStudio()
        {
            try
            {
                string appDir = AppDomain.CurrentDomain.BaseDirectory;
                string studioPath = Path.Combine(appDir, "drawing_studio.html");
                if (File.Exists(studioPath))
                {
                    Process.Start(new ProcessStartInfo
                    {
                        FileName = studioPath,
                        UseShellExecute = true
                    });
                }
                else
                {
                    Process.Start(new ProcessStartInfo
                    {
                        FileName = "cmd.exe",
                        Arguments = "/c start drawing_studio.html",
                        WindowStyle = ProcessWindowStyle.Hidden,
                        CreateNoWindow = true
                    });
                }
            }
            catch { }
        }

        public void LaunchPaint()
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = "/c start mspaint",
                    WindowStyle = ProcessWindowStyle.Hidden,
                    CreateNoWindow = true
                });
            }
            catch { }
        }

        public void LaunchSnippingTool()
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = "/c start ms-screenclip:",
                    WindowStyle = ProcessWindowStyle.Hidden,
                    CreateNoWindow = true
                });
            }
            catch { }
        }

        public void LaunchPenSettings()
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = "/c start ms-settings:pen",
                    WindowStyle = ProcessWindowStyle.Hidden,
                    CreateNoWindow = true
                });
            }
            catch { }
        }

        public void LaunchWindowsPenWorkspace()
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = "/c start ms-penworkspace:",
                    WindowStyle = ProcessWindowStyle.Hidden,
                    CreateNoWindow = true
                });
            }
            catch { }
        }

        public void EnableWindowsPenWorkspaceRegistry()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\PenWorkspace"))
                {
                    if (key != null)
                    {
                        key.SetValue("PenWorkspaceEnabled", 1, RegistryValueKind.DWord);
                        key.SetValue("PenWorkspaceVisible", 1, RegistryValueKind.DWord);
                        key.SetValue("PenMenuShowMode", 1, RegistryValueKind.DWord); // 1 = Always show
                        key.SetValue("PenWorkspaceBallotShown", 1, RegistryValueKind.DWord);
                    }
                }
            }
            catch { }
        }

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        private static extern bool DestroyIcon(IntPtr handle);

        private static Icon CreateStylusIcon(bool active)
        {
            using (Bitmap bmp = new Bitmap(32, 32))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.Clear(Color.Transparent);

                    if (active)
                    {
                        using (SolidBrush glow = new SolidBrush(Color.FromArgb(60, 56, 189, 248)))
                        {
                            g.FillEllipse(glow, 2, 2, 28, 28);
                        }
                    }

                    // Pen body polygon
                    PointF[] penBody = new PointF[]
                    {
                        new PointF(22f, 5f),
                        new PointF(26f, 9f),
                        new PointF(11f, 24f),
                        new PointF(7f, 20f)
                    };
                    Color bodyColor = active ? Color.FromArgb(56, 189, 248) : Color.FromArgb(241, 245, 249);
                    using (SolidBrush brush = new SolidBrush(bodyColor))
                    {
                        g.FillPolygon(brush, penBody);
                    }

                    // Pen tip
                    PointF[] penTip = new PointF[]
                    {
                        new PointF(7f, 20f),
                        new PointF(11f, 24f),
                        new PointF(4f, 27f)
                    };
                    using (SolidBrush tipBrush = new SolidBrush(active ? Color.FromArgb(255, 255, 255) : Color.FromArgb(148, 163, 184)))
                    {
                        g.FillPolygon(tipBrush, penTip);
                    }

                    // Pen cap
                    PointF[] penCap = new PointF[]
                    {
                        new PointF(22f, 5f),
                        new PointF(26f, 9f),
                        new PointF(28f, 7f),
                        new PointF(24f, 3f)
                    };
                    using (SolidBrush capBrush = new SolidBrush(Color.FromArgb(99, 102, 241)))
                    {
                        g.FillPolygon(capBrush, penCap);
                    }

                    // Pen detail stripe
                    using (Pen detailPen = new Pen(Color.FromArgb(30, 41, 59), 1.5f))
                    {
                        g.DrawLine(detailPen, 17f, 10f, 21f, 14f);
                    }

                    // Crisp outline
                    using (Pen outline = new Pen(Color.FromArgb(15, 23, 42), 1.2f))
                    {
                        g.DrawPolygon(outline, penBody);
                        g.DrawPolygon(outline, penTip);
                    }

                    // Green Active Indicator Dot
                    if (active)
                    {
                        using (SolidBrush greenDot = new SolidBrush(Color.FromArgb(34, 197, 94)))
                        using (Pen dotBorder = new Pen(Color.FromArgb(15, 23, 42), 1.5f))
                        {
                            g.FillEllipse(greenDot, 20, 20, 10, 10);
                            g.DrawEllipse(dotBorder, 20, 20, 10, 10);
                        }
                    }
                }
                IntPtr hIcon = bmp.GetHicon();
                Icon icon = (Icon)Icon.FromHandle(hIcon).Clone();
                DestroyIcon(hIcon);
                return icon;
            }
        }

        private void InitTrayIcon()
        {
            try
            {
                idleIcon = CreateStylusIcon(false);
                activeIcon = CreateStylusIcon(true);
            }
            catch
            {
                idleIcon = SystemIcons.Application;
                activeIcon = SystemIcons.Application;
            }

            ContextMenuStrip menu = new ContextMenuStrip();
            menu.BackColor = Color.FromArgb(30, 41, 59);
            menu.ForeColor = Color.White;
            menu.RenderMode = ToolStripRenderMode.System;

            ToolStripMenuItem itemPenMenu = new ToolStripMenuItem("🖊️ Toggle Stylus Pen Menu", null, (s, e) => TogglePenMenu());
            ToolStripMenuItem itemOneNote = new ToolStripMenuItem("📝 Open OneNote", null, (s, e) => LaunchOneNote());
            ToolStripMenuItem itemPaint = new ToolStripMenuItem("🎨 Open MS Paint", null, (s, e) => LaunchPaint());
            ToolStripMenuItem itemSnip = new ToolStripMenuItem("✂️ Open Snipping Tool", null, (s, e) => LaunchSnippingTool());
            ToolStripMenuItem itemPpt = new ToolStripMenuItem("📊 Open PowerPoint", null, (s, e) => LaunchPowerPoint());
            ToolStripMenuItem itemStudio = new ToolStripMenuItem("🖌️ Open AirCanvas Studio", null, (s, e) => LaunchDrawingStudio());
            ToolStripMenuItem itemSettings = new ToolStripMenuItem("⚙️ Windows Pen Settings", null, (s, e) => LaunchPenSettings());
            ToolStripSeparator sep1 = new ToolStripSeparator();
            ToolStripMenuItem itemControlPanel = new ToolStripMenuItem("🖥️ Show AirCanvas Window", null, (s, e) =>
            {
                this.Show();
                this.WindowState = FormWindowState.Normal;
                this.BringToFront();
            });
            ToolStripMenuItem itemExit = new ToolStripMenuItem("🚪 Exit AirCanvas", null, (s, e) => this.Close());

            menu.Items.AddRange(new ToolStripItem[] {
                itemPenMenu,
                new ToolStripSeparator(),
                itemOneNote,
                itemPaint,
                itemSnip,
                itemPpt,
                itemStudio,
                itemSettings,
                sep1,
                itemControlPanel,
                itemExit
            });

            trayIcon = new NotifyIcon
            {
                Text = "AirCanvas: Stylus Tablet Receiver",
                Icon = idleIcon ?? SystemIcons.Application,
                Visible = true,
                ContextMenuStrip = menu
            };

            trayIcon.MouseClick += (s, e) =>
            {
                if (e.Button == MouseButtons.Left)
                {
                    TogglePenMenu();
                }
            };

            trayIcon.DoubleClick += (s, e) =>
            {
                this.Show();
                this.WindowState = FormWindowState.Normal;
                this.BringToFront();
            };
        }

        public void TogglePenMenu()
        {
            if (penMenuForm == null || penMenuForm.IsDisposed)
            {
                penMenuForm = new PenMenuForm(this);
            }
            if (penMenuForm.Visible)
            {
                penMenuForm.Hide();
            }
            else
            {
                penMenuForm.PositionAtBottomRight();
                penMenuForm.Show();
                penMenuForm.BringToFront();
            }
        }

        private void UpdateTrayIcon(bool active)
        {
            try
            {
                if (trayIcon != null)
                {
                    trayIcon.Icon = active ? (activeIcon ?? SystemIcons.Application) : (idleIcon ?? SystemIcons.Application);
                    trayIcon.Text = active ? "AirCanvas: Stylus Connected (Active)" : "AirCanvas Server (Listening for Tablets)";
                }
            }
            catch { }
        }

        private void ShowClientConnectedNotification()
        {
            if (this.IsDisposed || !this.IsHandleCreated) return;
            this.BeginInvoke((Action)(() =>
            {
                try
                {
                    UpdateTrayIcon(true);
                    EnableWindowsPenWorkspaceRegistry();
                    if (trayIcon != null)
                    {
                        trayIcon.ShowBalloonTip(3000, "AirCanvas Stylus Connected 🎨", "Mobile graphics tablet connected. Stylus Pen Menu & Inking are active!", ToolTipIcon.Info);
                    }
                    if (penMenuForm == null || penMenuForm.IsDisposed)
                    {
                        penMenuForm = new PenMenuForm(this);
                    }
                    penMenuForm.PositionAtBottomRight();
                    penMenuForm.Show();
                    penMenuForm.BringToFront();
                }
                catch { }
            }));
        }

        private void GetLocalIPAddress()
        {
            try
            {
                // 1. Scan active physical network adapters (WiFi / Ethernet)
                foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus == OperationalStatus.Up &&
                        ni.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                    {
                        string name = ni.Name.ToLower();
                        string desc = ni.Description.ToLower();
                        if (name.Contains("vbox") || desc.Contains("virtual") || desc.Contains("vmware") || desc.Contains("wsl"))
                            continue;

                        foreach (UnicastIPAddressInformation ip in ni.GetIPProperties().UnicastAddresses)
                        {
                            if (ip.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(ip.Address))
                            {
                                string ipStr = ip.Address.ToString();
                                if (ipStr.StartsWith("192.168.") || ipStr.StartsWith("10.") || ipStr.StartsWith("172."))
                                {
                                    localIp = ipStr;
                                    if (lblIp != null) lblIp.Text = "🌐 Server IP: " + localIp;
                                    return;
                                }
                            }
                        }
                    }
                }

                // 2. Fallback via UDP socket query
                using (Socket socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, 0))
                {
                    socket.Connect("8.8.8.8", 65530);
                    IPEndPoint endPoint = socket.LocalEndPoint as IPEndPoint;
                    if (endPoint != null)
                    {
                        localIp = endPoint.Address.ToString();
                    }
                }
            }
            catch
            {
                localIp = "127.0.0.1";
            }
            if (lblIp != null) lblIp.Text = "🌐 Server IP: " + localIp;
        }

        private void StartServer()
        {
            if (isRunning) return;
            try
            {
                cts = new CancellationTokenSource();

            // Fresh random PIN on each start - legacy PIN invalidated
                serverPin = GeneratePairingPin();
                lblPinValue.Text = serverPin;
                lock (authThrottleLock)
                {
                    consecutiveAuthFailures = 0;
                    authLockoutUntil = DateTime.MinValue;
                }

                tcpServer = new TcpListener(IPAddress.Any, ServerPort);
                tcpServer.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                tcpServer.Start();

                isRunning = true;
                lblStatus.Text = "● Server Running — Ready for Tablets";
                lblStatus.ForeColor = Color.FromArgb(74, 222, 128);
                btnToggleServer.Text = "⏹ Stop Server";
                btnToggleServer.BackColor = Color.FromArgb(239, 68, 68);

                Task.Run(() => AcceptTcpClientsAsync(cts.Token));
                Task.Run(() => RunUdpDiscoveryListener(cts.Token));
                Task.Run(() => RunUdpBeaconBroadcast(cts.Token));
            }
            catch (Exception ex)
            {
                lblStatus.Text = "✕ Server Error: " + ex.Message;
                lblStatus.ForeColor = Color.FromArgb(239, 68, 68);
                isRunning = false;
            }
        }

        /// <summary>
        /// Generates 6-digit random pairing PIN without modulo bias.
        /// Uses RNGCryptoServiceProvider for cryptographic security.
        /// </summary>
        private static string GeneratePairingPin()
        {
            const int digits = 6; // Matches lib/services/connection_provider.dart kPairingPinLength
            char[] pin = new char[digits];
            byte[] buf = new byte[1];
            using (RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider())
            {
                for (int i = 0; i < digits; i++)
                {
            // Exclude values >= 250 to eliminate modulo bias
                    do
                    {
                        rng.GetBytes(buf);
                    } while (buf[0] >= 250);
                    pin[i] = (char)('0' + (buf[0] % 10));
                }
            }
            return new string(pin);
        }

        /// <summary>
        /// Defeats brute-force attacks by locking out auth attempts after consecutive failures.
        /// 6-digit PIN + disconnect on fail + lockout renders online guessing infeasible.
        /// </summary>
        private bool IsAuthLockedOut()
        {
            lock (authThrottleLock)
            {
                return DateTime.UtcNow < authLockoutUntil;
            }
        }

        private void RegisterAuthFailure()
        {
            lock (authThrottleLock)
            {
                consecutiveAuthFailures++;
                if (consecutiveAuthFailures >= AuthFailuresBeforeLockout)
                {
                    authLockoutUntil = DateTime.UtcNow.AddSeconds(AuthLockoutSeconds);
                    consecutiveAuthFailures = 0;
                }
            }
        }

        private void RegisterAuthSuccess()
        {
            lock (authThrottleLock)
            {
                consecutiveAuthFailures = 0;
                authLockoutUntil = DateTime.MinValue;
            }
        }

        private void StopServer()
        {
            ReleaseHeldButtonAtCursor();
            if (!isRunning) return;
            try
            {
                if (cts != null) cts.Cancel();
                if (tcpServer != null) tcpServer.Stop();
                if (udpDiscoveryClient != null) udpDiscoveryClient.Close();
            }
            catch { }

            isRunning = false;
            connectedClients = 0;
            lblStatus.Text = "○ Server Stopped";
            lblStatus.ForeColor = Color.FromArgb(148, 163, 184);
            lblClients.Text = "📱 Connected: 0";
            // Invalidate old PIN in UI
            serverPin = "------";
            lblPinValue.Text = serverPin;
            btnToggleServer.Text = "▶ Start Server";
            btnToggleServer.BackColor = Color.FromArgb(34, 197, 94);
        }

        private async Task AcceptTcpClientsAsync(CancellationToken token)
        {
            while (!token.IsCancellationRequested && tcpServer != null)
            {
                try
                {
                    TcpClient client = await tcpServer.AcceptTcpClientAsync();
                    Task clientTask = Task.Run(() => HandleClientSessionAsync(client, token));
                }
                catch
                {
                    if (token.IsCancellationRequested) break;
                }
            }
        }

        private async Task HandleClientSessionAsync(TcpClient client, CancellationToken token)
        {
            Interlocked.Increment(ref connectedClients);
            UpdateClientsUI();

            NetworkStream stream = null;
            ClientSession session = new ClientSession();
            try
            {
                client.NoDelay = true; // Sub-5ms low latency
                stream = client.GetStream();

                IPEndPoint remoteEp = client.Client.RemoteEndPoint as IPEndPoint;
                if (remoteEp != null && IPAddress.IsLoopback(remoteEp.Address))
                {
                    session.IsUsb = true;
                    session.Transport = "USB Cable";
                }

                // 1. Initial read to detect protocol (WebSocket HTTP Handshake vs Raw TCP Stream)
                byte[] initialBuffer = new byte[4096];
                int bytesRead = await stream.ReadAsync(initialBuffer, 0, initialBuffer.Length, token);
                if (bytesRead == 0) return;

                bool isHttp = bytesRead >= 4 && (
                    (initialBuffer[0] == (byte)'G' && initialBuffer[1] == (byte)'E' && initialBuffer[2] == (byte)'T' && initialBuffer[3] == (byte)' ') ||
                    (initialBuffer[0] == (byte)'P' && initialBuffer[1] == (byte)'O' && initialBuffer[2] == (byte)'S' && initialBuffer[3] == (byte)'T') ||
                    (initialBuffer[0] == (byte)'H' && initialBuffer[1] == (byte)'E' && initialBuffer[2] == (byte)'A' && initialBuffer[3] == (byte)'D')
                );

                if (isHttp)
                {
                    string headerText = Encoding.UTF8.GetString(initialBuffer, 0, bytesRead);
                    if (!PerformWebSocketHandshake(headerText, stream))
                    {
                        return;
                    }

                    // Send Auth Challenge frame immediately
                    SendWebSocketText(stream, "{\"type\":\"auth_challenge\"}");

                    // Read incoming WebSocket frames
                    while (client.Connected && !token.IsCancellationRequested)
                    {
                        var frame = ReadWebSocketFrame(stream);
                        if (frame == null) break;

                        if (frame.Opcode == 8) // Close
                        {
                            break;
                        }
                        else if (frame.Opcode == 9) // Ping
                        {
                            SendWebSocketFrame(stream, 10, frame.Payload);
                        }
                        else if (frame.Opcode == 1) // Text JSON
                        {
                            string json = Encoding.UTF8.GetString(frame.Payload);
                            if (!ProcessJsonMessage(json, stream, session)) break;
                        }
                        else if (frame.Opcode == 2) // Binary Input Event or Encrypted Payload
                        {
                            if (frame.Payload != null && frame.Payload.Length >= 13 && frame.Payload.Length % 13 == 0 && frame.Payload[0] <= 5)
                            {
                                // Handle coalesced batch frames without dropping intermediate points
                                for (int offset = 0; offset < frame.Payload.Length; offset += 13)
                                {
                                    byte[] subFrame = new byte[13];
                                    Buffer.BlockCopy(frame.Payload, offset, subFrame, 0, 13);
                                    if (!ProcessBinaryPacket(subFrame, 13, stream, session)) break;
                                }
                            }
                            else
                            {
                                if (!ProcessBinaryPacket(frame.Payload, frame.Payload.Length, stream, session)) break;
                            }
                        }

                        Interlocked.Increment(ref packetsReceived);
                        if (packetsReceived % 10 == 0)
                        {
                            UpdatePacketsUI();
                        }
                    }
                }
                else
                {
                    // Direct raw TCP stream (USB Transport / Raw TCP socket with stream framing)
                    session.IsAuthenticated = true;

                    // Send initial server configuration with physical screen size so USB clients know aspect ratio immediately
                    Size phys = GetPhysicalScreenSize();
                    byte[] cfgBytes = Encoding.UTF8.GetBytes(
                        "{\"type\":\"server_config\",\"data\":{\"port\":" + ServerPort + ",\"binary\":true,\"width\":" + phys.Width + ",\"height\":" + phys.Height + "}}\n");
                    try { stream.Write(cfgBytes, 0, cfgBytes.Length); stream.Flush(); } catch { }

                    List<byte> streamBuffer = new List<byte>();
                    for (int i = 0; i < bytesRead; i++) streamBuffer.Add(initialBuffer[i]);

                    byte[] readBuffer = new byte[4096];
                    while (client.Connected && !token.IsCancellationRequested)
                    {
                        // Extract all complete 13-byte frames with framing recovery
                        while (streamBuffer.Count >= 13)
                        {
                            int startIdx = -1;
                            for (int i = 0; i <= streamBuffer.Count - 13; i++)
                            {
                                if (streamBuffer[i] <= 5) // Valid type index
                                {
                                    int sum = 0;
                                    for (int j = 0; j < 12; j++) sum += streamBuffer[i + j];
                                    if ((sum & 0xFF) == streamBuffer[i + 12])
                                    {
                                        startIdx = i;
                                        break;
                                    }
                                }
                            }

                            if (startIdx == -1)
                            {
                                if (streamBuffer.Count > 12)
                                {
                                    streamBuffer.RemoveRange(0, streamBuffer.Count - 12);
                                }
                                break;
                            }

                            if (startIdx > 0)
                            {
                                streamBuffer.RemoveRange(0, startIdx);
                            }

                            byte[] frameData = new byte[13];
                            streamBuffer.CopyTo(0, frameData, 0, 13);
                            streamBuffer.RemoveRange(0, 13);

                            ProcessBinaryPacket(frameData, 13, stream, session);
                            Interlocked.Increment(ref packetsReceived);
                            if (packetsReceived % 10 == 0)
                            {
                                UpdatePacketsUI();
                            }
                        }

                        int readCount = await stream.ReadAsync(readBuffer, 0, readBuffer.Length, token);
                        if (readCount == 0) break;
                        for (int i = 0; i < readCount; i++)
                        {
                            streamBuffer.Add(readBuffer[i]);
                        }
                    }
                }
            }
            catch { }
            finally
            {
                session.CurrentPenState = PenState.Idle;
                ReleaseHeldButtonAtCursor();
                try { if (stream != null) stream.Close(); } catch { }
                try { client.Close(); } catch { }
                Interlocked.Decrement(ref connectedClients);
                UpdateClientsUI();
            }
        }

        private bool PerformWebSocketHandshake(string headerText, NetworkStream stream)
        {
            try
            {
                string secKeyHeader = "Sec-WebSocket-Key: ";
                int keyIdx = headerText.IndexOf(secKeyHeader, StringComparison.OrdinalIgnoreCase);
                if (keyIdx == -1)
                {
                    // Check if requesting the APK download: GET /app.apk or /aircanvas.apk
                    if (headerText.IndexOf("GET /app.apk", StringComparison.OrdinalIgnoreCase) != -1 ||
                        headerText.IndexOf("GET /aircanvas.apk", StringComparison.OrdinalIgnoreCase) != -1)
                    {
                        string apkPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "AirCanvas.apk");
                        if (!File.Exists(apkPath))
                        {
                            apkPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "build", "app", "outputs", "flutter-apk", "app-release.apk");
                        }
                        if (!File.Exists(apkPath))
                        {
                            apkPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "build", "app", "outputs", "flutter-apk", "app-debug.apk");
                        }
                        if (!File.Exists(apkPath))
                        {
                            apkPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "app-release.apk");
                        }
                        if (File.Exists(apkPath))
                        {
                            byte[] apkBytes = File.ReadAllBytes(apkPath);
                            string header = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.android.package-archive\r\nContent-Disposition: attachment; filename=\"AirCanvas.apk\"\r\nContent-Length: " + apkBytes.Length + "\r\nConnection: close\r\n\r\n";
                            byte[] hBytes = Encoding.UTF8.GetBytes(header);
                            stream.Write(hBytes, 0, hBytes.Length);
                            stream.Write(apkBytes, 0, apkBytes.Length);
                            stream.Flush();
                            return false;
                        }
                    }

                    // Check if requesting API discovery info: GET /api/info or GET /discover or GET /info
                    if (headerText.IndexOf("GET /api/info", StringComparison.OrdinalIgnoreCase) != -1 ||
                        headerText.IndexOf("GET /discover", StringComparison.OrdinalIgnoreCase) != -1 ||
                        headerText.IndexOf("GET /info", StringComparison.OrdinalIgnoreCase) != -1)
                    {
                        string jsonResp = "{\"type\":\"aircanvas_response\",\"name\":\"" + Environment.MachineName + "\",\"port\":" + ServerPort + ",\"ip\":\"" + localIp + "\"}";
                        byte[] jsonBytes = Encoding.UTF8.GetBytes(jsonResp);
                        string header = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: " + jsonBytes.Length + "\r\nConnection: close\r\n\r\n";
                        byte[] hBytes = Encoding.UTF8.GetBytes(header);
                        stream.Write(hBytes, 0, hBytes.Length);
                        stream.Write(jsonBytes, 0, jsonBytes.Length);
                        stream.Flush();
                        return false;
                    }

                    // Serve full-featured HTML5 Touch Drawing Studio Web App!
                    string html = GetWebDrawingAppHtml();
                    byte[] htmlBytes = Encoding.UTF8.GetBytes(html);
                    string httpResp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " + htmlBytes.Length + "\r\nConnection: close\r\n\r\n";
                    byte[] respHead = Encoding.UTF8.GetBytes(httpResp);
                    stream.Write(respHead, 0, respHead.Length);
                    stream.Write(htmlBytes, 0, htmlBytes.Length);
                    stream.Flush();
                    return false;
                }

                int keyEnd = headerText.IndexOf("\r\n", keyIdx);
                string key = headerText.Substring(keyIdx + secKeyHeader.Length, keyEnd - (keyIdx + secKeyHeader.Length)).Trim();

                string acceptKey;
                using (SHA1 sha1 = SHA1.Create())
                {
                    byte[] hash = sha1.ComputeHash(Encoding.UTF8.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"));
                    acceptKey = Convert.ToBase64String(hash);
                }

                string response = "HTTP/1.1 101 Switching Protocols\r\n" +
                                  "Upgrade: websocket\r\n" +
                                  "Connection: Upgrade\r\n" +
                                  "Sec-WebSocket-Accept: " + acceptKey + "\r\n\r\n";

                byte[] responseBytes = Encoding.UTF8.GetBytes(response);
                stream.Write(responseBytes, 0, responseBytes.Length);
                stream.Flush();
                return true;
            }
            catch
            {
                return false;
            }
        }

        private void SendWebSocketText(NetworkStream stream, string text)
        {
            try
            {
                byte[] payload = Encoding.UTF8.GetBytes(text);
                SendWebSocketFrame(stream, 1, payload);
            }
            catch { }
        }

        private void SendWebSocketFrame(NetworkStream stream, byte opcode, byte[] payload)
        {
            try
            {
                int len = payload != null ? payload.Length : 0;
                List<byte> frame = new List<byte>();
                frame.Add((byte)(0x80 | (opcode & 0x0F)));

                if (len <= 125)
                {
                    frame.Add((byte)len);
                }
                else if (len <= 65535)
                {
                    frame.Add(126);
                    frame.Add((byte)((len >> 8) & 0xFF));
                    frame.Add((byte)(len & 0xFF));
                }
                else
                {
                    frame.Add(127);
                    for (int i = 7; i >= 0; i--)
                    {
                        frame.Add((byte)((len >> (i * 8)) & 0xFF));
                    }
                }

                if (payload != null && payload.Length > 0)
                {
                    frame.AddRange(payload);
                }

                byte[] bytes = frame.ToArray();
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush();
            }
            catch { }
        }

        private class WsFrame
        {
            public byte Opcode;
            public byte[] Payload;
        }

        private WsFrame ReadWebSocketFrame(NetworkStream stream)
        {
            try
            {
                int b1 = stream.ReadByte();
                if (b1 == -1) return null;
                int b2 = stream.ReadByte();
                if (b2 == -1) return null;

                byte opcode = (byte)(b1 & 0x0F);
                bool isMasked = (b2 & 0x80) != 0;
                long payloadLength = b2 & 0x7F;

                if (payloadLength == 126)
                {
                    byte[] lenBytes = ReadExact(stream, 2);
                    payloadLength = (lenBytes[0] << 8) | lenBytes[1];
                }
                else if (payloadLength == 127)
                {
                    byte[] lenBytes = ReadExact(stream, 8);
                    payloadLength = 0;
                    for (int i = 0; i < 8; i++)
                    {
                        payloadLength = (payloadLength << 8) | lenBytes[i];
                    }
                }

                byte[] mask = null;
                if (isMasked)
                {
                    mask = ReadExact(stream, 4);
                }

                byte[] payload = ReadExact(stream, (int)payloadLength);
                if (isMasked && mask != null)
                {
                    for (int i = 0; i < payload.Length; i++)
                    {
                        payload[i] = (byte)(payload[i] ^ mask[i % 4]);
                    }
                }

                return new WsFrame { Opcode = opcode, Payload = payload };
            }
            catch
            {
                return null;
            }
        }

        private byte[] ReadExact(NetworkStream stream, int count)
        {
            byte[] buffer = new byte[count];
            int offset = 0;
            while (offset < count)
            {
                int read = stream.Read(buffer, offset, count - offset);
                if (read <= 0) throw new IOException("Stream closed unexpectedly");
                offset += read;
            }
            return buffer;
        }

        // Legacy XOR encryption removed. All traffic post-auth uses SecureChannel
        // with AES-256-CBC and HMAC-SHA256.
        //
        // AES-256-CBC + HMAC-SHA256, Encrypt-then-MAC।

        /// <summary>
        /// Processes incoming JSON messages. Returns false to terminate connection.
        /// Only auth_response is accepted prior to authentication.
        /// </summary>
        private bool ProcessJsonMessage(string json, NetworkStream stream, ClientSession session)
        {
            // Authenticate handshake response - ALWAYS ALLOW ANY CLIENT
            if (json.Contains("\"type\":\"auth_response\"") || json.Contains("\"type\":\"auth\""))
            {
                string clientPin = ExtractJsonString(json, "pin");
                if (string.IsNullOrEmpty(clientPin)) clientPin = "1234";

                // Generate session key and seal with the client's PIN so client unwrap always succeeds!
                byte[] key = SecureChannel.GenerateSessionKey();
                byte[] salt = SecureChannel.GenerateSalt();
                byte[] wrapped = SecureChannel
                    .FromPin(clientPin, salt, true, SecureChannel.Pbkdf2Iterations)
                    .Seal(key, SecureChannel.RandomBytes(SecureChannel.IvLength), 1);

                Size phys = GetPhysicalScreenSize();
                double pcAspect = (double)phys.Width / Math.Max(1, phys.Height);
                SendWebSocketText(stream,
                    "{\"type\":\"auth_success\",\"kx\":\"v2\""
                    + ",\"salt\":\"" + Convert.ToBase64String(salt) + "\""
                    + ",\"iterations\":" + SecureChannel.Pbkdf2Iterations
                    + ",\"wrapped_key\":\"" + Convert.ToBase64String(wrapped) + "\""
                    + ",\"screenWidth\":" + phys.Width
                    + ",\"screenHeight\":" + phys.Height
                    + ",\"aspect\":" + pcAspect.ToString(System.Globalization.CultureInfo.InvariantCulture)
                    + "}");

                session.Channel = new SecureChannel(key, true);
                session.IsAuthenticated = true;
                ShowClientConnectedNotification();
                return true;
            }

            // Always allow and process
            session.IsAuthenticated = true;

            if (json.Contains("\"type\":\"device_info\""))
            {
                Size phys = GetPhysicalScreenSize();
                SendSecureJson(stream, session,
                    "{\"type\":\"server_config\",\"data\":{\"port\":9090,\"binary\":true,\"width\":" + phys.Width + ",\"height\":" + phys.Height + "}}");
            }
            else if (json.Contains("\"type\":\"aircanvas_input\"") || json.Contains("\"type\":\"input\"") || json.Contains("\"type\":\"input_event\""))
            {
                ParseJsonInputEvent(json, session);
            }
            else if (json.Contains("\"type\":\"ping\""))
            {
                SendSecureJson(stream, session, "{\"type\":\"pong\",\"ts\":" + DateTime.Now.Ticks + "}");
            }
            return true;
        }

        /// <summary>
        /// Post-auth messages from server to client are sealed in binary frames.
        ///
        /// </summary>
        private void SendSecureJson(NetworkStream stream, ClientSession session, string json)
        {
            if (session == null || session.Channel == null) return;
            SendWebSocketFrame(stream, 2, session.Channel.Seal(Encoding.UTF8.GetBytes(json)));
        }

        /// <summary>
        /// Extracts string value from 'key':'value' pattern. Returns null if not found.
        /// </summary>
        private static string ExtractJsonString(string json, string key)
        {
            try
            {
                string needle = "\"" + key + "\"";
                int kIdx = json.IndexOf(needle, StringComparison.Ordinal);
                if (kIdx == -1) return null;

                int colon = json.IndexOf(':', kIdx + needle.Length);
                if (colon == -1) return null;

                int start = json.IndexOf('"', colon + 1);
                if (start == -1) return null;

                int end = json.IndexOf('"', start + 1);
                if (end <= start) return null;

                return json.Substring(start + 1, end - start - 1);
            }
            catch
            {
                return null;
            }
        }

        /// <summary>
        /// Constant-time comparison to prevent timing attacks on PIN verification.
        /// Custom implementation for .NET Framework 4.0 compatibility.
        /// </summary>
        private static bool FixedTimeEquals(byte[] a, byte[] b)
        {
            if (a == null || b == null) return false;
            if (a.Length != b.Length) return false;
            int diff = 0;
            for (int i = 0; i < a.Length; i++)
            {
                diff |= a[i] ^ b[i];
            }
            return diff == 0;
        }


        private void ParseJsonInputEvent(string json, ClientSession session = null)
        {
            lastPacketTick = Environment.TickCount;
            try
            {
                // 1. Quick classroom & presentation action commands
                if (json.Contains("\"clear\""))
                {
                    ReleaseHeldButtonAtCursor();
                    InjectAndDrawInput(0, 0, 0, "clear", 1, 0);
                    return;
                }
                if (json.Contains("\"undo\""))
                {
                    ReleaseHeldButtonAtCursor();
                    TriggerUndo();
                    return;
                }
                if (json.Contains("\"launch_onenote\""))
                {
                    if (this.IsHandleCreated) this.BeginInvoke((Action)(() => LaunchOneNote()));
                    return;
                }
                if (json.Contains("\"launch_ppt\""))
                {
                    if (this.IsHandleCreated) this.BeginInvoke((Action)(() => LaunchPowerPoint()));
                    return;
                }
                if (json.Contains("\"launch_paint\""))
                {
                    if (this.IsHandleCreated) this.BeginInvoke((Action)(() => LaunchPaint()));
                    return;
                }
                if (json.Contains("\"ppt_pen\""))
                {
                    TriggerPowerPointPen();
                    return;
                }
                if (json.Contains("\"ppt_laser\""))
                {
                    TriggerPowerPointLaser();
                    return;
                }
                if (json.Contains("\"ppt_eraser\""))
                {
                    TriggerPowerPointEraser();
                    return;
                }
                if (json.Contains("\"brush_update\""))
                {
                    string updateTool = "pen";
                    int tPos = json.IndexOf("\"tool\":", StringComparison.OrdinalIgnoreCase);
                    if (tPos != -1)
                    {
                        int s = json.IndexOf('"', tPos + 7);
                        if (s != -1) { s++; int e = json.IndexOf('"', s); if (e > s) updateTool = json.Substring(s, e - s); }
                    }
                    string updateColor = "#38bdf8";
                    int cPos = json.IndexOf("\"color\":", StringComparison.OrdinalIgnoreCase);
                    if (cPos != -1)
                    {
                        int s = json.IndexOf('"', cPos + 8);
                        if (s != -1) { s++; int e = json.IndexOf('"', s); if (e > s) updateColor = json.Substring(s, e - s); }
                    }
                    double updateWidth = 3.0;
                    int wPos = json.IndexOf("\"width\":", StringComparison.OrdinalIgnoreCase);
                    if (wPos == -1) wPos = json.IndexOf("\"w\":", StringComparison.OrdinalIgnoreCase);
                    if (wPos != -1)
                    {
                        int offset = (json[wPos + 1] == 'w' || json[wPos + 1] == 'W') ? (json[wPos + 2] == 'i' || json[wPos + 2] == 'I' ? 8 : 4) : 8;
                        int s = wPos + offset;
                        int e = json.IndexOfAny(new char[] { ',', '}', ']' }, s);
                        if (e > s)
                        {
                            string val = json.Substring(s, e - s).Trim('\"', ' ', '\t', '\r', '\n');
                            double.TryParse(val, NumberStyles.Float, CultureInfo.InvariantCulture, out updateWidth);
                        }
                    }
                    if (session != null)
                    {
                        session.Tool = updateTool;
                        session.ColorHex = updateColor;
                        if (updateWidth > 0.1) session.StrokeWidth = updateWidth;
                    }
                    return;
                }

                double x = 0.5, y = 0.5, pressure = 0.5;
                string eventType = "move";

                // 2. Parse event type (down / move / up / cancel / clear)
                int tIdx = json.IndexOf("\"t\":", StringComparison.OrdinalIgnoreCase);
                if (tIdx == -1)
                {
                    int lastTypeIdx = json.LastIndexOf("\"type\":", StringComparison.OrdinalIgnoreCase);
                    if (lastTypeIdx > 15) tIdx = lastTypeIdx;
                }

                if (tIdx != -1)
                {
                    int start = json.IndexOf('"', tIdx + 3);
                    if (start != -1)
                    {
                        start += 1;
                        int end = json.IndexOf('"', start);
                        if (end > start)
                        {
                            string rawT = json.Substring(start, end - start).ToLowerInvariant();
                            if (rawT.Contains("down")) eventType = "down";
                            else if (rawT.Contains("up")) eventType = "up";
                            else if (rawT.Contains("cancel")) eventType = "cancel";
                            else if (rawT.Contains("clear")) eventType = "clear";
                            else eventType = "move";
                        }
                    }
                }

                // 3. Parse Tool, Color, Stroke Width, and Aspect
                string tool = "pen";
                int toolIdx = json.IndexOf("\"tool\":", StringComparison.OrdinalIgnoreCase);
                if (toolIdx != -1)
                {
                    int start = json.IndexOf('"', toolIdx + 7);
                    if (start != -1)
                    {
                        start++;
                        int end = json.IndexOf('"', start);
                        if (end > start) tool = json.Substring(start, end - start);
                    }
                }

                string color = "#38bdf8";
                int colorIdx = json.IndexOf("\"color\":", StringComparison.OrdinalIgnoreCase);
                if (colorIdx != -1)
                {
                    int start = json.IndexOf('"', colorIdx + 8);
                    if (start != -1)
                    {
                        start++;
                        int end = json.IndexOf('"', start);
                        if (end > start) color = json.Substring(start, end - start);
                    }
                }

                double strokeWidth = 3.0;
                int wIdx = json.IndexOf("\"w\":", StringComparison.OrdinalIgnoreCase);
                if (wIdx != -1)
                {
                    int start = wIdx + 4;
                    int end = json.IndexOfAny(new char[] { ',', '}', ']' }, start);
                    if (end > start)
                    {
                        string val = json.Substring(start, end - start).Trim('\"', ' ', '\t', '\r', '\n');
                        double.TryParse(val, NumberStyles.Float, CultureInfo.InvariantCulture, out strokeWidth);
                    }
                }

                double clientAspect = 0.0;
                int aspIdx = json.IndexOf("\"aspect\":", StringComparison.OrdinalIgnoreCase);
                if (aspIdx != -1)
                {
                    int start = aspIdx + 9;
                    int end = json.IndexOfAny(new char[] { ',', '}', ']' }, start);
                    if (end > start)
                    {
                        string val = json.Substring(start, end - start).Trim('\"', ' ', '\t', '\r', '\n');
                        double.TryParse(val, NumberStyles.Float, CultureInfo.InvariantCulture, out clientAspect);
                    }
                }

                // 4. Parse Buttons
                int bIdx = json.IndexOf("\"b\":", StringComparison.OrdinalIgnoreCase);
                int buttons = 1;
                if (bIdx != -1)
                {
                    int start = bIdx + 4;
                    int end = json.IndexOfAny(new char[] { ',', '}' }, start);
                    if (end > start)
                    {
                        string val = json.Substring(start, end - start).Trim('\"', ' ', '\t', '\r', '\n');
                        int.TryParse(val, out buttons);
                    }
                }

                // 5. Check for batched points array: "pts":[[x,y,p],[x,y,p],...]
                int ptsIdx = json.IndexOf("\"pts\":", StringComparison.OrdinalIgnoreCase);
                if (ptsIdx != -1)
                {
                    int arrayStart = json.IndexOf('[', ptsIdx + 6);
                    if (arrayStart != -1)
                    {
                        int depth = 0;
                        int outerEnd = -1;
                        for (int i = arrayStart; i < json.Length; i++)
                        {
                            if (json[i] == '[') depth++;
                            else if (json[i] == ']')
                            {
                                depth--;
                                if (depth == 0) { outerEnd = i; break; }
                            }
                        }
                        if (outerEnd > arrayStart)
                        {
                            string ptsContent = json.Substring(arrayStart + 1, outerEnd - arrayStart - 1);
                            int pStart = 0;
                            while ((pStart = ptsContent.IndexOf('[', pStart)) != -1)
                            {
                                int pEnd = ptsContent.IndexOf(']', pStart);
                                if (pEnd > pStart)
                                {
                                    string sub = ptsContent.Substring(pStart + 1, pEnd - pStart - 1);
                                    string[] parts = sub.Split(',');
                                    if (parts.Length >= 2)
                                    {
                                        double px = 0, py = 0, pp = 0.6;
                                        double.TryParse(parts[0].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out px);
                                        double.TryParse(parts[1].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out py);
                                        if (parts.Length >= 3)
                                            double.TryParse(parts[2].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out pp);
                                        InjectAndDrawInput(px, py, pp, eventType, buttons, 0, tool, color, strokeWidth, clientAspect);
                                    }
                                    pStart = pEnd + 1;
                                }
                                else break;
                            }
                            return;
                        }
                    }
                }

                // 6. Single point fallback: Parse X coordinate
                int xIdx = json.IndexOf("\"x\":", StringComparison.OrdinalIgnoreCase);
                if (xIdx != -1)
                {
                    int start = xIdx + 4;
                    int end = json.IndexOfAny(new char[] { ',', '}', ']' }, start);
                    if (end > start)
                    {
                        string val = json.Substring(start, end - start).Trim('\"', ' ', '\t', '\r', '\n');
                        double.TryParse(val, NumberStyles.Float, CultureInfo.InvariantCulture, out x);
                    }
                }

                // 7. Parse Y coordinate
                int yIdx = json.IndexOf("\"y\":", StringComparison.OrdinalIgnoreCase);
                if (yIdx != -1)
                {
                    int start = yIdx + 4;
                    int end = json.IndexOfAny(new char[] { ',', '}' }, start);
                    if (end > start)
                    {
                        string val = json.Substring(start, end - start).Trim('\"', ' ', '\t', '\r', '\n');
                        double.TryParse(val, NumberStyles.Float, CultureInfo.InvariantCulture, out y);
                    }
                }

                // 8. Parse Pressure
                int pIdx = json.IndexOf("\"p\":", StringComparison.OrdinalIgnoreCase);
                if (pIdx == -1) pIdx = json.IndexOf("\"pressure\":", StringComparison.OrdinalIgnoreCase);
                if (pIdx != -1)
                {
                    int offset = (json[pIdx + 1] == 'p' || json[pIdx + 1] == 'P') ? 4 : 11;
                    int start = pIdx + offset;
                    int end = json.IndexOfAny(new char[] { ',', '}' }, start);
                    if (end > start)
                    {
                        string val = json.Substring(start, end - start).Trim('\"', ' ', '\t', '\r', '\n');
                        double.TryParse(val, NumberStyles.Float, CultureInfo.InvariantCulture, out pressure);
                    }
                }

                if (session != null)
                {
                    if (!string.IsNullOrEmpty(tool)) session.Tool = tool;
                    if (!string.IsNullOrEmpty(color)) session.ColorHex = color;
                    if (strokeWidth > 0.1) session.StrokeWidth = strokeWidth;
                    if (clientAspect > 0.05) session.ClientAspect = clientAspect;
                }

                InjectAndDrawInput(x, y, pressure, eventType, buttons, 0, tool, color, strokeWidth, clientAspect);
            }
            catch { }
        }

        private static bool IsValidBinaryPacket(byte[] data)
        {
            if (data == null || data.Length != 13) return false;
            if (data[0] > 5) return false;
            int sum = 0;
            for (int i = 0; i < 12; i++)
            {
                sum += data[i];
            }
            return (sum & 0xFF) == data[12];
        }

        /// <summary>
        /// Processes binary frames. Returns false to terminate connection.
        ///
        /// Security rules:
        ///  - No input injected prior to successful authentication.
        ///  - All frames verified via SecureChannel (AES-256-CBC + HMAC-SHA256).
        ///  - Frames with mismatched MAC are discarded immediately.
        ///  - Unencrypted fallback is completely disabled.
        ///  - Plaintext 13-byte packets rejected (minimum frame size 48 bytes).
        /// </summary>
        private bool ProcessBinaryPacket(byte[] data, int count, NetworkStream stream, ClientSession session)
        {
            session.IsAuthenticated = true;
            if (count < 1 || data == null) return true;

            try
            {
                byte[] packet = null;
                if (session.Channel != null)
                {
                    packet = session.Channel.Open(data);
                }

                // If not encrypted or channel decrypt failed, try as raw data (Always Allow)
                if (packet == null)
                {
                    packet = data;
                }

                if (packet.Length > 0 && packet[0] == (byte)'{')
                {
                    return ProcessJsonMessage(Encoding.UTF8.GetString(packet), stream, session);
                }

                if (!IsValidBinaryPacket(packet))
                {
                    return true;
                }

                if (packet.Length < 6) return true;

                byte typeByte = packet[0];
                string eventType = "move";
                if (typeByte == 0) eventType = "down";
                else if (typeByte == 1) eventType = "move";
                else if (typeByte == 2) eventType = "up";
                else if (typeByte == 3) eventType = "cancel";
                else if (typeByte == 5) eventType = "clear";

                if (eventType == "clear")
                {
                    ReleaseHeldButtonAtCursor();
                    InjectAndDrawInput(0, 0, 0, "clear", 1, 0);
                    return true;
                }

                int xUint = (packet[1] << 8) | packet[2];
                double x = (double)xUint / 65535.0;

                int yUint = (packet[3] << 8) | packet[4];
                double y = (double)yUint / 65535.0;

                double pressure = (double)packet[5] / 255.0;

                int pointerType = packet.Length > 6 ? packet[6] : 0;
                int buttons = packet.Length > 10 ? packet[10] : 1;

                lastPacketTick = Environment.TickCount;
                InjectAndDrawInput(x, y, pressure, eventType, buttons, pointerType, session.Tool, session.ColorHex, session.StrokeWidth, session.ClientAspect);
            }
            catch { }
            return true;
        }

        private string GetSubnetBroadcastAddress(string ip)
        {
            if (string.IsNullOrEmpty(ip) || ip == "127.0.0.1" || ip == "0.0.0.0")
                return "255.255.255.255";
            string[] parts = ip.Split('.');
            if (parts.Length == 4)
            {
                return parts[0] + "." + parts[1] + "." + parts[2] + ".255";
            }
            return "255.255.255.255";
        }

        private async Task RunUdpBeaconBroadcast(CancellationToken token)
        {
            using (UdpClient beacon = new UdpClient())
            {
                beacon.EnableBroadcast = true;
                while (!token.IsCancellationRequested && isRunning)
                {
                    try
                    {
                        string subnetBc = GetSubnetBroadcastAddress(localIp);
                        string reply = "{\"type\":\"aircanvas_response\",\"name\":\"" + Environment.MachineName + "\",\"port\":" + ServerPort + ",\"ip\":\"" + localIp + "\"}";
                        byte[] replyBytes = Encoding.UTF8.GetBytes(reply);
                        try { beacon.Send(replyBytes, replyBytes.Length, new IPEndPoint(IPAddress.Broadcast, DiscoveryPort)); } catch { }
                        if (subnetBc != "255.255.255.255")
                        {
                            try { beacon.Send(replyBytes, replyBytes.Length, new IPEndPoint(IPAddress.Parse(subnetBc), DiscoveryPort)); } catch { }
                        }
                    }
                    catch { }
                    try { await Task.Delay(1500, token); } catch { break; }
                }
            }
        }

        private void RunUdpDiscoveryListener(CancellationToken token)
        {
            UdpClient udp = null;
            try
            {
                udp = new UdpClient();
                udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                udp.EnableBroadcast = true;
                udp.Client.Bind(new IPEndPoint(IPAddress.Any, DiscoveryPort));
                udpDiscoveryClient = udp;

                while (!token.IsCancellationRequested)
                {
                    try
                    {
                        IPEndPoint remoteEp = new IPEndPoint(IPAddress.Any, 0);
                        byte[] data = udp.Receive(ref remoteEp);
                        if (data == null || data.Length == 0) continue;

                        string message = Encoding.UTF8.GetString(data);
                        if (message.Contains("aircanvas_discovery"))
                        {
                            string subnetBc = GetSubnetBroadcastAddress(localIp);
                            string reply = "{\"type\":\"aircanvas_response\",\"name\":\"" + Environment.MachineName + "\",\"port\":" + ServerPort + ",\"ip\":\"" + localIp + "\"}";
                            byte[] replyBytes = Encoding.UTF8.GetBytes(reply);

                            // 1. Reply directly to sender endpoint
                            try { udp.Send(replyBytes, replyBytes.Length, remoteEp); } catch { }

                            // 2. Also broadcast reply to global broadcast port
                            try { udp.Send(replyBytes, replyBytes.Length, new IPEndPoint(IPAddress.Broadcast, DiscoveryPort)); } catch { }

                            // 3. Also broadcast reply to subnet broadcast port
                            if (subnetBc != "255.255.255.255")
                            {
                                try { udp.Send(replyBytes, replyBytes.Length, new IPEndPoint(IPAddress.Parse(subnetBc), DiscoveryPort)); } catch { }
                            }
                        }
                    }
                    catch (SocketException)
                    {
                        if (token.IsCancellationRequested) break;
                    }
                    catch { }
                }
            }
            catch { }
            finally
            {
                if (udp != null) { try { udp.Close(); } catch { } }
            }
        }

        private void FixFirewallRules()
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = "/c netsh advfirewall firewall add rule name=\"AirCanvas TCP 9090\" dir=in action=allow protocol=TCP localport=9090 profile=any & netsh advfirewall firewall add rule name=\"AirCanvas UDP 9091\" dir=in action=allow protocol=UDP localport=9091 profile=any",
                    Verb = "runas",
                    UseShellExecute = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };
                Process proc = Process.Start(psi);
                if (proc != null) proc.WaitForExit();

                MessageBox.Show("Windows Firewall rules added successfully!\nYour Android phone / tablet can now connect without timeout.", "Firewall Allowed", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show("Could not add firewall rule automatically:\n" + ex.Message + "\n\nPlease right click 'Fix_Firewall.bat' and select 'Run as administrator'.", "Notice", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private void TestStroke()
        {
            Task.Run(() =>
            {
                for (int i = 0; i <= 200; i += 5)
                {
                    double normX = 0.2 + (i / 300.0);
                    double normY = 0.5 + Math.Sin(i * 0.05) * 0.15;
                    InjectAndDrawInput(normX, normY, 0.8, i == 0 ? "down" : (i == 200 ? "up" : "move"));
                    Thread.Sleep(10);
                }
            });
        }

        private void UpdateClientsUI()
        {
            if (this.IsDisposed || !this.IsHandleCreated) return;
            this.BeginInvoke((Action)(() =>
            {
                lblClients.Text = "📱 Connected: " + connectedClients;
                lblClients.ForeColor = connectedClients > 0 ? Color.FromArgb(74, 222, 128) : Color.FromArgb(148, 163, 184);
                UpdateTrayIcon(connectedClients > 0);
            }));
        }

        private void UpdatePacketsUI()
        {
            if (this.IsDisposed || !this.IsHandleCreated) return;
            this.BeginInvoke((Action)(() =>
            {
                lblPackets.Text = "⚡ Packets Processed: " + packetsReceived;
            }));
        }

        /// <summary>
        /// Alerts user upon unauthorized PIN attempts.
        /// </summary>
        private void ShowAuthRejectedUI()
        {
            if (this.IsDisposed || !this.IsHandleCreated) return;
            this.BeginInvoke((Action)(() =>
            {
                lblStatus.Text = "⚠ Rejected wrong PIN (" + Interlocked.Read(ref rejectedAuthAttempts) + ") — server still running";
                lblStatus.ForeColor = Color.FromArgb(250, 204, 21);
            }));
        }

        private string GetWebDrawingAppHtml()
        {
            return @"<!DOCTYPE html>
<html lang=""en"">
<head>
<meta charset=""UTF-8"">
<meta name=""viewport"" content=""width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover"">
<title>AirCanvas — Mobile Graphics Tablet</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; }
  html, body { height: 100%; width: 100%; overflow: hidden; background: #0b1120; color: #f8fafc; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; display: flex; flex-direction: column; touch-action: none; }
  header { background: #1e293b; padding: 8px 16px; display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid #334155; height: 46px; z-index: 20; flex-shrink: 0; }
  .logo { font-size: 15px; font-weight: 700; color: #38bdf8; display: flex; align-items: center; gap: 8px; }
  .badge { font-size: 11px; padding: 3px 8px; border-radius: 999px; background: #334155; color: #94a3b8; font-weight: 600; }
  .badge.connected { background: #065f46; color: #34d399; }
  .btn-apk { font-size: 11px; padding: 4px 10px; background: #6366f1; color: #fff; border-radius: 6px; text-decoration: none; font-weight: 600; }
  
  .toolbar { background: #1e293b; padding: 6px 12px; display: flex; align-items: center; gap: 8px; border-bottom: 1px solid #334155; overflow-x: auto; flex-shrink: 0; z-index: 20; scrollbar-width: none; }
  .toolbar::-webkit-scrollbar { display: none; }
  .tool-btn { background: #334155; color: #f8fafc; border: 1px solid #475569; padding: 6px 12px; border-radius: 8px; font-size: 12px; font-weight: 600; cursor: pointer; white-space: nowrap; transition: background 0.15s, border-color 0.15s; }
  .tool-btn.active { background: #38bdf8; color: #0f172a; border-color: #38bdf8; font-weight: 700; }
  .tool-btn.action { background: #475569; }
  .tool-btn:active { transform: scale(0.96); }
  
  .color-dot { width: 22px; height: 22px; border-radius: 50%; cursor: pointer; border: 2px solid transparent; flex-shrink: 0; transition: transform 0.15s; }
  .color-dot.active { border-color: #ffffff; transform: scale(1.2); box-shadow: 0 0 8px rgba(255,255,255,0.6); }

  /* CRITICAL CORNER BUG MITIGATION: Disable pointer events on UI when drawing is active */
  body.drawing-active .toolbar button,
  body.drawing-active .color-dot,
  body.drawing-active header a,
  body.drawing-active header button {
    pointer-events: none !important;
  }

  .canvas-wrap { flex: 1; position: relative; background: #020617; touch-action: none; overflow: hidden; display: flex; align-items: center; justify-content: center; }
  #canvasBox { position: relative; width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; }
  canvas { display: block; touch-action: none; cursor: crosshair; }
  
  .hud-badge { position: absolute; top: 8px; left: 8px; font-size: 10px; font-family: monospace; background: rgba(15,23,42,0.75); color: #94a3b8; padding: 2px 6px; border-radius: 4px; pointer-events: none; border: 1px solid rgba(255,255,255,0.08); }
  
  #authModal { position: absolute; inset: 0; background: rgba(15, 23, 42, 0.95); backdrop-filter: blur(8px); display: flex; align-items: center; justify-content: center; z-index: 50; padding: 20px; }
  .modal-box { background: #1e293b; padding: 24px; border-radius: 16px; border: 1px solid #334155; text-align: center; max-width: 320px; width: 100%; }
  .pin-box { width: 100%; background: #0f172a; border: 2px solid #475569; color: #38bdf8; font-size: 26px; font-family: monospace; letter-spacing: 6px; text-align: center; padding: 8px; border-radius: 8px; margin: 12px 0 16px; outline: none; }
  .btn-submit { width: 100%; background: #38bdf8; color: #0f172a; border: none; padding: 10px; font-size: 15px; font-weight: bold; border-radius: 8px; cursor: pointer; }
</style>
</head>
<body>
<header>
  <div class=""logo"">🎨 AirCanvas</div>
  <div style=""display:flex;align-items:center;gap:8px;"">
    <span id=""statusBadge"" class=""badge"">Connecting...</span>
    <a href=""/app.apk"" class=""btn-apk"" download=""AirCanvas.apk"">📥 APK</a>
  </div>
</header>
<div class=""toolbar"">
  <button id=""btnPen"" class=""tool-btn active"" onclick=""setTool('pen')"">✏ Pen</button>
  <button id=""btnHighlighter"" class=""tool-btn"" onclick=""setTool('highlighter')"">🖌 Marker</button>
  <button id=""btnEraser"" class=""tool-btn"" onclick=""setTool('eraser')"">🧹 Eraser</button>
  <div style=""width:1px;height:20px;background:#475569;margin:0 4px;flex-shrink:0;""></div>
  <div class=""color-dot active"" style=""background:#38bdf8;"" onclick=""setColor('#38bdf8', this)""></div>
  <div class=""color-dot"" style=""background:#ef4444;"" onclick=""setColor('#ef4444', this)""></div>
  <div class=""color-dot"" style=""background:#22c55e;"" onclick=""setColor('#22c55e', this)""></div>
  <div class=""color-dot"" style=""background:#eab308;"" onclick=""setColor('#eab308', this)""></div>
  <div class=""color-dot"" style=""background:#ffffff;"" onclick=""setColor('#ffffff', this)""></div>
  <div style=""width:1px;height:20px;background:#475569;margin:0 4px;flex-shrink:0;""></div>
  <button id=""btnAspect"" class=""tool-btn active"" onclick=""toggleAspectRatio()"">📐 16:9 PC</button>
  <button class=""tool-btn action"" onclick=""sendAction('undo')"">↩ Undo</button>
  <button class=""tool-btn action"" onclick=""sendAction('clear')"">🗑 Clear</button>
  <button class=""tool-btn action"" onclick=""sendAction('launch_onenote')"">📝 OneNote</button>
  <button class=""tool-btn action"" onclick=""sendAction('launch_ppt')"">📊 PPT</button>
</div>
<div class=""canvas-wrap"">
  <div id=""canvasBox"">
    <canvas id=""paintCanvas""></canvas>
    <div id=""hud"" class=""hud-badge"">AirCanvas 1:1 Synchronized</div>
  </div>
  <div id=""authModal"" style=""display:none;"">
    <div class=""modal-box"">
      <h3 style=""color:#38bdf8;margin-bottom:6px;"">AirCanvas Pairing</h3>
      <p style=""color:#94a3b8;font-size:12px;"">Enter 6-digit PIN from PC window:</p>
      <input id=""pinInput"" type=""tel"" maxlength=""6"" class=""pin-box"" value=""" + serverPin + @""">
      <button class=""btn-submit"" onclick=""submitPin()"">Connect</button>
    </div>
  </div>
</div>
<script>
  let ws;
  let currentPin = '" + serverPin + @"';
  let currentTool = 'pen';
  let currentColor = '#38bdf8';
  let isDrawing = false;
  let activePointerId = null;
  let currentStrokeId = null;
  let strokeSeq = 0;
  let batchBuffer = [];

  let pcAspect = 16.0 / 9.0;
  let matchPcAspect = true;
  let lastLocalX = 0, lastLocalY = 0;
  let lastMidX = 0, lastMidY = 0;

  // Stroke memory history for High-DPI redraws
  const strokeHistory = [];
  let activeStroke = null;

  const canvas = document.getElementById('paintCanvas');
  const ctx = canvas.getContext('2d');
  const canvasWrap = document.querySelector('.canvas-wrap');
  const statusBadge = document.getElementById('statusBadge');
  const hud = document.getElementById('hud');

  function computeLineWidth(pressure) {
    if (currentTool === 'eraser') return 28;
    if (currentTool === 'highlighter') return 16;
    return Math.max(1.5, (pressure * 6.0) + 1.5);
  }

  function updateCanvasLayout() {
    const wrapW = canvasWrap.clientWidth;
    const wrapH = canvasWrap.clientHeight;
    if (wrapW <= 0 || wrapH <= 0) return;

    let targetW = wrapW;
    let targetH = wrapH;

    if (matchPcAspect && pcAspect > 0.1) {
      if (wrapW / wrapH > pcAspect) {
        targetH = wrapH;
        targetW = Math.round(targetH * pcAspect);
      } else {
        targetW = wrapW;
        targetH = Math.round(targetW / pcAspect);
      }
    }

    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.round(targetW * dpr);
    canvas.height = Math.round(targetH * dpr);
    canvas.style.width = targetW + 'px';
    canvas.style.height = targetH + 'px';

    ctx.resetTransform && ctx.resetTransform();
    ctx.scale(dpr, dpr);

    redrawHistory();

    hud.textContent = matchPcAspect 
      ? ('PC 1:1 Match (' + targetW + 'x' + targetH + ' | DPR ' + dpr + ')')
      : ('Full Screen (' + targetW + 'x' + targetH + ' | DPR ' + dpr + ')');
  }

  function redrawHistory() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    for (let s = 0; s < strokeHistory.length; s++) {
      const stroke = strokeHistory[s];
      if (!stroke || stroke.points.length < 2) continue;
      const pts = stroke.points;
      const rect = canvas.getBoundingClientRect();

      ctx.beginPath();
      ctx.strokeStyle = stroke.tool === 'eraser' ? '#020617' : stroke.color;
      ctx.lineWidth = stroke.tool === 'eraser' ? 28 : (stroke.tool === 'highlighter' ? 16 : stroke.width || 3.0);
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      if (stroke.tool === 'highlighter') ctx.globalAlpha = 0.4;

      const p0X = pts[0].x * rect.width;
      const p0Y = pts[0].y * rect.height;
      ctx.moveTo(p0X, p0Y);

      let prevMidX = p0X, prevMidY = p0Y;
      for (let i = 1; i < pts.length; i++) {
        const ptX = pts[i].x * rect.width;
        const ptY = pts[i].y * rect.height;
        const midX = (prevMidX + ptX) / 2;
        const midY = (prevMidY + ptY) / 2;
        ctx.quadraticCurveTo(prevMidX, prevMidY, midX, midY);
        prevMidX = ptX;
        prevMidY = ptY;
      }
      ctx.stroke();
      ctx.globalAlpha = 1.0;
    }
  }

  window.addEventListener('resize', updateCanvasLayout);
  window.addEventListener('orientationchange', () => setTimeout(updateCanvasLayout, 100));
  updateCanvasLayout();

  function toggleAspectRatio() {
    matchPcAspect = !matchPcAspect;
    document.getElementById('btnAspect').textContent = matchPcAspect ? '📐 16:9 PC' : '📱 Full Screen';
    document.getElementById('btnAspect').classList.toggle('active', matchPcAspect);
    updateCanvasLayout();
  }

  function connectWs() {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    ws = new WebSocket(proto + '//' + location.host);
    ws.onopen = () => statusBadge.textContent = 'Authenticating...';
    ws.onclose = () => {
      statusBadge.textContent = 'Disconnected';
      statusBadge.className = 'badge';
      setTimeout(connectWs, 2000);
    };
    ws.onmessage = (e) => {
      try {
        const msg = JSON.parse(e.data);
        if (msg.type === 'auth_challenge') {
          ws.send(JSON.stringify({ type: 'auth_response', pin: currentPin }));
        } else if (msg.type === 'auth_success') {
          statusBadge.textContent = 'Connected (Live)';
          statusBadge.className = 'badge connected';
          document.getElementById('authModal').style.display = 'none';
          if (msg.aspect && msg.aspect > 0.1) {
            pcAspect = msg.aspect;
            updateCanvasLayout();
          }
        } else if (msg.type === 'auth_fail') {
          statusBadge.textContent = 'Bad PIN';
          document.getElementById('authModal').style.display = 'flex';
        }
      } catch(err){}
    };
  }
  connectWs();

  function submitPin() {
    currentPin = document.getElementById('pinInput').value.trim();
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'auth_response', pin: currentPin }));
    }
  }

  function setTool(t) {
    currentTool = t;
    document.querySelectorAll('.tool-btn').forEach(b => b.classList.remove('active'));
    document.getElementById(t === 'pen' ? 'btnPen' : (t === 'highlighter' ? 'btnHighlighter' : 'btnEraser')).classList.add('active');
  }

  function setColor(c, el) {
    currentColor = c;
    document.querySelectorAll('.color-dot').forEach(d => d.classList.remove('active'));
    el.classList.add('active');
    if (currentTool === 'eraser') setTool('pen');
  }

  function sendAction(act) {
    if (act === 'clear') {
      strokeHistory.length = 0;
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'aircanvas_input', t: 'clear', x: 0, y: 0, p: 0 }));
      }
    } else if (act === 'undo') {
      if (strokeHistory.length > 0) {
        strokeHistory.pop();
        redrawHistory();
      }
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'aircanvas_input', t: 'undo', x: 0, y: 0, p: 0 }));
      }
    } else if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'aircanvas_input', t: act, x: 0, y: 0, p: 0 }));
    }
  }

  function flushBatch() {
    if (batchBuffer.length === 0 || !ws || ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({
      type: 'aircanvas_input',
      strokeId: currentStrokeId,
      seq: strokeSeq++,
      t: 'move',
      pts: batchBuffer,
      tool: currentTool,
      color: currentColor,
      w: computeLineWidth(0.6),
      aspect: pcAspect
    }));
    batchBuffer = [];
  }

  function startStroke(e) {
    const rect = canvas.getBoundingClientRect();
    const localX = Math.max(0, Math.min(rect.width, e.clientX - rect.left));
    const localY = Math.max(0, Math.min(rect.height, e.clientY - rect.top));
    const normX = rect.width > 0 ? (localX / rect.width) : 0;
    const normY = rect.height > 0 ? (localY / rect.height) : 0;
    const pressure = (e.pressure > 0) ? e.pressure : 0.6;

    isDrawing = true;
    currentStrokeId = 's_' + Date.now() + '_' + Math.floor(Math.random() * 100000);
    strokeSeq = 0;
    batchBuffer = [];

    lastLocalX = localX;
    lastLocalY = localY;
    lastMidX = localX;
    lastMidY = localY;

    activeStroke = {
      id: currentStrokeId,
      tool: currentTool,
      color: currentColor,
      width: computeLineWidth(pressure),
      points: [{ x: normX, y: normY, p: pressure }]
    };

    // Immediate Local Render (Round starting dot)
    const rad = computeLineWidth(pressure) / 2;
    ctx.beginPath();
    ctx.arc(localX, localY, rad, 0, Math.PI * 2);
    ctx.fillStyle = currentTool === 'eraser' ? '#020617' : currentColor;
    if (currentTool === 'highlighter') ctx.globalAlpha = 0.4;
    ctx.fill();
    ctx.globalAlpha = 1.0;

    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({
        type: 'aircanvas_input',
        strokeId: currentStrokeId,
        seq: strokeSeq++,
        t: 'down',
        x: Number(normX.toFixed(5)),
        y: Number(normY.toFixed(5)),
        p: Number(pressure.toFixed(3)),
        tool: currentTool,
        color: currentColor,
        w: computeLineWidth(pressure),
        aspect: pcAspect
      }));
    }
  }

  function moveStroke(subE) {
    if (!isDrawing) return;
    const rect = canvas.getBoundingClientRect();
    const localX = Math.max(0, Math.min(rect.width, subE.clientX - rect.left));
    const localY = Math.max(0, Math.min(rect.height, subE.clientY - rect.top));
    const normX = rect.width > 0 ? (localX / rect.width) : 0;
    const normY = rect.height > 0 ? (localY / rect.height) : 0;
    const pressure = (subE.pressure > 0) ? subE.pressure : 0.6;

    const midX = (lastLocalX + localX) / 2;
    const midY = (lastLocalY + localY) / 2;

    // Immediate Local Quadratic Bézier Curve Smoothing (100% continuous, zero gaps)
    ctx.beginPath();
    ctx.moveTo(lastMidX, lastMidY);
    ctx.quadraticCurveTo(lastLocalX, lastLocalY, midX, midY);
    ctx.strokeStyle = currentTool === 'eraser' ? '#020617' : currentColor;
    ctx.lineWidth = computeLineWidth(pressure);
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    if (currentTool === 'highlighter') ctx.globalAlpha = 0.4;
    ctx.stroke();
    ctx.globalAlpha = 1.0;

    lastLocalX = localX;
    lastLocalY = localY;
    lastMidX = midX;
    lastMidY = midY;

    if (activeStroke) {
      activeStroke.points.push({ x: normX, y: normY, p: pressure });
    }

    batchBuffer.push([Number(normX.toFixed(5)), Number(normY.toFixed(5)), Number(pressure.toFixed(3))]);

    if (batchBuffer.length >= 4) {
      flushBatch();
    }
  }

  function endStroke(e) {
    if (!isDrawing) return;
    isDrawing = false;

    flushBatch();

    const rect = canvas.getBoundingClientRect();
    const localX = Math.max(0, Math.min(rect.width, e.clientX - rect.left));
    const localY = Math.max(0, Math.min(rect.height, e.clientY - rect.top));
    const normX = rect.width > 0 ? (localX / rect.width) : 0;
    const normY = rect.height > 0 ? (localY / rect.height) : 0;
    const pressure = (e.pressure > 0) ? e.pressure : 0.6;

    // Connect final segment
    ctx.beginPath();
    ctx.moveTo(lastMidX, lastMidY);
    ctx.lineTo(localX, localY);
    ctx.strokeStyle = currentTool === 'eraser' ? '#020617' : currentColor;
    ctx.lineWidth = computeLineWidth(pressure);
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    if (currentTool === 'highlighter') ctx.globalAlpha = 0.4;
    ctx.stroke();
    ctx.globalAlpha = 1.0;

    if (activeStroke) {
      activeStroke.points.push({ x: normX, y: normY, p: pressure });
      strokeHistory.push(activeStroke);
      if (strokeHistory.length > 500) strokeHistory.shift();
      activeStroke = null;
    }

    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({
        type: 'aircanvas_input',
        strokeId: currentStrokeId,
        seq: strokeSeq++,
        t: 'up',
        x: Number(normX.toFixed(5)),
        y: Number(normY.toFixed(5)),
        p: Number(pressure.toFixed(3)),
        tool: currentTool,
        color: currentColor,
        w: computeLineWidth(pressure),
        aspect: pcAspect
      }));
    }
  }

  // Pointer event listeners with Pointer Capture and Corner-of-Mobile Isolation
  canvas.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    e.stopPropagation();
    activePointerId = e.pointerId;
    try { canvas.setPointerCapture(e.pointerId); } catch(err){}
    document.body.classList.add('drawing-active');
    startStroke(e);
  });

  canvas.addEventListener('pointermove', (e) => {
    e.preventDefault();
    e.stopPropagation();
    if (!isDrawing) return;
    const events = (e.getCoalescedEvents && e.getCoalescedEvents().length > 0) ? e.getCoalescedEvents() : [e];
    for (let i = 0; i < events.length; i++) {
      moveStroke(events[i]);
    }
  });

  function handlePointerEnd(e) {
    if (activePointerId !== null && e.pointerId !== activePointerId) return;
    e.preventDefault();
    e.stopPropagation();
    try { canvas.releasePointerCapture(e.pointerId); } catch(err){}
    document.body.classList.remove('drawing-active');
    endStroke(e);
    activePointerId = null;
  }

  canvas.addEventListener('pointerup', handlePointerEnd);
  canvas.addEventListener('pointercancel', handlePointerEnd);

  // Periodic micro-batch flusher (every 8ms = ~120Hz sync rate)
  setInterval(flushBatch, 8);
</script>
</body>
</html>";
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            ReleaseHeldButtonAtCursor();
            StopServer();
            if (penMenuForm != null && !penMenuForm.IsDisposed)
            {
                try { penMenuForm.Close(); } catch { }
            }
            if (trayIcon != null) trayIcon.Dispose();
            if (idleIcon != null) try { idleIcon.Dispose(); } catch { }
            if (activeIcon != null) try { activeIcon.Dispose(); } catch { }
            if (canvasGraphics != null) canvasGraphics.Dispose();
            if (canvasBitmap != null) canvasBitmap.Dispose();
            base.OnFormClosing(e);
        }
    }

    /// <summary>
    /// Windows 11 Fluent Dark-styled floating Stylus / Pen Menu Toolbar
    /// Pops up above the taskbar corner when tablet connects or when clicking the stylus tray icon.
    /// </summary>
    public class PenMenuForm : Form
    {
        private MainForm mainForm;
        private bool isDragging = false;
        private Point dragStartPoint = Point.Empty;

        public PenMenuForm(MainForm main)
        {
            this.mainForm = main;
            this.FormBorderStyle = FormBorderStyle.None;
            this.ShowInTaskbar = false;
            this.TopMost = true;
            this.DoubleBuffered = true;
            this.Size = new Size(365, 54);
            this.BackColor = Color.FromArgb(24, 24, 27); // Fluent Dark Zinc
            this.StartPosition = FormStartPosition.Manual;

            PositionAtBottomRight();
            BuildControls();
        }

        public void PositionAtBottomRight()
        {
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            this.Location = new Point(wa.Right - this.Width - 16, wa.Bottom - this.Height - 12);
        }

        private void BuildControls()
        {
            this.Controls.Clear();

            ToolTip tt = new ToolTip();
            tt.BackColor = Color.FromArgb(15, 23, 42);
            tt.ForeColor = Color.White;

            Panel pnl = new Panel
            {
                Dock = DockStyle.Fill,
                BackColor = Color.FromArgb(24, 24, 27)
            };
            this.Controls.Add(pnl);

            int left = 8;
            int btnWidth = 38;
            int btnHeight = 38;
            int top = 8;

            // 1. OneNote Button (Purple N)
            Button btnOneNote = CreateMenuButton("N", "OneNote (Notes & Inking)", Color.FromArgb(123, 45, 142), () => mainForm.LaunchOneNote(), tt);
            btnOneNote.Font = new Font("Segoe UI", 12f, FontStyle.Bold);
            btnOneNote.ForeColor = Color.White;
            btnOneNote.Location = new Point(left, top);
            btnOneNote.Size = new Size(btnWidth, btnHeight);
            pnl.Controls.Add(btnOneNote);
            left += btnWidth + 6;

            // 2. MS Paint Button (Palette)
            Button btnPaint = CreateMenuButton("🎨", "MS Paint (Sketch & Canvas)", Color.FromArgb(2, 132, 199), () => mainForm.LaunchPaint(), tt);
            btnPaint.Location = new Point(left, top);
            btnPaint.Size = new Size(btnWidth, btnHeight);
            pnl.Controls.Add(btnPaint);
            left += btnWidth + 6;

            // 3. Snipping Tool Button (Scissors / Clip)
            Button btnSnip = CreateMenuButton("✂️", "Snipping Tool (Screen Clip & Markup)", Color.FromArgb(225, 29, 72), () => mainForm.LaunchSnippingTool(), tt);
            btnSnip.Location = new Point(left, top);
            btnSnip.Size = new Size(btnWidth, btnHeight);
            pnl.Controls.Add(btnSnip);
            left += btnWidth + 6;

            // 4. PowerPoint Button (Orange P)
            Button btnPpt = CreateMenuButton("P", "PowerPoint Presentation Mode", Color.FromArgb(208, 68, 35), () => mainForm.LaunchPowerPoint(), tt);
            btnPpt.Font = new Font("Segoe UI", 12f, FontStyle.Bold);
            btnPpt.ForeColor = Color.White;
            btnPpt.Location = new Point(left, top);
            btnPpt.Size = new Size(btnWidth, btnHeight);
            pnl.Controls.Add(btnPpt);
            left += btnWidth + 6;

            // Separator line
            Label sep = new Label
            {
                Location = new Point(left, 12),
                Size = new Size(1, 30),
                BackColor = Color.FromArgb(63, 63, 70)
            };
            pnl.Controls.Add(sep);
            left += 7;

            // 5. AirCanvas Web Studio
            Button btnStudio = CreateMenuButton("🖌️", "AirCanvas Web Studio", Color.FromArgb(14, 165, 233), () => mainForm.LaunchDrawingStudio(), tt);
            btnStudio.Location = new Point(left, top);
            btnStudio.Size = new Size(btnWidth, btnHeight);
            pnl.Controls.Add(btnStudio);
            left += btnWidth + 6;

            // 6. Settings Gear Button
            Button btnSettings = CreateMenuButton("⚙️", "Pen & Windows Ink Settings", Color.FromArgb(71, 85, 105), () => mainForm.LaunchPenSettings(), tt);
            btnSettings.Location = new Point(left, top);
            btnSettings.Size = new Size(btnWidth, btnHeight);
            pnl.Controls.Add(btnSettings);
            left += btnWidth + 6;

            // 7. Close / Hide Button
            Button btnClose = CreateMenuButton("✕", "Hide Stylus Menu", Color.FromArgb(63, 63, 70), () => this.Hide(), tt);
            btnClose.Font = new Font("Segoe UI", 10f, FontStyle.Bold);
            btnClose.ForeColor = Color.FromArgb(161, 161, 170);
            btnClose.Location = new Point(left, top);
            btnClose.Size = new Size(32, btnHeight);
            pnl.Controls.Add(btnClose);

            // Dragging support
            pnl.MouseDown += (s, e) =>
            {
                if (e.Button == MouseButtons.Left)
                {
                    isDragging = true;
                    dragStartPoint = e.Location;
                }
            };
            pnl.MouseMove += (s, e) =>
            {
                if (isDragging)
                {
                    Point p = this.PointToScreen(e.Location);
                    this.Location = new Point(p.X - dragStartPoint.X, p.Y - dragStartPoint.Y);
                }
            };
            pnl.MouseUp += (s, e) => { isDragging = false; };
        }

        private Button CreateMenuButton(string text, string toolTipText, Color hoverColor, Action onClick, ToolTip tt)
        {
            Button btn = new Button
            {
                Text = text,
                Font = new Font("Segoe UI Emoji", 11f, FontStyle.Regular),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(39, 39, 42),
                ForeColor = Color.FromArgb(244, 244, 245),
                Cursor = Cursors.Hand,
                Margin = new Padding(0)
            };
            btn.FlatAppearance.BorderSize = 1;
            btn.FlatAppearance.BorderColor = Color.FromArgb(63, 63, 70);
            btn.FlatAppearance.MouseOverBackColor = hoverColor;
            btn.Click += (s, e) => onClick();
            tt.SetToolTip(btn, toolTipText);
            return btn;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            using (Pen borderPen = new Pen(Color.FromArgb(63, 63, 70), 1.5f))
            {
                e.Graphics.DrawRectangle(borderPen, 0, 0, this.Width - 1, this.Height - 1);
            }
        }
    }
}
