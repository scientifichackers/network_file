import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http_server/http_server.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as pathlib;

const DEFAULT_UDP_PORT = 10003, _NAME = "network_file";
final _bcastAddr = InternetAddress("255.255.255.255"), _l = Logger(_NAME);

class FileIndex {
  final Directory root;
  final VirtualDirectory vDir;

  FileIndex(Directory root)
      : this.root = root.absolute,
        vDir = VirtualDirectory(root.path);

  File getFile(String key) {
    return File(root.path + "/" + key);
  }

  void serveFile(String key, HttpRequest request) {
    vDir.serveFile(getFile(key), request);
  }
}

Uint8List _dumpInt(int value) {
  return Uint64List.fromList([value]).buffer.asUint8List();
}

List _loadInt(List value) {
  return [
    Uint8List.fromList(value.sublist(0, 8)).buffer.asUint64List()[0],
    value.sublist(8),
  ];
}

typedef bool ShouldSAcceptDiscovery(FileSystemEntity file, String extra);

class FileDiscoveryServer {
  final FileIndex index;
  final int udpPort, transferServerPort, uid;
  final ShouldSAcceptDiscovery shouldAcceptDiscovery;

  RawDatagramSocket sock;
  StreamSubscription<RawSocketEvent> listener;

  FileDiscoveryServer(
    this.index,
    this.udpPort,
    this.transferServerPort,
    this.uid, {
    this.shouldAcceptDiscovery,
  });

  Future<void> bind() async {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort);
  }

  Future<void> handleRequest(Datagram req) async {
    final parts = _loadInt(req.data);
    if (parts[0] == uid) return;

    final params = jsonDecode(utf8.decode(parts[1]));
    final path = params[0];
    final extra = params[1];

    if (path == null) {
      _l.fine(
        "peer discovery request { address: ${req.address.address}, extra: $extra }",
      );
      if (shouldAcceptDiscovery != null && !shouldAcceptDiscovery(null, extra))
        return;
    } else {
      final file = index.getFile(path), exists = await file.exists();
      _l.fine(
        "file discovery request { path: $path, extra: $extra file: $file exists: $exists, address: ${req.address} }",
      );
      if (!exists ||
          (shouldAcceptDiscovery != null &&
              !shouldAcceptDiscovery(file, extra))) return;
    }

    sock.send(_dumpInt(transferServerPort), req.address, req.port);
  }

  void serveForever() {
    _l.info(
      "FileDiscoveryServer started @ udp://${sock.address.address}:${sock.port}",
    );
    listener = sock.listen((event) {
      final req = sock.receive();
      if (req == null) return;
      try {
        handleRequest(req);
      } catch (e, trace) {
        _l.fine("error in discovery server", e, trace);
      }
    });
  }

  Future<void> close() async {
    sock?.close();
    sock = null;
    await listener?.cancel();
    listener = null;
    _l.info("FileDiscoveryServer closed!");
  }
}

class FileTransferServer {
  final FileIndex index;

  HttpServer server;
  StreamSubscription<HttpRequest> listener;

  FileTransferServer(this.index);

  Future<void> bind() async {
    server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
  }

  void serveForever() {
    _l.info(
      "FileTransferServer started @ http://${server.address.address}:${server.port}",
    );
    listener = server.listen((request) {
      String key = pathlib.relative(request.uri.path, from: "/");
      _l.fine(
        "transfer request { key: $key ${request.connectionInfo.remoteAddress} }",
      );
      index.serveFile(key, request);
    });
  }

  Future<void> close() async {
    await server?.close();
    server = null;
    await listener?.cancel();
    listener = null;
    _l.info("FileTransferServer closed!");
  }
}

class NetworkFile {
  FileDiscoveryServer discoveryServer;
  FileTransferServer transferServer;
  final int udpPort;

  Future<void> start(
    Directory root, {
    ShouldSAcceptDiscovery shouldAcceptDiscovery,
  }) async {
    var index = FileIndex(root);

    transferServer = FileTransferServer(index);
    await transferServer.bind();
    transferServer.serveForever();

    discoveryServer = FileDiscoveryServer(
      index,
      udpPort,
      transferServer.server.port,
      hashCode,
      shouldAcceptDiscovery: shouldAcceptDiscovery,
    );
    await discoveryServer.bind();
    discoveryServer.serveForever();
  }

  Future<void> stop() async {
    await discoveryServer?.close();
    discoveryServer = null;
    await transferServer?.close();
    transferServer = null;
  }

  Future<Uri> find({
    String filePath,
    Duration timeout: const Duration(seconds: 30),
    String extra,
    Duration broadcastInterval: const Duration(milliseconds: 100),
  }) async {
    final completer = Completer<Uri>();

    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.broadcastEnabled = true;

    final payload =
        _dumpInt(hashCode) + utf8.encode(jsonEncode([filePath, extra]));
    final sendTimer = Timer.periodic(broadcastInterval, (timer) {
      if (completer.isCompleted) {
        timer.cancel();
        return;
      }
      sock.send(payload, _bcastAddr, udpPort);
    });

    StreamSubscription recvSub;
    recvSub = sock.timeout(timeout).listen((event) {
      final data = sock.receive(), response = data?.data;
      if (response == null) return;

      final uri = Uri(
        scheme: "http",
        host: data.address.address,
        port: _loadInt(response)[0],
        path: filePath,
      );
      _l.info("found ${filePath ?? 'peer'} @ $uri");

      recvSub.cancel();
      completer.complete(uri);
    }, onError: (error, stackTrace) {
      recvSub.cancel();
      completer.completeError(error, stackTrace);
    });

    try {
      return await completer.future;
    } finally {
      sendTimer.cancel();
      recvSub.cancel();
    }
  }

  NetworkFile._internal(this.udpPort);

  static NetworkFile _instance;

  factory NetworkFile.getInstance({int udpPort: DEFAULT_UDP_PORT}) {
    if (_instance == null) _instance = NetworkFile._internal(udpPort);
    return _instance;
  }
}
