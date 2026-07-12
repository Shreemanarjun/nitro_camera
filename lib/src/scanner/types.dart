/// Public types for the code-scanner module. Deliberately decoupled from any
/// decode engine (zxing / built-in Dart decoders / a future C++ backend).
library;

/// Barcode / code symbologies the scanner can detect.
///
/// Engines: **zxing** decodes the common linear + 2D + GS1 DataBar set; the
/// **built-in decoders** (`decoders/`) handle postal (POSTNET/PLANET/RM4SCC/
/// KIX), MSI, Code 11, Industrial 2-of-5, Telepen and Pharmacode.
enum CodeFormat {
  // ── 2D ──
  qrCode,
  dataMatrix,
  aztec,
  pdf417,

  /// MaxiCode — the UPS shipping symbology.
  maxicode,
  // ── 1D (zxing) ──
  ean13,
  ean8,
  upcA,
  upcE,
  code39,
  code93,
  code128,

  /// Interleaved 2-of-5.
  itf,
  codabar,

  /// GS1 DataBar (formerly RSS-14).
  rss14,

  /// GS1 DataBar Expanded (formerly RSS Expanded).
  rssExpanded,
  // ── 1D (built-in decoders) ──
  /// MSI / modified Plessey (mod-10 checked).
  msi,

  /// Code 11 (C/K checksummed).
  code11,

  /// Standard / Industrial 2-of-5 (data in bars only).
  industrial2of5,

  /// Telepen alpha (full-ASCII, mod-127 checked).
  telepen,

  /// Pharmacode one-track (Laetus). No structure/checksum — only decoded
  /// when explicitly selected ([CodeScanKind.pharma]).
  pharmacode,

  /// Pharmacode two-track (Laetus).
  pharmacodeTwoTrack,
  // ── Postal (height-modulated, built-in decoders) ──
  /// USPS POSTNET.
  postnet,

  /// USPS PLANET.
  planet,

  /// Royal Mail 4-State Customer Code (checksummed).
  rm4scc,

  /// Dutch TNT KIX (RM4SCC without checksum).
  kix;

  /// Whether this is a 2D (matrix) symbology.
  bool get is2D => switch (this) {
    qrCode || dataMatrix || aztec || pdf417 || maxicode => true,
    _ => false,
  };

  /// Whether this is a postal (height-modulated) symbology.
  bool get isPostal => switch (this) {
    postnet || planet || rm4scc || kix => true,
    _ => false,
  };

  /// Whether this is a Pharmacode symbology (explicit-selection only).
  bool get isPharma => this == pharmacode || this == pharmacodeTwoTrack;

  /// Whether the zxing engine decodes this format.
  bool get isZxing => switch (this) {
    msi || code11 || industrial2of5 || telepen || pharmacode || pharmacodeTwoTrack || postnet || planet || rm4scc || kix => false,
    _ => true,
  };

  /// Whether this is a 1D (linear) symbology.
  bool get is1D => !is2D && !isPostal;
}

/// Which family of codes to look for in a frame.
enum CodeScanKind {
  /// QR codes only — the fastest option.
  qr,

  /// Linear barcodes: EAN/UPC, Code 39/93/128 (incl. GS1-128), ITF, Codabar,
  /// GS1 DataBar (+Expanded), MSI, Code 11, Industrial 2-of-5, Telepen.
  oneD,

  /// Matrix codes: QR, Data Matrix, Aztec, PDF417, MaxiCode (UPS).
  twoD,

  /// Postal codes: POSTNET, PLANET, RM4SCC, KIX.
  postal,

  /// Pharmacode one- & two-track. Explicit-only: one-track has no checksum
  /// or structure, so scanning it alongside other formats would constantly
  /// false-positive.
  pharma,

  /// Everything except Pharmacode (see [pharma]).
  all;

  /// The formats this kind scans for.
  Set<CodeFormat> get formats => switch (this) {
    qr => const {CodeFormat.qrCode},
    oneD => CodeFormat.values.where((f) => f.is1D && !f.isPharma).toSet(),
    twoD => CodeFormat.values.where((f) => f.is2D).toSet(),
    postal => CodeFormat.values.where((f) => f.isPostal).toSet(),
    pharma => const {CodeFormat.pharmacode, CodeFormat.pharmacodeTwoTrack},
    all => CodeFormat.values.where((f) => !f.isPharma).toSet(),
  };

  String get label => switch (this) {
    qr => 'QR',
    oneD => '1D',
    twoD => '2D',
    postal => 'POST',
    pharma => 'RX',
    all => 'ALL',
  };
}

/// A decoded code.
class CodeResult {
  final String text;
  final CodeFormat format;

  /// Frame timestamp (ms) the code was decoded from, when known.
  final int timestamp;

  /// Whether the symbol carries GS1-structured data: GS1 DataBar (always),
  /// GS1-128 / GS1 DataMatrix / GS1 QR (detected from the symbology
  /// identifier, e.g. `]C1`, `]d2`, `]Q3`, `]e0`).
  final bool isGs1;

  /// Detected key points of the symbol, as flat `[x0,y0, x1,y1, …]` pairs
  /// **normalized to the scan window as displayed** (0..1, origin top-left of
  /// the upright viewfinder — the frame's sensor rotation and front-camera
  /// mirror are already applied, so these paint directly over the preview).
  /// 1D codes yield the two scanline endpoints; QR yields its finder
  /// patterns. Null when the engine doesn't report points (postal/width
  /// decoders).
  final List<double>? windowPoints;

  const CodeResult(
    this.text,
    this.format, {
    this.timestamp = 0,
    this.isGs1 = false,
    this.windowPoints,
  });

  /// The ISBN when this is a Bookland EAN-13 (978/979 prefix), else null.
  String? get isbn {
    if (format != CodeFormat.ean13) return null;
    if (!(text.startsWith('978') || text.startsWith('979'))) return null;
    return text;
  }

  @override
  String toString() => '${format.name}${isGs1 ? '·GS1' : ''}: $text';
}

/// A raw engine decode: text + symbology (no frame metadata yet).
class RawDecode {
  final String text;
  final CodeFormat format;
  final bool isGs1;

  /// Key points in the DECODED bitmap's pixel space (flat x,y pairs).
  final List<double>? points;

  const RawDecode(this.text, this.format, {this.isGs1 = false, this.points});
}

/// How a [CodeScanner] delivers results.
enum ScanMode {
  /// Keep scanning; every confirmed code is emitted (deduplicated by a
  /// per-payload cooldown).
  continuous,

  /// Stop after the first confirmed code. Call `CodeScanner.resume()` to arm
  /// the next scan.
  oneShot,
}
