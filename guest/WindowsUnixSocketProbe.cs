using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class WindowsUnixSocketProbe
{
    private const int AfUnix = 1;
    private const int SockStream = 1;
    private const int SocketError = -1;
    private const int UnixPathMax = 108;
    private static readonly IntPtr InvalidSocket = new IntPtr(-1);
    private static bool winsockStarted;

    [DllImport("Ws2_32.dll", SetLastError = true)]
    private static extern int WSAStartup(ushort versionRequested, IntPtr wsaData);

    [DllImport("Ws2_32.dll")]
    private static extern int WSAGetLastError();

    [DllImport("Ws2_32.dll", SetLastError = true)]
    private static extern IntPtr socket(int addressFamily, int socketType, int protocol);

    [DllImport("Ws2_32.dll", SetLastError = true)]
    private static extern int bind(IntPtr socket, byte[] address, int addressLength);

    [DllImport("Ws2_32.dll", SetLastError = true)]
    private static extern int listen(IntPtr socket, int backlog);

    [DllImport("Ws2_32.dll", SetLastError = true)]
    private static extern IntPtr accept(IntPtr socket, IntPtr address, IntPtr addressLength);

    [DllImport("Ws2_32.dll", SetLastError = true)]
    private static extern int connect(IntPtr socket, byte[] address, int addressLength);

    [DllImport("Ws2_32.dll", SetLastError = true)]
    private static extern int send(IntPtr socket, byte[] buffer, int length, int flags);

    [DllImport("Ws2_32.dll", SetLastError = true)]
    private static extern int recv(IntPtr socket, byte[] buffer, int length, int flags);

    [DllImport("Ws2_32.dll", SetLastError = true)]
    private static extern int closesocket(IntPtr socket);

    private static void EnsureWinsock()
    {
        if (winsockStarted)
        {
            return;
        }

        IntPtr data = Marshal.AllocHGlobal(512);
        try
        {
            int result = WSAStartup(0x0202, data);
            if (result != 0)
            {
                throw new Win32Exception(result, "WSAStartup failed");
            }

            winsockStarted = true;
        }
        finally
        {
            Marshal.FreeHGlobal(data);
        }
    }

    private static byte[] CreateAddress(string path)
    {
        byte[] pathBytes = Encoding.UTF8.GetBytes(path);
        if (pathBytes.Length >= UnixPathMax)
        {
            throw new ArgumentException("The UTF-8 socket path must be shorter than 108 bytes.", "path");
        }

        byte[] address = new byte[2 + UnixPathMax];
        address[0] = AfUnix;
        address[1] = 0;
        Buffer.BlockCopy(pathBytes, 0, address, 2, pathBytes.Length);
        return address;
    }

    private static IntPtr CreateSocket()
    {
        EnsureWinsock();
        IntPtr value = socket(AfUnix, SockStream, 0);
        if (value == InvalidSocket)
        {
            ThrowSocketError("socket(AF_UNIX, SOCK_STREAM)");
        }

        return value;
    }

    private static void Bind(IntPtr value, string path)
    {
        byte[] address = CreateAddress(path);
        if (bind(value, address, address.Length) == SocketError)
        {
            ThrowSocketError("bind(" + path + ")");
        }
    }

    private static void Connect(IntPtr value, string path)
    {
        byte[] address = CreateAddress(path);
        if (connect(value, address, address.Length) == SocketError)
        {
            ThrowSocketError("connect(" + path + ")");
        }
    }

    private static void Listen(IntPtr value)
    {
        if (listen(value, 1) == SocketError)
        {
            ThrowSocketError("listen");
        }
    }

    private static IntPtr Accept(IntPtr value)
    {
        IntPtr accepted = accept(value, IntPtr.Zero, IntPtr.Zero);
        if (accepted == InvalidSocket)
        {
            ThrowSocketError("accept");
        }

        return accepted;
    }

    private static void SendText(IntPtr value, string text)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(text);
        int offset = 0;
        while (offset < bytes.Length)
        {
            byte[] remaining = new byte[bytes.Length - offset];
            Buffer.BlockCopy(bytes, offset, remaining, 0, remaining.Length);
            int sent = send(value, remaining, remaining.Length, 0);
            if (sent == SocketError)
            {
                ThrowSocketError("send");
            }
            if (sent == 0)
            {
                throw new IOException("send returned zero before the payload was complete.");
            }

            offset += sent;
        }
    }

    private static string ReceiveText(IntPtr value)
    {
        byte[] bytes = new byte[4096];
        int received = recv(value, bytes, bytes.Length, 0);
        if (received == SocketError)
        {
            ThrowSocketError("recv");
        }

        return Encoding.UTF8.GetString(bytes, 0, received);
    }

    private static void ThrowSocketError(string operation)
    {
        int error = WSAGetLastError();
        throw new Win32Exception(error, operation + " failed with Winsock error " + error);
    }

    private static void CloseSocket(ref IntPtr value)
    {
        if (value != IntPtr.Zero && value != InvalidSocket)
        {
            closesocket(value);
            value = IntPtr.Zero;
        }
    }

    private static void DeleteSocketFile(string path)
    {
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }

    public static string RunLocalRoundTrip(string path, string request)
    {
        IntPtr server = IntPtr.Zero;
        IntPtr client = IntPtr.Zero;
        IntPtr accepted = IntPtr.Zero;
        DeleteSocketFile(path);

        try
        {
            server = CreateSocket();
            Bind(server, path);
            Listen(server);

            client = CreateSocket();
            Connect(client, path);
            accepted = Accept(server);

            SendText(client, request);
            string received = ReceiveText(accepted);
            string response = "local-af-unix-ack:" + received;
            SendText(accepted, response);
            return ReceiveText(client);
        }
        finally
        {
            CloseSocket(ref accepted);
            CloseSocket(ref client);
            CloseSocket(ref server);
            DeleteSocketFile(path);
        }
    }

    public static string ConnectAndExchange(string path, string request)
    {
        IntPtr client = IntPtr.Zero;
        try
        {
            client = CreateSocket();
            Connect(client, path);
            SendText(client, request);
            return ReceiveText(client);
        }
        finally
        {
            CloseSocket(ref client);
        }
    }

    public static void RunServer(string path, string readyPath, string transcriptPath)
    {
        IntPtr server = IntPtr.Zero;
        IntPtr accepted = IntPtr.Zero;
        DeleteSocketFile(path);

        try
        {
            server = CreateSocket();
            Bind(server, path);
            Listen(server);
            File.WriteAllText(readyPath, DateTimeOffset.UtcNow.ToString("o"), new UTF8Encoding(false));

            accepted = Accept(server);
            string request = ReceiveText(accepted);
            string response = "host-af-unix-ack:" + request;
            SendText(accepted, response);
            File.WriteAllText(transcriptPath, request, new UTF8Encoding(false));
        }
        finally
        {
            CloseSocket(ref accepted);
            CloseSocket(ref server);
        }
    }
}
