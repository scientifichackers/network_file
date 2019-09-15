import 'dart:io';

import 'package:network_file/network_file.dart';

main() async {
  NetworkFile.getInstance().startServer(
    rootDir: Directory.current.path,
    responseData: "secret",
    acceptClientDiscovery: (addr, rootDir, path, secret) {
      if (secret != "secret") return false;
      return NetworkFile.acceptClientDiscovery(
        addr,
        rootDir,
        path,
        secret,
      );
    },
  );
}
