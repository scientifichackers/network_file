import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:network_file/network_file.dart';

void main() {
  test('tests one file to be downloaded', () async {
    var projectRoot = Directory(Platform.script.toFilePath()).parent;
    var pubspec = await File(
      projectRoot.path + "/" + "pubspec.yaml",
    ).readAsString();

    await NetworkFile.runserver(projectRoot);
    var url = await NetworkFile.findFile("pubspec.yaml");
    var response = await http.get(url);

    assert(response.body == pubspec);
    assert(response.statusCode == 200);
  });
}
