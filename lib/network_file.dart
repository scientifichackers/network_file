import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http_server/http_server.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as pathlib;

const BCAST_ADDR = "255.255.255.255", UDP_PORT = 10003, _NAME = "network_file";
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

class FileDiscoveryServer {
  RawDatagramSocket sock;
  final FileIndex index;
  final List<int> responsePrefix;

  FileDiscoveryServer(this.index, int transferServerPort, {this.sock})
      : responsePrefix = utf8.encode(transferServerPort.toString());

  Future<void> bind() async {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, UDP_PORT);
  }

  Future<void> handleRequest(Datagram data) async {
    var key = utf8.decode(data.data),
        file = index.getFile(key),
        exists = await file.exists();

    print(
      "${data.address.address}:${data.port} requested file: $key, exists: $exists",
    );

    if (!exists) return;
    sock.send(
      responsePrefix + utf8.encode("\n\n" + key),
      data.address,
      data.port,
    );
  }

  StreamSubscription<RawSocketEvent> serveForever() {
    print(
      "FileDiscoveryServer listenng on: udp://${sock.address.address}:${sock.port}",
    );
    return sock.listen((event) {
      var data = sock.receive();
      if (data == null) return;
      handleRequest(data);
    });
  }
}

class FileTransferServer {
  HttpServer server;
  FileIndex index;

  FileTransferServer(this.index);

  Future<void> bind() async {
    server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
  }

  StreamSubscription<HttpRequest> serveForever() {
    print(
      "FileTransferServer listenng on: tcp://${server.address.address}:${server.port}",
    );
    return server.listen((request) {
      String key = pathlib.relative(request.uri.path, from: "/");
      print("request to download: $key");
      index.serveFile(key, request);
    });
  }
}

class NetworkFile {
  static Future<void> runServer(Directory root) async {
    var index = FileIndex(root);

    var fServer = FileTransferServer(index);
    await fServer.bind();
    fServer.serveForever();

    var dServer = FileDiscoveryServer(index, fServer.server.port);
    await dServer.bind();
    dServer.serveForever();
  }

  static Future<String> findFile({
    String path,
    Duration timeout: const Duration(seconds: 30),
  }) async {
    var sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.broadcastEnabled = true;

    sock.send(utf8.encode(path), InternetAddress(BCAST_ADDR), UDP_PORT);

    var completer = Completer();
    StreamSubscription sub;

    sub = sock.timeout(timeout).listen((event) {
      var data = sock.receive();
      if (data == null) {
        return;
      }
      var response = utf8.decode(data.data).split("\n\n");
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
