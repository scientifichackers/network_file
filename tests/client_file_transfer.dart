import 'package:network_file/network_file.dart';

main() async {
  print(await NetworkFile.getInstance().find());
  print(
    await NetworkFile.getInstance().find(
      path: "pubspec.yaml",
      requestData: "secret",
      acceptServerDiscovery: (
        Uri uri,
        String path,
        secret,
      ) {
        if (secret != "secret") return false;
        return NetworkFile.acceptServerDiscovery(uri, path, secret);
      },
    ),
  );
}
