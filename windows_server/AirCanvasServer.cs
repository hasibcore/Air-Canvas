using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace AirCanvas
{
    public class Program
    {
        [STAThread]
        public static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
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
        private Button btnToggleServer;
        private Button btnTestInput;
        private Button btnAllowFirewall;
        private Button btnClearCanvas;
        private CheckBox chkEnableInjection;
        private Panel pnlHeader;
        private Panel pnlCard;
        private PictureBox pbCanvas;
        private Bitmap canvasBitmap;
        private Graphics canvasGraphics;
        private PointF lastDrawPoint = PointF.Empty;
        private NotifyIcon trayIcon;

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
        private byte[] sessionKeyBytes = null;
        private string lastClientPin = "1234";

        // Win32 Native Input Injection
        [DllImport("user32.dll")]
        private static extern bool SetCursorPos(int X, int Y);

        [DllImport("user32.dll")]
        private static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, int dwExtraInfo);

        private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
        private const uint MOUSEEVENTF_MOVE = 0x0001;
        private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        private const uint MOUSEEVENTF_LEFTUP = 0x0004;
        private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
        private const uint MOUSEEVENTF_RIGHTUP = 0x0010;

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
            this.Size = new Size(820, 600);
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
                Text = "● Server Starting...",
                Font = new Font("Segoe UI", 9.5f, FontStyle.Regular),
                ForeColor = Color.FromArgb(234, 179, 8), // Yellow
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
                Size = new Size(340, 455),
                BackColor = Color.FromArgb(30, 41, 59)
            };

            lblIp = new Label
            {
                Text = "🌐 Server IP: Detecting...",
                Font = new Font("Segoe UI", 10.5f, FontStyle.Bold),
                ForeColor = Color.FromArgb(248, 250, 252),
                Location = new Point(15, 15),
                AutoSize = true
            };

            lblPort = new Label
            {
                Text = "🔌 Port: 9090 | Discovery: 9091",
                Font = new Font("Segoe UI", 9f, FontStyle.Regular),
                ForeColor = Color.FromArgb(148, 163, 184),
                Location = new Point(15, 42),
                AutoSize = true
            };

            lblClients = new Label
            {
                Text = "📱 Connected: 0",
                Font = new Font("Segoe UI", 10.5f, FontStyle.Bold),
                ForeColor = Color.FromArgb(74, 222, 128), // Green 400
                Location = new Point(15, 72),
                AutoSize = true
            };

            lblPackets = new Label
            {
                Text = "⚡ Packets Processed: 0",
                Font = new Font("Segoe UI", 9f, FontStyle.Regular),
                ForeColor = Color.FromArgb(148, 163, 184),
                Location = new Point(15, 100),
                AutoSize = true
            };

            chkEnableInjection = new CheckBox
            {
                Text = "Inject Cursor to Photoshop/Krita/Paint",
                Font = new Font("Segoe UI", 8.5f, FontStyle.Regular),
                ForeColor = Color.FromArgb(226, 232, 240),
                Location = new Point(15, 130),
                Size = new Size(310, 25),
                Checked = true
            };

            btnTestInput = new Button
            {
                Text = "🧪 Test Stroke",
                Font = new Font("Segoe UI", 8.5f, FontStyle.Regular),
                Location = new Point(15, 165),
                Size = new Size(145, 32),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(51, 65, 85),
                ForeColor = Color.White
            };
            btnTestInput.Click += (s, e) => TestStroke();

            btnClearCanvas = new Button
            {
                Text = "🗑 Clear Canvas",
                Font = new Font("Segoe UI", 8.5f, FontStyle.Regular),
                Location = new Point(170, 165),
                Size = new Size(150, 32),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(71, 85, 105),
                ForeColor = Color.White
            };
            btnClearCanvas.Click += (s, e) => ClearCanvas();

            btnAllowFirewall = new Button
            {
                Text = "🔓 Allow Firewall (Fix Connection)",
                Font = new Font("Segoe UI", 9f, FontStyle.Bold),
                Location = new Point(15, 210),
                Size = new Size(305, 36),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(16, 185, 129), // Emerald 500
                ForeColor = Color.White
            };
            btnAllowFirewall.Click += (s, e) => FixFirewallRules();

            btnToggleServer = new Button
            {
                Text = "⏹ Stop Server",
                Font = new Font("Segoe UI", 10.5f, FontStyle.Bold),
                Location = new Point(15, 395),
                Size = new Size(305, 42),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(239, 68, 68), // Red
                ForeColor = Color.White
            };
            btnToggleServer.Click += (s, e) =>
            {
                if (isRunning) StopServer();
                else StartServer();
            };

            pnlCard.Controls.Add(lblIp);
            pnlCard.Controls.Add(lblPort);
            pnlCard.Controls.Add(lblClients);
            pnlCard.Controls.Add(lblPackets);
            pnlCard.Controls.Add(chkEnableInjection);
            pnlCard.Controls.Add(btnTestInput);
            pnlCard.Controls.Add(btnClearCanvas);
            pnlCard.Controls.Add(btnAllowFirewall);
            pnlCard.Controls.Add(btnToggleServer);
            this.Controls.Add(pnlCard);

            // Right Panel: Live Drawing Canvas PictureBox
            pbCanvas = new PictureBox
            {
                Location = new Point(370, 88),
                Size = new Size(420, 455),
                BackColor = Color.FromArgb(15, 23, 42),
                BorderStyle = BorderStyle.FixedSingle
            };
            this.Controls.Add(pbCanvas);

            // Tray Icon
            trayIcon = new NotifyIcon
            {
                Text = "AirCanvas Server",
                Icon = SystemIcons.Application,
                Visible = true
            };
            trayIcon.DoubleClick += (s, e) =>
            {
                this.Show();
                this.WindowState = FormWindowState.Normal;
            };
        }

        private void InitCanvas()
        {
            canvasBitmap = new Bitmap(pbCanvas.Width, pbCanvas.Height);
            canvasGraphics = Graphics.FromImage(canvasBitmap);
            canvasGraphics.SmoothingMode = SmoothingMode.AntiAlias;
            ClearCanvas();
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
            }
        }

        private void InjectAndDrawInput(double x, double y, double pressure, string eventType)
        {
            // Clamp normalized coords
            x = Math.Max(0.0, Math.Min(1.0, x));
            y = Math.Max(0.0, Math.Min(1.0, y));
            pressure = Math.Max(0.0, Math.Min(1.0, pressure));

            // 1. Draw live on in-app PC Canvas
            DrawOnAppCanvas(x, y, pressure, eventType);

            // 2. Win32 Cursor injection for Photoshop/Krita/Paint
            if (chkEnableInjection.Checked)
            {
                try
                {
                    Rectangle screen = Screen.PrimaryScreen.Bounds;
                    int targetX = (int)(x * (screen.Width - 1));
                    int targetY = (int)(y * (screen.Height - 1));

                    SetCursorPos(targetX, targetY);

                    if (eventType.Equals("down", StringComparison.OrdinalIgnoreCase))
                    {
                        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
                    }
                    else if (eventType.Equals("move", StringComparison.OrdinalIgnoreCase))
                    {
                        mouse_event(MOUSEEVENTF_MOVE, 0, 0, 0, 0);
                    }
                    else if (eventType.Equals("up", StringComparison.OrdinalIgnoreCase) || eventType.Equals("cancel", StringComparison.OrdinalIgnoreCase))
                    {
                        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
                    }
                }
                catch { }
            }
        }

        private void DrawOnAppCanvas(double x, double y, double pressure, string eventType)
        {
            if (this.IsDisposed || !this.IsHandleCreated || canvasGraphics == null) return;

            this.BeginInvoke((Action)(() =>
            {
                try
                {
                    float canvasX = (float)(x * pbCanvas.Width);
                    float canvasY = (float)(y * pbCanvas.Height);
                    PointF currentPt = new PointF(canvasX, canvasY);

                    float penWidth = Math.Max(2.5f, (float)(pressure * 9.0f));

                    if (eventType.Equals("down", StringComparison.OrdinalIgnoreCase))
                    {
                        if (!hasDrawnOnCanvas)
                        {
                            canvasGraphics.Clear(Color.FromArgb(15, 23, 42));
                            hasDrawnOnCanvas = true;
                        }
                        lastDrawPoint = currentPt;
                        using (Brush brush = new SolidBrush(Color.FromArgb(56, 189, 248))) // Sky 400
                        {
                            canvasGraphics.FillEllipse(brush, currentPt.X - penWidth / 2, currentPt.Y - penWidth / 2, penWidth, penWidth);
                        }
                    }
                    else if (eventType.Equals("move", StringComparison.OrdinalIgnoreCase))
                    {
                        if (!lastDrawPoint.IsEmpty)
                        {
                            using (Pen pen = new Pen(Color.FromArgb(56, 189, 248), penWidth))
                            {
                                pen.StartCap = LineCap.Round;
                                pen.EndCap = LineCap.Round;
                                pen.LineJoin = LineJoin.Round;
                                canvasGraphics.DrawLine(pen, lastDrawPoint, currentPt);
                            }
                        }
                        lastDrawPoint = currentPt;
                    }
                    else if (eventType.Equals("up", StringComparison.OrdinalIgnoreCase) || eventType.Equals("cancel", StringComparison.OrdinalIgnoreCase))
                    {
                        lastDrawPoint = PointF.Empty;
                    }

                    pbCanvas.Invalidate();
                }
                catch { }
            }));
        }

        private void GetLocalIPAddress()
        {
            try
            {
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
            lblIp.Text = "🌐 Server IP: " + localIp;
        }

        private void StartServer()
        {
            if (isRunning) return;
            try
            {
                cts = new CancellationTokenSource();

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
            }
            catch (Exception ex)
            {
                lblStatus.Text = "✕ Server Error: " + ex.Message;
                lblStatus.ForeColor = Color.FromArgb(239, 68, 68);
                isRunning = false;
            }
        }

        private void StopServer()
        {
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
            try
            {
                client.NoDelay = true; // Sub-5ms low latency
                stream = client.GetStream();

                // 1. WebSocket Handshake
                byte[] handshakeBuffer = new byte[4096];
                int bytesRead = await stream.ReadAsync(handshakeBuffer, 0, handshakeBuffer.Length, token);
                if (bytesRead == 0) return;

                string headerText = Encoding.UTF8.GetString(handshakeBuffer, 0, bytesRead);
                if (!PerformWebSocketHandshake(headerText, stream))
                {
                    return;
                }

                // 2. Send Auth Challenge frame immediately
                SendWebSocketText(stream, "{\"type\":\"auth_challenge\"}");

                // 3. Read incoming WebSocket frames
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
                        ProcessJsonMessage(json, stream);
                    }
                    else if (frame.Opcode == 2) // Binary Input Event or Encrypted Payload
                    {
                        ProcessBinaryPacket(frame.Payload, frame.Payload.Length, stream);
                    }

                    Interlocked.Increment(ref packetsReceived);
                    if (packetsReceived % 10 == 0)
                    {
                        UpdatePacketsUI();
                    }
                }
            }
            catch { }
            finally
            {
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
                if (keyIdx == -1) return false;

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

        private byte[] Crypt(byte[] data, byte[] key)
        {
            if (key == null || key.Length == 0 || data == null) return data;
            byte[] result = new byte[data.Length];
            for (int i = 0; i < data.Length; i++)
            {
                result[i] = (byte)(data[i] ^ key[i % key.Length]);
            }
            return result;
        }

        private void ProcessJsonMessage(string json, NetworkStream stream)
        {
            // Authenticate handshake response
            if (json.Contains("\"type\":\"auth_response\"") || json.Contains("\"type\":\"auth\""))
            {
                try
                {
                    int pIdx = json.IndexOf("\"pin\":");
                    if (pIdx != -1)
                    {
                        int start = json.IndexOf('"', pIdx + 6) + 1;
                        int end = json.IndexOf('"', start);
                        if (start > 0 && end > start)
                        {
                            lastClientPin = json.Substring(start, end - start);
                        }
                    }
                }
                catch { }

                sessionKeyBytes = Encoding.UTF8.GetBytes(lastClientPin != null ? lastClientPin : "1234");
                string b64Key = Convert.ToBase64String(sessionKeyBytes);

                SendWebSocketText(stream, "{\"type\":\"auth_success\",\"session_key\":\"" + b64Key + "\"}");
            }
            else if (json.Contains("\"type\":\"device_info\""))
            {
                // Key must be "binary" to match Flutter's ServerConfig.fromJson()
                SendWebSocketText(stream, "{\"type\":\"server_config\",\"data\":{\"port\":9090,\"binary\":true}}");
            }
            else if (json.Contains("\"type\":\"aircanvas_input\"") || json.Contains("\"type\":\"input\"") || json.Contains("\"type\":\"input_event\""))
            {
                ParseJsonInputEvent(json);
            }
            else if (json.Contains("\"type\":\"ping\""))
            {
                SendWebSocketText(stream, "{\"type\":\"pong\",\"ts\":" + DateTime.Now.Ticks + "}");
            }
        }

        private void ParseJsonInputEvent(string json)
        {
            try
            {
                double x = 0, y = 0, pressure = 0.5;
                string eventType = "move";

                // Format: t/type, x, y, p/pressure
                int tIdx = json.IndexOf("\"t\":");
                if (tIdx == -1) tIdx = json.IndexOf("\"type\":");
                if (tIdx != -1)
                {
                    int start = json.IndexOf('"', tIdx + 4) + 1;
                    int end = json.IndexOf('"', start);
                    if (start > 0 && end > start)
                    {
                        eventType = json.Substring(start, end - start);
                    }
                }

                int xIdx = json.IndexOf("\"x\":");
                if (xIdx != -1)
                {
                    int end = json.IndexOfAny(new char[] { ',', '}' }, xIdx);
                    string val = json.Substring(xIdx + 4, end - (xIdx + 4)).Trim();
                    double.TryParse(val, out x);
                }

                int yIdx = json.IndexOf("\"y\":");
                if (yIdx != -1)
                {
                    int end = json.IndexOfAny(new char[] { ',', '}' }, yIdx);
                    string val = json.Substring(yIdx + 4, end - (yIdx + 4)).Trim();
                    double.TryParse(val, out y);
                }

                int pIdx = json.IndexOf("\"p\":");
                if (pIdx == -1) pIdx = json.IndexOf("\"pressure\":");
                if (pIdx != -1)
                {
                    int end = json.IndexOfAny(new char[] { ',', '}' }, pIdx);
                    string val = json.Substring(pIdx + (pIdx == json.IndexOf("\"p\":") ? 4 : 11), end - (pIdx + (pIdx == json.IndexOf("\"p\":") ? 4 : 11))).Trim();
                    double.TryParse(val, out pressure);
                }

                InjectAndDrawInput(x, y, pressure, eventType);
            }
            catch { }
        }

        private void ProcessBinaryPacket(byte[] data, int count, NetworkStream stream)
        {
            if (count < 1) return;
            try
            {
                byte[] packet = data;

                // Attempt decryption: encrypted packets won't start with a valid
                // event type (0-5) or JSON brace '{'. Try each key until one
                // produces recognizable output.
                bool isRecognizable = (packet[0] <= 5 && packet.Length == 13) || packet[0] == (byte)'{';
                if (!isRecognizable)
                {
                    byte[][] keysToTry = new byte[][] {
                        sessionKeyBytes,
                        lastClientPin != null ? Encoding.UTF8.GetBytes(lastClientPin) : null,
                        Encoding.UTF8.GetBytes("1234")
                    };
                    foreach (byte[] key in keysToTry)
                    {
                        if (key == null) continue;
                        byte[] dec = Crypt(packet, key);
                        if ((dec.Length == 13 && dec[0] <= 5) || (dec.Length > 0 && dec[0] == (byte)'{'))
                        {
                            packet = dec;
                            break;
                        }
                    }
                }

                // Route JSON messages (device_info, input in JSON mode, ping, etc.)
                if (packet[0] == (byte)'{')
                {
                    string json = Encoding.UTF8.GetString(packet);
                    ProcessJsonMessage(json, stream);
                    return;
                }

                // Validate as 13-byte binary input event
                if (packet[0] > 5 || packet.Length < 6) return;

                // Flutter InputEvent binary format:
                // [type:1][x:2][y:2][pressure:1][pointerType:1][pointerId:1][tiltX:1][tiltY:1][buttons:1][version:1][checksum:1]
                byte typeByte = packet[0];
                string eventType = "move";
                if (typeByte == 0) eventType = "down";
                else if (typeByte == 1) eventType = "move";
                else if (typeByte == 2) eventType = "up";
                else if (typeByte == 3) eventType = "cancel";

                // Big-endian uint16 / 65535.0 (normalized 0.0 to 1.0)
                int xUint = (packet[1] << 8) | packet[2];
                double x = (double)xUint / 65535.0;

                int yUint = (packet[3] << 8) | packet[4];
                double y = (double)yUint / 65535.0;

                double pressure = (double)packet[5] / 255.0;

                InjectAndDrawInput(x, y, pressure, eventType);
            }
            catch { }
        }

        private void RunUdpDiscoveryListener(CancellationToken token)
        {
            try
            {
                udpDiscoveryClient = new UdpClient(DiscoveryPort);
                while (!token.IsCancellationRequested)
                {
                    IPEndPoint remoteEp = new IPEndPoint(IPAddress.Any, 0);
                    byte[] data = udpDiscoveryClient.Receive(ref remoteEp);
                    string message = Encoding.UTF8.GetString(data);

                    if (message.Contains("aircanvas_discovery"))
                    {
                        string reply = "{\"type\":\"aircanvas_response\",\"name\":\"" + Environment.MachineName + "\",\"port\":" + ServerPort + ",\"ip\":\"" + localIp + "\"}";
                        byte[] replyBytes = Encoding.UTF8.GetBytes(reply);
                        udpDiscoveryClient.Send(replyBytes, replyBytes.Length, remoteEp);
                    }
                }
            }
            catch { }
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
            for (int i = 0; i <= 200; i += 5)
            {
                double normX = 0.2 + (i / 300.0);
                double normY = 0.5 + Math.Sin(i * 0.05) * 0.15;
                DrawOnAppCanvas(normX, normY, 0.8, i == 0 ? "down" : (i == 200 ? "up" : "move"));
                Thread.Sleep(10);
            }
        }

        private void UpdateClientsUI()
        {
            if (this.IsDisposed || !this.IsHandleCreated) return;
            this.BeginInvoke((Action)(() =>
            {
                lblClients.Text = "📱 Connected: " + connectedClients;
                lblClients.ForeColor = connectedClients > 0 ? Color.FromArgb(74, 222, 128) : Color.FromArgb(148, 163, 184);
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

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            StopServer();
            if (trayIcon != null) trayIcon.Dispose();
            if (canvasGraphics != null) canvasGraphics.Dispose();
            if (canvasBitmap != null) canvasBitmap.Dispose();
            base.OnFormClosing(e);
        }
    }
}
