/// USPS POSTNET / PLANET decoder (height-modulated, checksummed).
///
/// Input is the 2-state classification of the extracted bars
/// (`classify2State`): 1 = tall, 0 = short. Tables transcribed from Zint
/// `backend/postal.c`.
library;

import '../types.dart';

/// POSTNET digit patterns, 1 = tall bar (PLANET is the inverse).
const List<String> _postnetDigits = [
  '11000',
  '00011',
  '00101',
  '00110',
  '01001',
  '01010',
  '01100',
  '10001',
  '10010',
  '10100',
];

/// Decodes POSTNET or PLANET from tall/short bar states. Returns null when
/// the frame structure or mod-10 checksum doesn't hold.
RawDecode? decodePostnetPlanet(List<int> tall) {
  final n = tall.length;
  // frame: guard + 5·(digits+check) + guard
  if (n < 12 || (n - 2) % 5 != 0) return null;
  if (tall.first != 1 || tall.last != 1) return null;

  RawDecode? tryDecode(List<int> bits, CodeFormat format) {
    final digits = <int>[];
    for (var i = 1; i + 5 <= bits.length - 1; i += 5) {
      final pattern = bits.sublist(i, i + 5).join();
      final d = _postnetDigits.indexOf(pattern);
      if (d < 0) return null;
      digits.add(d);
    }
    if (digits.length < 2) return null;
    final sum = digits.fold<int>(0, (a, b) => a + b);
    if (sum % 10 != 0) return null;
    // Drop the trailing check digit.
    return RawDecode(digits.sublist(0, digits.length - 1).join(), format);
  }

  return tryDecode(tall, CodeFormat.postnet) ?? tryDecode(tall.map((b) => 1 - b).toList(), CodeFormat.planet);
}
