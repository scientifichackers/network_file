import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';

final log = Logger("network_file");
const uint8Size = Uint8List.bytesPerElement * 8;

class Payload {
  final int intPrefix;
  final jsonData;

  Payload(this.intPrefix, this.jsonData);
}

List<int> dump(Payload payload) {
  return Uint64List.fromList([payload.intPrefix])
          .buffer
          .asUint8List()
          .toList() +
      utf8.encode(jsonEncode(payload.jsonData));
}

Payload load(List<int> value) {
  return Payload(
    Uint8List.fromList(value.sublist(0, uint8Size)).buffer.asUint64List()[0],
    jsonDecode(utf8.decode(value.sublist(uint8Size))),
  );
}
