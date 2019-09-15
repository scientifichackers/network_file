import 'dart:async';
import 'dart:io';

import 'package:http_server/http_server.dart';
import 'package:network_file/util.dart';
import 'package:path/path.dart' as pathlib;

typedef FutureOr<bool> AcceptClientDiscovery(
  InternetAddress address,
  String rootDir,
  String path,
  requestData,
);

typedef FutureOr<bool> AcceptServerDiscovery(
  Uri uri,
  String path,
  responseData,
);

typedef FutureOr<void> ServeFile(
  String rootDir,
  String path,
  HttpRequest req,
);

class NetworkFile {
  static var bcastAddr = InternetAddress("255.255.255.255");
  static AcceptClientDiscovery acceptClientDiscovery = (
    address,
    rootDir,
    path,
    requestData,
  ) async {
    if (rootDir == null || path == null) {
      log.fine(
        "peer discovery request { from: $address, requestData: $requestData }",
      );
      return true;
    } else {
      var file = File("$rootDir/$path");
      var exists = await file.exists();
      log.fine(
        "file discovery request { from: $address path: $path, requestData: $requestData file: $file exists: $exists }",
      );
      return exists;
    }
  };

  static AcceptServerDiscovery acceptServerDiscovery = (
    uri,
    path,
    responseData,
  ) async {
    return true;
  };

  static ServeFile serveFile = (
    String rootDir,
    String path,
    HttpRequest req,
  ) async {
    VirtualDirectory(rootDir).serveFile(File("$rootDir/$path"), req);
  };

  //
  // constructor
  //

  final int udpPort;
  static final Map<int, NetworkFile> _instances = {};

  NetworkFile._internal(this.udpPort);

  factory NetworkFile.getInstance({int udpPort: 10003}) {
    _instances.putIfAbsent(udpPort, () {
      return NetworkFile._internal(udpPort);
    });
    return _instances[udpPort];
  }

  //
  // server side
  //

  Future<void> startServer({
    String rootDir,
    responseData,
    AcceptClientDiscovery acceptClientDiscovery,
    ServeFile serveFile,
  }) async {
    acceptClientDiscovery ??= NetworkFile.acceptClientDiscovery;
    serveFile ??= NetworkFile.serveFile;

    await startDiscoveryServer(rootDir, responseData, acceptClientDiscovery);
    await startFileServer(rootDir, serveFile);
  }

  Future<void> stopServer() async {
    discoveryServer?.close();
    discoveryServer = null;
    await discoveryServerSub?.cancel();
    discoveryServerSub = null;
    log.info("discovery server closed");

    fileServer?.close();
    fileServer = null;
    await fileServerSub?.cancel();
    fileServerSub = null;
    log.info("file server closed");
  }

  //
  // discovery server
  //

  RawDatagramSocket discoveryServer;
  StreamSubscription<RawSocketEvent> discoveryServerSub;

  Future<void> startDiscoveryServer(
    String rootDir,
    responseData,
    AcceptClientDiscovery acceptClientDiscovery,
  ) async {
    discoveryServer =
        await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort);
    log.info(
      "discovery server started @ udp://${discoveryServer.address.address}:${discoveryServer.port}",
    );

    discoveryServerSub = discoveryServer.listen((_) {
      final req = discoveryServer.receive();
      if (req == null) return;
      try {
        onDiscoveryRequest(req, rootDir, responseData, acceptClientDiscovery);
      } catch (e, trace) {
        log.fine("error in discovery server", e, trace);
      }
    });
  }

  Future<void> onDiscoveryRequest(
    Datagram req,
    String rootDir,
    responseData,
    AcceptClientDiscovery acceptClientDiscovery,
  ) async {
    if (fileServer == null) return;

    var payload = load(req.data);
    if (payload.intPrefix == hashCode) return;

    var path = payload.jsonData[0];
    var requestData = payload.jsonData[1];

    if (await acceptClientDiscovery(
      req.address,
      rootDir,
      path,
      requestData,
    )) {
      discoveryServer.send(
        dump(Payload(fileServer.port, responseData)),
        req.address,
        req.port,
      );
    }
  }

  //
  // file server
  //

  HttpServer fileServer;
  StreamSubscription<HttpRequest> fileServerSub;

  Future<void> startFileServer(String rootDir, ServeFile serveFile) async {
    fileServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    log.info(
      "file server started @ http://${fileServer.address.address}:${fileServer.port}",
    );
    fileServerSub = fileServer.listen((req) async {
      await onFileServerRequest(req, rootDir, serveFile);
    });
  }

  void onFileServerRequest(
    HttpRequest req,
    String rootDir,
    ServeFile serveFile,
  ) async {
    var path = pathlib.relative(req.uri.path, from: "/");
    log.fine(
      "file request { from: ${req.connectionInfo.remoteAddress}, path: $path }",
    );
    await serveFile(rootDir, path, req);
  }

  //
  // client side
  //

  Future<Uri> find({
    String path,
    Duration timeout: const Duration(seconds: 30),
    dynamic requestData,
    Duration broadcastInterval: const Duration(milliseconds: 100),
    AcceptServerDiscovery acceptServerDiscovery,
  }) async {
    acceptServerDiscovery ??= NetworkFile.acceptServerDiscovery;

    final completer = Completer<Uri>();

    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.broadcastEnabled = true;

    final payload = dump(Payload(hashCode, [path, requestData]));
    final sendTimer = Timer.periodic(broadcastInterval, (timer) {
      if (completer.isCompleted) {
        timer.cancel();
        return;
      }
      sock.send(payload, bcastAddr, udpPort);
    });

    StreamSubscription recvSub;
    recvSub = sock.timeout(timeout).listen((event) async {
      var datagram = sock.receive();
      if (datagram == null) return;

      var payload = load(datagram.data);
      var uri = Uri(
        scheme: "http",
        host: datagram.address.address,
        port: payload.intPrefix,
        path: path,
      );
      log.info("found ${'path "$path"' ?? 'peer'} @ $uri");

      if (await acceptServerDiscovery(uri, path, payload.jsonData)) {
        recvSub.cancel();
        completer.complete(uri);
      } else {
        log.info("rejected $uri");
      }
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
}
