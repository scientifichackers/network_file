import 'dart:io';

import 'package:network_file/network_file.dart';

main() async {
  NetworkFile.getInstance(rootDir: Directory.current.path).startServer();
}
