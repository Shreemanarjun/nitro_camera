/// Typed native ML-detector results (barcode / face) — the structured form of
/// the `detection` event's JSON payload. Replaces the untyped
/// `Map<String, dynamic>` stream with parsed, typed records.
library;

/// Which native ML detector to run. Wire values match the native side.
enum NativeDetector {
  barcode('barcode'),
  face('face');

  /// The string passed across the FFI boundary.
  final String wire;
  const NativeDetector(this.wire);
}

/// An axis-aligned bounding box in **frame pixel** coordinates (origin
/// top-left of the detector's input frame, before display rotation/mirror).
/// Use [normalized] against the frame size for a resolution-independent box.
class DetectionBounds {
  final double left;
  final double top;
  final double right;
  final double bottom;

  const DetectionBounds(this.left, this.top, this.right, this.bottom);

  double get width => right - left;
  double get height => bottom - top;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  /// This box as fractions (0..1) of a [frameWidth] × [frameHeight] frame.
  DetectionBounds normalized(int frameWidth, int frameHeight) {
    final w = frameWidth == 0 ? 1 : frameWidth;
    final h = frameHeight == 0 ? 1 : frameHeight;
    return DetectionBounds(left / w, top / h, right / w, bottom / h);
  }

  static DetectionBounds? _fromJson(Object? v) {
    if (v is List && v.length >= 4) {
      return DetectionBounds((v[0] as num).toDouble(), (v[1] as num).toDouble(), (v[2] as num).toDouble(), (v[3] as num).toDouble());
    }
    return null;
  }

  @override
  String toString() => 'DetectionBounds($left, $top, $right, $bottom)';
}

/// A detected barcode/QR (native ML Kit barcode detector).
class DetectedBarcode {
  /// Decoded value (raw value, or the display value when raw is absent).
  final String text;

  /// The native barcode-format code.
  final int format;

  /// Bounding box in frame pixels (may be null if the detector didn't report one).
  final DetectionBounds? bounds;

  const DetectedBarcode({required this.text, required this.format, this.bounds});

  factory DetectedBarcode.fromJson(Map<String, dynamic> j) => DetectedBarcode(
    text: j['text'] as String? ?? '',
    format: (j['format'] as num?)?.toInt() ?? 0,
    bounds: DetectionBounds._fromJson(j['bounds']),
  );
}

/// A detected face (native ML Kit face detector).
class DetectedFace {
  final DetectionBounds? bounds;
  final int? trackingId;
  final double? smilingProbability;
  final double? leftEyeOpenProbability;
  final double? rightEyeOpenProbability;
  final double headEulerAngleY;
  final double headEulerAngleZ;

  const DetectedFace({
    this.bounds,
    this.trackingId,
    this.smilingProbability,
    this.leftEyeOpenProbability,
    this.rightEyeOpenProbability,
    this.headEulerAngleY = 0,
    this.headEulerAngleZ = 0,
  });

  factory DetectedFace.fromJson(Map<String, dynamic> j) => DetectedFace(
    bounds: DetectionBounds._fromJson(j['bounds']),
    trackingId: (j['trackingId'] as num?)?.toInt(),
    smilingProbability: (j['smilingProbability'] as num?)?.toDouble(),
    leftEyeOpenProbability: (j['leftEyeOpenProbability'] as num?)?.toDouble(),
    rightEyeOpenProbability: (j['rightEyeOpenProbability'] as num?)?.toDouble(),
    headEulerAngleY: (j['headEulerAngleY'] as num?)?.toDouble() ?? 0,
    headEulerAngleZ: (j['headEulerAngleZ'] as num?)?.toDouble() ?? 0,
  );
}

/// One frame's worth of native-detector results.
class DetectionResult {
  final NativeDetector detector;

  /// The detector input frame size (bounds are in these pixel coordinates).
  final int frameWidth;
  final int frameHeight;

  /// Frame rotation (degrees) the detector saw.
  final int rotation;

  /// Barcodes (empty unless [detector] is [NativeDetector.barcode]).
  final List<DetectedBarcode> barcodes;

  /// Faces (empty unless [detector] is [NativeDetector.face]).
  final List<DetectedFace> faces;

  const DetectionResult({
    required this.detector,
    required this.frameWidth,
    required this.frameHeight,
    required this.rotation,
    this.barcodes = const [],
    this.faces = const [],
  });

  /// Parses the native `detection` event payload. Returns null for an error
  /// payload or an unrecognised detector.
  static DetectionResult? fromJson(Map<String, dynamic> json) {
    if (json.containsKey('error')) return null;
    final name = json['detector'] as String?;
    final detector = switch (name) {
      'barcode' => NativeDetector.barcode,
      'face' => NativeDetector.face,
      _ => null,
    };
    if (detector == null) return null;
    final results = (json['results'] as List? ?? []).cast<Map<String, dynamic>>();
    return DetectionResult(
      detector: detector,
      frameWidth: (json['width'] as num?)?.toInt() ?? 0,
      frameHeight: (json['height'] as num?)?.toInt() ?? 0,
      rotation: (json['rotation'] as num?)?.toInt() ?? 0,
      barcodes: detector == NativeDetector.barcode ? results.map(DetectedBarcode.fromJson).toList() : const [],
      faces: detector == NativeDetector.face ? results.map(DetectedFace.fromJson).toList() : const [],
    );
  }

  @override
  String toString() =>
      'DetectionResult(${detector.name}, '
      '${frameWidth}x$frameHeight@$rotation°, '
      'barcodes=${barcodes.length}, faces=${faces.length})';
}
