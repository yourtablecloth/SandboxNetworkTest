import dgram from 'node:dgram';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';

function readArguments(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    const value = argv[index + 1];
    if (!name?.startsWith('--') || value === undefined) {
      throw new Error(`Invalid argument sequence near '${name ?? '<end>'}'.`);
    }
    values[name.slice(2)] = value;
  }
  return values;
}

function writeJsonAtomic(path, value) {
  const temporaryPath = `${path}.${process.pid}.tmp`;
  fs.writeFileSync(temporaryPath, JSON.stringify(value, null, 2), 'utf8');
  fs.renameSync(temporaryPath, path);
}

const args = readArguments(process.argv.slice(2));
const mode = args.mode;
const tcpPort = Number.parseInt(args['tcp-port'], 10);
const udpPort = Number.parseInt(args['udp-port'], 10);
const readyPath = args['ready-path'];
const resultPath = args['result-path'];

if (!mode || !Number.isInteger(tcpPort) || !Number.isInteger(udpPort) || !readyPath || !resultPath) {
  throw new Error('mode, tcp-port, udp-port, ready-path, and result-path are required.');
}

const result = {
  State: 'Listening',
  Mode: mode,
  ProcessId: process.pid,
  HostName: os.hostname(),
  StartedAtUtc: new Date().toISOString(),
  TcpPort: tcpPort,
  UdpPort: udpPort,
  TcpRequest: null,
  UdpRequest: null,
};

let listenersReady = 0;
let finalizing = false;

function markReady(protocol, address) {
  result[`${protocol}Listener`] = address;
  listenersReady += 1;
  if (listenersReady === 2) {
    writeJsonAtomic(readyPath, {
      State: 'Listening',
      Mode: mode,
      ProcessId: process.pid,
      TcpListener: result.TcpListener,
      UdpListener: result.UdpListener,
      ReadyAtUtc: new Date().toISOString(),
    });
  }
}

function completeWhenReady() {
  if (finalizing || !result.TcpRequest || !result.UdpRequest) {
    return;
  }
  finalizing = true;
  result.State = 'Completed';
  result.CompletedAtUtc = new Date().toISOString();
  writeJsonAtomic(resultPath, result);
  tcpServer.close();
  udpServer.close();
}

function fail(protocol, error) {
  if (finalizing) {
    return;
  }
  finalizing = true;
  result.State = 'Failed';
  result.FailedProtocol = protocol;
  result.Error = error?.stack ?? String(error);
  result.CompletedAtUtc = new Date().toISOString();
  try {
    writeJsonAtomic(resultPath, result);
  } finally {
    process.exitCode = 1;
  }
}

const tcpServer = net.createServer((socket) => {
  socket.setEncoding('utf8');
  socket.setTimeout(10000);
  let requestBuffer = '';

  socket.on('data', (chunk) => {
    requestBuffer += chunk;
    const lineEnd = requestBuffer.indexOf('\n');
    if (lineEnd < 0 || result.TcpRequest) {
      return;
    }

    const requestPayload = requestBuffer.slice(0, lineEnd).replace(/\r$/, '');
    const response = {
      Message: 'Hello from the host TCP listener',
      Protocol: 'TCP',
      Mode: mode,
      HostName: os.hostname(),
      RequestPayload: requestPayload,
      RemoteAddress: socket.remoteAddress,
      RemotePort: socket.remotePort,
      RespondedAtUtc: new Date().toISOString(),
    };
    result.TcpRequest = response;
    socket.end(`${JSON.stringify(response)}\n`);
    completeWhenReady();
  });

  socket.on('timeout', () => socket.destroy(new Error('TCP client timed out.')));
  socket.on('error', (error) => {
    if (!finalizing) {
      fail('TCP connection', error);
    }
  });
});

tcpServer.on('error', (error) => fail('TCP listener', error));
tcpServer.listen(tcpPort, '0.0.0.0', () => markReady('Tcp', tcpServer.address()));

const udpServer = dgram.createSocket('udp4');
udpServer.on('error', (error) => fail('UDP listener', error));
udpServer.on('message', (message, remote) => {
  if (result.UdpRequest) {
    return;
  }

  const requestPayload = message.toString('utf8');
  const response = {
    Message: 'Hello from the host UDP listener',
    Protocol: 'UDP',
    Mode: mode,
    HostName: os.hostname(),
    RequestPayload: requestPayload,
    RemoteAddress: remote.address,
    RemotePort: remote.port,
    RespondedAtUtc: new Date().toISOString(),
  };
  const responseBytes = Buffer.from(JSON.stringify(response), 'utf8');
  udpServer.send(responseBytes, remote.port, remote.address, (error) => {
    if (error) {
      fail('UDP response', error);
      return;
    }
    result.UdpRequest = response;
    completeWhenReady();
  });
});
udpServer.bind(udpPort, '0.0.0.0', () => markReady('Udp', udpServer.address()));

process.on('SIGTERM', () => {
  tcpServer.close();
  udpServer.close();
});
