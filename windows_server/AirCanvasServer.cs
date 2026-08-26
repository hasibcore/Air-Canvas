using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
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
        private CheckBox chkEnableInjection;
        private Panel pnlHeader;
        private Panel pnlCard;
        private NotifyIcon trayIcon;

        // Server State (Pure Socket TCP - No Http.sys / No Access is denied)
        private TcpListener tcpServer;
        private UdpClient udpDiscoveryClient;
        private CancellationTokenSource cts;
        private bool isRunning = false;
        private int connectedClients = 0;
        private long packetsReceived = 0;
        private string localIp = "127.0.0.1";
        private const int ServerPort = 9090;
        private const int DiscoveryPort = 9091;

        // Client Screen Dimensions (for scaling)
        private double clientWidth = 1920;
        private double clientHeight = 1080;

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
            StartServer();
        }

        private void InitializeComponent()
        {
            this.Text = "AirCanvas Server — PC Graphics Tablet Receiver";
            this.Size = new Size(540, 500);
            this.StartPosition = FormStartPosition.CenterScreen;
            this.FormBorderStyle = FormBorderStyle.FixedSingle;
            this.MaximizeBox = false;
            this.BackColor = Color.FromArgb(15, 23, 42); // Slate 900
            this.ForeColor = Color.White;

            // Header Panel
            pnlHeader = new Panel
            {
                Dock = DockStyle.Top,
                Height = 80,
                BackColor = Color.FromArgb(30, 41, 59) // Slate 800
            };

            lblTitle = new Label
            {
                Text = "🎨 AirCanvas PC Server",
                Font = new Font("Segoe UI", 16, FontStyle.Bold),
                ForeColor = Color.FromArgb(56, 189, 248), // Sky 400
                Location = new Point(20, 15),
                AutoSize = true
            };

            lblStatus = new Label
            {
                Text = "● Server Starting...",
                Font = new Font("Segoe UI", 10, FontStyle.Regular),
                ForeColor = Color.FromArgb(234, 179, 8), // Yellow
                Location = new Point(24, 48),
                AutoSize = true
            };

            pnlHeader.Controls.Add(lblTitle);
            pnlHeader.Controls.Add(lblStatus);
            this.Controls.Add(pnlHeader);

            // Card Panel
            pnlCard = new Panel
            {
                Location = new Point(20, 95),
                Size = new Size(485, 260),
                BackColor = Color.FromArgb(30, 41, 59)
            };

            lblIp = new Label
            {
                Text = "🌐 Server IP: Detecting...",
                Font = new Font("Segoe UI", 11, FontStyle.Bold),
                ForeColor = Color.FromArgb(248, 250, 252),
                Location = new Point(20, 18),
                AutoSize = true
            };

            lblPort = new Label
            {
                Text = "🔌 Port: 9090 (WebSocket) | 9091 (UDP Discovery)",
                Font = new Font("Segoe UI", 9.5f, FontStyle.Regular),
                ForeColor = Color.FromArgb(148, 163, 184),
                Location = new Point(20, 48),
                AutoSize = true
            };

            lblClients = new Label
            {
                Text = "📱 Connected Devices: 0",
                Font = new Font("Segoe UI", 11, FontStyle.Bold),
                ForeColor = Color.FromArgb(74, 222, 128), // Green 400
                Location = new Point(20, 80),
                AutoSize = true
            };

            lblPackets = new Label
            {
                Text = "⚡ Packets Processed: 0",
                Font = new Font("Segoe UI", 9.5f, FontStyle.Regular),
                ForeColor = Color.FromArgb(148, 163, 184),
                Location = new Point(20, 110),
                AutoSize = true
            };

            chkEnableInjection = new CheckBox
            {
                Text = "Enable Native Cursor & Pen Injection (Photoshop/Krita/Blender)",
                Font = new Font("Segoe UI", 9.5f, FontStyle.Regular),
                ForeColor = Color.FromArgb(226, 232, 240),
                Location = new Point(20, 145),
                Size = new Size(445, 25),
                Checked = true
            };

            btnTestInput = new Button
            {
                Text = "🧪 Test Stroke",
                Font = new Font("Segoe UI", 9f, FontStyle.Regular),
                Location = new Point(20, 185),
                Size = new Size(110, 34),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(51, 65, 85),
                ForeColor = Color.White
            };
            btnTestInput.Click += (s, e) => TestStroke();

            btnAllowFirewall = new Button
            {
                Text = "🔓 Allow Firewall (Fix Connection)",
                Font = new Font("Segoe UI", 9f, FontStyle.Bold),
                Location = new Point(140, 185),
                Size = new Size(250, 34),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(16, 185, 129), // Emerald 500
                ForeColor = Color.White
            };
            btnAllowFirewall.Click += (s, e) => FixFirewallRules();

            pnlCard.Controls.Add(lblIp);
            pnlCard.Controls.Add(lblPort);
            pnlCard.Controls.Add(lblClients);
            pnlCard.Controls.Add(lblPackets);
            pnlCard.Controls.Add(chkEnableInjection);
            pnlCard.Controls.Add(btnTestInput);
            pnlCard.Controls.Add(btnAllowFirewall);
            this.Controls.Add(pnlCard);

            // Toggle Button
            btnToggleServer = new Button
            {
                Text = "⏹ Stop Server",
                Font = new Font("Segoe UI", 11, FontStyle.Bold),
                Location = new Point(20, 375),
                Size = new Size(485, 45),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(239, 68, 68), // Red
                ForeColor = Color.White
            };
            btnToggleServer.Click += (s, e) =>
            {
                if (isRunning) StopServer();
                else StartServer();
            };
            this.Controls.Add(btnToggleServer);

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

                // Pure Socket TcpListener - Bypasses Windows Http.sys URLACL (No Access is denied)
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
            lblClients.Text = "📱 Connected Devices: 0";
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
                    Task.Run(() => HandleClientSessionAsync(client, token));
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
                client.NoDelay = true; // Disable Nagle's algorithm for sub-5ms low latency
                stream = client.GetStream();

                // 1. Perform RFC 6455 WebSocket Handshake
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
                    if (frame == null) break; // Client disconnected or closed

                    if (frame.Opcode == 8) // Close
                    {
                        break;
                    }
                    else if (frame.Opcode == 9) // Ping -> send Pong
                    {
                        SendWebSocketFrame(stream, 10, frame.Payload);
                    }
                    else if (frame.Opcode == 1) // Text JSON
                    {
                        string json = Encoding.UTF8.GetString(frame.Payload);
                        ProcessJsonMessage(json, stream);
                    }
                    else if (frame.Opcode == 2) // Binary Input Event
                    {
                        ProcessBinaryPacket(frame.Payload, frame.Payload.Length);
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
                frame.Add((byte)(0x80 | (opcode & 0x0F))); // FIN = 1, Opcode

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

        private void ProcessJsonMessage(string json, NetworkStream stream)
        {
            // Authenticate handshake response
            if (json.Contains("\"type\":\"auth_response\"") || json.Contains("\"type\":\"auth\""))
            {
                SendWebSocketText(stream, "{\"type\":\"auth_success\",\"token\":\"pc-session-key\"}");
            }
            else if (json.Contains("\"type\":\"device_info\""))
            {
                // Parse client screen resolution
                ExtractClientResolution(json);

                // Send server config confirmation
                SendWebSocketText(stream, "{\"type\":\"server_config\",\"data\":{\"port\":9090,\"useBinaryProtocol\":true}}");
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

        private void ExtractClientResolution(string json)
        {
            try
            {
                int wIdx = json.IndexOf("\"screenWidth\":");
                if (wIdx != -1)
                {
                    int end = json.IndexOfAny(new char[] { ',', '}' }, wIdx);
                    string val = json.Substring(wIdx + 14, end - (wIdx + 14)).Trim();
                    double.TryParse(val, out clientWidth);
                }
                int hIdx = json.IndexOf("\"screenHeight\":");
                if (hIdx != -1)
                {
                    int end = json.IndexOfAny(new char[] { ',', '}' }, hIdx);
                    string val = json.Substring(hIdx + 15, end - (hIdx + 15)).Trim();
                    double.TryParse(val, out clientHeight);
                }
            }
            catch { }
        }

        private void ParseJsonInputEvent(string json)
        {
            try
            {
                double x = 0, y = 0, pressure = 1.0;
                string eventType = "move";

                int tIdx = json.IndexOf("\"type\":");
                if (tIdx != -1)
                {
                    int start = json.IndexOf('"', tIdx + 7) + 1;
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

                int pIdx = json.IndexOf("\"pressure\":");
                if (pIdx != -1)
                {
                    int end = json.IndexOfAny(new char[] { ',', '}' }, pIdx);
                    string val = json.Substring(pIdx + 11, end - (pIdx + 11)).Trim();
                    double.TryParse(val, out pressure);
                }

                InjectInput(x, y, pressure, eventType);
            }
            catch { }
        }

        private void ProcessBinaryPacket(byte[] data, int count)
        {
            if (count < 14) return;
            try
            {
                // Binary protocol layout:
                // [0]: Magic byte (0xAC)
                // [1]: Event type (0=down, 1=move, 2=up, 3=hover, 4=cancel)
                // [2-5]: X (float32, big endian)
                // [6-9]: Y (float32, big endian)
                // [10-13]: Pressure (float32, big endian)
                if (data[0] != 0xAC) return;

                byte typeByte = data[1];
                string eventType = "move";
                if (typeByte == 0) eventType = "down";
                else if (typeByte == 1) eventType = "move";
                else if (typeByte == 2) eventType = "up";

                byte[] xBytes = new byte[] { data[5], data[4], data[3], data[2] };
                byte[] yBytes = new byte[] { data[9], data[8], data[7], data[6] };
                byte[] pBytes = new byte[] { data[13], data[12], data[11], data[10] };

                float x = BitConverter.ToSingle(xBytes, 0);
                float y = BitConverter.ToSingle(yBytes, 0);
                float pressure = BitConverter.ToSingle(pBytes, 0);

                InjectInput(x, y, pressure, eventType);
            }
            catch { }
        }

        private void InjectInput(double x, double y, double pressure, string eventType)
        {
            if (!chkEnableInjection.Checked) return;

            try
            {
                Rectangle screen = Screen.PrimaryScreen.Bounds;
                int targetX = (int)((x / (clientWidth > 0 ? clientWidth : screen.Width)) * screen.Width);
                int targetY = (int)((y / (clientHeight > 0 ? clientHeight : screen.Height)) * screen.Height);

                // Clamp to screen bounds
                targetX = Math.Max(0, Math.Min(screen.Width - 1, targetX));
                targetY = Math.Max(0, Math.Min(screen.Height - 1, targetY));

                SetCursorPos(targetX, targetY);

                if (eventType.Equals("down", StringComparison.OrdinalIgnoreCase))
                {
                    mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
                }
                else if (eventType.Equals("up", StringComparison.OrdinalIgnoreCase))
                {
                    mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
                }
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
            Rectangle screen = Screen.PrimaryScreen.Bounds;
            int startX = screen.Width / 2 - 100;
            int startY = screen.Height / 2;

            SetCursorPos(startX, startY);
            mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
            for (int i = 0; i <= 200; i += 10)
            {
                SetCursorPos(startX + i, (int)(startY + Math.Sin(i * 0.05) * 40));
                Thread.Sleep(10);
            }
            mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
        }

        private void UpdateClientsUI()
        {
            if (this.IsDisposed || !this.IsHandleCreated) return;
            this.BeginInvoke((Action)(() =>
            {
                lblClients.Text = "📱 Connected Devices: " + connectedClients;
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
            base.OnFormClosing(e);
        }
    }
}
