import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http_server/http_server.dart';
import 'package:path/path.dart' as pathlib;

const BCAST_ADDR = "255.255.255.255";
const UDP_PORT = 10003;

class FileIndex {
  Map<String, File> fileMap = {};
  Directory root;
  bool useMD5Key, recursive;
  VirtualDirectory vdir;

  FileIndex(this.root, {this.useMD5Key: false, this.recursive: false}) {
    root = root.absolute;
    vdir = VirtualDirectory(root.path);
  }

  Future<void> build() async {
    await for (FileSystemEntity file in root.list(recursive: recursive)) {
      if (file is File) {
        await add(file);
      }
    }
  }

  Future<void> add(File file) async {
    var key = pathlib.relative(file.path, from: root.path);
    if (useMD5Key) {
      key = md5.convert(await file.readAsBytes()).toString();
    }
    fileMap[key] = file;
  }

  void serveFile(String key, HttpRequest request) {
    File file;
    if (useMD5Key) {
      if (!fileMap.containsKey(key)) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
        return;
      }
      file = fileMap[key];
    } else {
      print(root.path);
      print(key);
      print(root.path + "/" + key);
      file = File(root.path + "/" + key);
    }
    vdir.serveFile(file, request);
  }
}

class FileDiscoveryServer {
  RawDatagramSocket sock;
  FileIndex index;
  List<int> responsePrefix;

  FileDiscoveryServer(this.index, int transferServerPort, {this.sock}) {
    responsePrefix = utf8.encode(transferServerPort.toString());
  }

  Future<void> bind() async {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, UDP_PORT);
  }

  void handleRequest(Datagram data) {
    var key = utf8.decode(data.data);
    print(
      "${data.address.address}:${data.port} requested file: $key -> ${index.fileMap[key]}",
    );
    if (!index.fileMap.containsKey(key)) {
      return;
    }
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
      if (data == null) {
        return;
      }
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
      print(
        "request to download file: $key -> ${index.fileMap[key]}",
      );
      index.serveFile(key, request);
    });
  }
}

class NetworkFile {
  static Future<void> runserver(
    Directory root, {
    bool useMD5Key: false,
    bool recursive: false,
  }) async {
    var index = FileIndex(root, useMD5Key: useMD5Key, recursive: recursive);
    await index.build();

    var fServer = FileTransferServer(index);
    await fServer.bind();
    fServer.serveForever();

    var dServer = FileDiscoveryServer(index, fServer.server.port);
    await dServer.bind();
    dServer.serveForever();

    return [FileDiscoveryServer, FileTransferServer];
  }

  static Future<String> findFile(
    String key, {
    Duration timeout: const Duration(seconds: 30),
  }) async {
    var sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.broadcastEnabled = true;

    sock.send(utf8.encode(key), InternetAddress(BCAST_ADDR), UDP_PORT);

    var completer = Completer();
    StreamSubscription sub;

    sub = sock.timeout(timeout).listen(
      (event) {
        var data = sock.receive();
        if (data == null) {
          return;
        }
        var response = utf8.decode(data.data).split("\n\n");
        if (response[1] != key) {
          return;
        }
        sub.cancel();
        completer.complete(
          "http://${data.address.address}:${response[0]}/${response[1]}",
        );
      },
      onError: (error, stackTrace) {
        print(error);
        print(stackTrace);
        sub.cancel();
        completer.completeError(error, stackTrace);
      },
    );
    return await completer.future;
  }
}
