import 'dart:async';
import 'dart:io';

import 'package:http_server/http_server.dart';
import 'package:logging/logging.dart';
import 'package:network_file/util.dart';
import 'package:path/path.dart' as pathlib;

final _log = Logger("network_file");

class NetworkFileCallbacks {
  Future<bool> acceptClientDiscovery(
    InternetAddress address,
    String rootDir,
    String path,
    requestData,
  ) async {
    if (rootDir == null || path == null) {
      _log.fine(
        "peer discovery request { from: $address, requestData: $requestData }",
      );
      return true;
    } else {
      var file = File("$rootDir/$path");
      var exists = await file.exists();
      _log.fine(
        "file discovery request { from: $address path: $path, requestData: $requestData file: $file exists: $exists }",
      );
      return exists;
    }
  }

  Future<bool> acceptServerDiscovery(
    Uri uri,
    String path,
    responseData,
  ) async {
    return true;
  }

  Future<void> serveFile(String rootDir, String path, HttpRequest req) async {
    VirtualDirectory(rootDir).serveFile(File("$rootDir/$path"), req);
  }
}

class NetworkFile {
  static var bcastAddr = InternetAddress("255.255.255.255");

  //
  // constructor
  //

  final int udpPort;
  String rootDir;
  var responseData;
  NetworkFileCallbacks callbacks;
  static final Map<int, NetworkFile> _instances = {};

  NetworkFile._internal(this.udpPort);

  factory NetworkFile.getInstance({
    int udpPort: 10003,
    String rootDir,
    dynamic responseData,
    NetworkFileCallbacks callbacks,
  }) {
    _instances.putIfAbsent(udpPort, () {
      return NetworkFile._internal(udpPort);
    });
    var instance = _instances[udpPort];
    instance.rootDir = rootDir;
    instance.responseData = responseData;
    instance.callbacks = callbacks ?? NetworkFileCallbacks();
    return instance;
  }

  //
  // server side
  //

  Future<void> startServer() async {
    await startDiscoveryServer();
    await startFileServer();
  }

  Future<void> stopServer() async {
    discoveryServer?.close();
    discoveryServer = null;
    await discoveryServerSub?.cancel();
    discoveryServerSub = null;
    _log.info("discovery server closed");

    fileServer?.close();
    fileServer = null;
    await fileServerSub?.cancel();
    fileServerSub = null;
    _log.info("file server closed");
  }

  //
  // discovery server
  //

  RawDatagramSocket discoveryServer;
  StreamSubscription<RawSocketEvent> discoveryServerSub;

  Future<void> startDiscoveryServer() async {
    discoveryServer =
        await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort);
    _log.info(
      "discovery server started @ udp://${discoveryServer.address.address}:${discoveryServer.port}",
    );

    discoveryServerSub = discoveryServer.listen((_) {
      final req = discoveryServer.receive();
      if (req == null) return;
      try {
        onDiscoveryRequest(req);
      } catch (e, trace) {
        _log.fine("error in discovery server", e, trace);
      }
    });
  }

  Future<void> onDiscoveryRequest(Datagram req) async {
    if (fileServer == null) return;

    var payload = load(req.data);
    if (payload.intPrefix == hashCode) return;

    var path = payload.jsonData[0];
    var requestData = payload.jsonData[1];

    if (await callbacks.acceptClientDiscovery(
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

  Future<void> startFileServer() async {
    fileServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _log.info(
      "file server started @ http://${fileServer.address.address}:${fileServer.port}",
    );
    fileServerSub = fileServer.listen(onFileServerRequest);
  }

  void onFileServerRequest(HttpRequest req) async {
    var path = pathlib.relative(req.uri.path, from: "/");
    _log.fine(
      "file request { from: ${req.connectionInfo.remoteAddress}, path: $path }",
    );
    await callbacks.serveFile(rootDir, path, req);
  }

  //
  // client side
  //

  Future<Uri> find({
    String path,
    Duration timeout: const Duration(seconds: 30),
    dynamic requestData,
    Duration broadcastInterval: const Duration(milliseconds: 100),
  }) async {
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
      _log.info("found ${'path "$path"' ?? 'peer'} @ $uri");

      if (await callbacks.acceptServerDiscovery(
        uri,
        path,
        payload.jsonData,
      )) {
        recvSub.cancel();
        completer.complete(uri);
      } else {
        _log.info("rejected $uri");
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
