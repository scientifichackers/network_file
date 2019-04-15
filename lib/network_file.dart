import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http_server/http_server.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as pathlib;

const BCAST_ADDR = "255.255.255.255",
    UDP_PORT = 10003,
    _separator = "\n\n",
    _NAME = "network_file";

final _l = Logger(_NAME);

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

typedef bool ShouldSAcceptDiscovery(FileSystemEntity file, String extra);

class FileDiscoveryServer {
  final FileIndex index;
  final List<int> responsePrefix;
  final ShouldSAcceptDiscovery shouldAcceptDiscovery;

  RawDatagramSocket sock;
  StreamSubscription<RawSocketEvent> listener;

  FileDiscoveryServer(
    this.index,
    int transferServerPort, {
    this.shouldAcceptDiscovery,
  }) : responsePrefix = utf8.encode(transferServerPort.toString());

  Future<void> bind() async {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, UDP_PORT);
  }

  Future<void> handleRequest(Datagram req) async {
    var params = jsonDecode(utf8.decode(req.data)),
        key = params[0],
        extra = params[1],
        file = index.getFile(key),
        exists = await file.exists();

    _l.fine("receieved discovery request: $key, $extra (exists: $exists)");

    if (!exists || !(shouldAcceptDiscovery?.call(file, extra) ?? true)) return;
    sock.send(
      responsePrefix + utf8.encode(_separator + key),
      req.address,
      req.port,
    );
  }

  void serveForever() {
    _l.info(
      "FileDiscoveryServer listenng on: udp://${sock.address.address}:${sock.port}",
    );
    listener = sock.listen((event) {
      var data = sock.receive();
      if (data == null) return;
      handleRequest(data);
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
      _l.fine("receieved download request: $key");
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

class Servers {
  final FileDiscoveryServer discoveryServer;
  final FileTransferServer transferServer;

  Servers(this.discoveryServer, this.transferServer);

  Future<void> close() async {
    await discoveryServer.close();
    await transferServer.close();
  }
}

class NetworkFile {
  static Future<Servers> runServers(
    Directory root, {
    ShouldSAcceptDiscovery shouldAcceptDiscovery,
  }) async {
    var index = FileIndex(root);

    var fServer = FileTransferServer(index);
    await fServer.bind();
    fServer.serveForever();

    var dServer = FileDiscoveryServer(
      index,
      fServer.server.port,
      shouldAcceptDiscovery: shouldAcceptDiscovery,
    );
    await dServer.bind();
    dServer.serveForever();

    return Servers(dServer, fServer);
  }

  static Future<String> findFile({
    String path,
    Duration timeout: const Duration(seconds: 30),
    String extra,
  }) async {
    var sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.broadcastEnabled = true;

    sock.send(
      utf8.encode(jsonEncode([path, extra])),
      InternetAddress(BCAST_ADDR),
      UDP_PORT,
    );

    var completer = Completer();
    StreamSubscription sub;

    sub = sock.timeout(timeout).listen((event) {
      var data = sock.receive();
      if (data == null) {
        return;
      }
      var response = utf8.decode(data.data).split(_separator);
      if (response[1] != path) {
        return;
      }
      sub.cancel();
      completer.complete(
        "http://${data.address.address}:${response[0]}/${response[1]}",
      );
    }, onError: (error, stackTrace) {
      print(error);
      print(stackTrace);
      sub.cancel();
      completer.completeError(error, stackTrace);
    });

    return await completer.future;
  }
}
