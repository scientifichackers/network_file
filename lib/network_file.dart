import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http_server/http_server.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as pathlib;

const UDP_PORT = 10003, _NAME = "network_file";
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
  final int transferServerPort, uid;
  final ShouldSAcceptDiscovery shouldAcceptDiscovery;

  RawDatagramSocket sock;
  StreamSubscription<RawSocketEvent> listener;

  FileDiscoveryServer(
    this.index,
    this.transferServerPort,
    this.uid, {
    this.shouldAcceptDiscovery,
  });

  Future<void> bind() async {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, UDP_PORT);
  }

  Future<void> handleRequest(Datagram req) async {
    final parts = _loadInt(req.data);
    if (parts[0] == uid) return;
    
    final params = jsonDecode(utf8.decode(parts[1])),
        path = params[0],
        extra = params[1],
        file = index.getFile(path),
        exists = await file.exists();

    _l.fine(
      "discovery request: $path, $extra (exists: $exists) (${req.address})",
    );

    if (!exists || !(shouldAcceptDiscovery?.call(file, extra) ?? true)) return;
    sock.send([transferServerPort], req.address, req.port);
  }

  void serveForever() {
    _l.info(
      "FileDiscoveryServer listenng on: udp://${sock.address.address}:${sock.port}",
    );
    listener = sock.listen((event) {
      final req = sock.receive();
      if (req == null) return;
      handleRequest(req);
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
      "FileTransferServer listenng on: tcp://${server.address.address}:${server.port}",
    );
    listener = server.listen((request) {
      String key = pathlib.relative(request.uri.path, from: "/");
      _l.fine(
        "download request: $key (${request.connectionInfo.remoteAddress})",
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

  Future<void> run(
    Directory root, {
    ShouldSAcceptDiscovery shouldAcceptDiscovery,
  }) async {
    var index = FileIndex(root);

    transferServer = FileTransferServer(index);
    await transferServer.bind();
    transferServer.serveForever();

    discoveryServer = FileDiscoveryServer(
      index,
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

  Future<String> findFile(
    String path, {
    Duration timeout: const Duration(seconds: 30),
    String extra,
  }) async {
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.broadcastEnabled = true;

    final payload = _dumpInt(hashCode) + utf8.encode(jsonEncode([path, extra]));
    sock.send(payload, _bcastAddr, UDP_PORT);

    final completer = Completer();
    StreamSubscription sub;

    sub = sock.timeout(timeout).listen((event) {
      final data = sock.receive(), response = data?.data;
      if (response == null || response.length != 1) return;
      sub.cancel();
      completer.complete("http://${data.address.address}:${response[0]}/$path");
    }, onError: (error, stackTrace) {
      sub.cancel();
      completer.completeError(error, stackTrace);
    });

    return await completer.future;
  }

  NetworkFile._internal();

  static NetworkFile _instance;

  factory NetworkFile.getInstance() {
    if (_instance == null) _instance = NetworkFile._internal();
    return _instance;
  }
}
