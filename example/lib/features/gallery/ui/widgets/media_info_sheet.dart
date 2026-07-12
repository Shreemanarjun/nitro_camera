import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../services/capture_storage.dart';
import '../video_player_page.dart';
import 'media_tile.dart';

/// Opens the dark-glass INFO sheet for a gallery item.
Future<void> showMediaInfoSheet(
  BuildContext context,
  MediaEntry item, {
  VideoMeta? videoMeta,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => MediaInfoSheet(item: item, videoMeta: videoMeta),
  );
}

class MediaInfoSheet extends StatefulWidget {
  const MediaInfoSheet({super.key, required this.item, this.videoMeta});

  final MediaEntry item;
  final VideoMeta? videoMeta;

  @override
  State<MediaInfoSheet> createState() => _MediaInfoSheetState();
}

class _MediaInfoSheetState extends State<MediaInfoSheet> {
  late final Future<_MediaDetails> _details = _load();

  Future<_MediaDetails> _load() async {
    final item = widget.item;
    final file = File(item.path);
    int size = 0;
    DateTime? date;
    try {
      final stat = await file.stat();
      size = stat.size;
      date = stat.modified;
    } catch (_) {}

    int? w = widget.videoMeta?.width;
    int? h = widget.videoMeta?.height;
    final rows = <(String, String)>[];

    if (!item.isVideo) {
      try {
        final bytes = await file.readAsBytes();
        if (w == null || h == null) {
          (w, h) = await _decodeDimensions(bytes) ?? (null, null);
        }
        rows.addAll(await _exifHighlights(bytes));
      } catch (_) {}
    }

    return _MediaDetails(
      sizeBytes: size,
      date: date,
      width: w,
      height: h,
      exifRows: rows,
    );
  }

  /// Header-only decode (no full bitmap) for photo dimensions.
  Future<(int, int)?> _decodeDimensions(Uint8List bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final dims = (descriptor.width, descriptor.height);
      descriptor.dispose();
      buffer.dispose();
      return dims;
    } catch (_) {
      return null; // e.g. DNG — no Flutter codec
    }
  }

  Future<List<(String, String)>> _exifHighlights(Uint8List bytes) async {
    final rows = <(String, String)>[];
    try {
      final tags = await readExifFromBytes(bytes);
      if (tags.isEmpty) return rows;

      final make = tags['Image Make']?.printable.trim();
      final model = tags['Image Model']?.printable.trim();
      final camera = [
        if (make != null && make.isNotEmpty) make,
        if (model != null && model.isNotEmpty) model,
      ].join(' ');
      if (camera.isNotEmpty) rows.add(('CAMERA', camera));

      final taken = tags['EXIF DateTimeOriginal']?.printable;
      if (taken != null && taken.isNotEmpty) rows.add(('CAPTURED', taken));

      final iso = tags['EXIF ISOSpeedRatings']?.printable;
      if (iso != null && iso.isNotEmpty) rows.add(('ISO', iso));

      final exposure = tags['EXIF ExposureTime']?.printable;
      if (exposure != null && exposure.isNotEmpty) {
        rows.add(('SHUTTER', '${exposure}s'));
      }

      final fNumber = _firstRatio(tags['EXIF FNumber']);
      if (fNumber != null) {
        rows.add(('APERTURE', 'f/${fNumber.toStringAsFixed(1)}'));
      }

      final focal = _firstRatio(tags['EXIF FocalLength']);
      if (focal != null) {
        rows.add(('FOCAL LENGTH', '${focal.toStringAsFixed(1)} mm'));
      }

      final lat = _gpsToDecimal(
        tags['GPS GPSLatitude'],
        tags['GPS GPSLatitudeRef'],
      );
      final lng = _gpsToDecimal(
        tags['GPS GPSLongitude'],
        tags['GPS GPSLongitudeRef'],
      );
      if (lat != null && lng != null) {
        rows.add((
          'GPS',
          '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}',
        ));
      }
    } catch (_) {}
    return rows;
  }

  double? _firstRatio(IfdTag? tag) {
    final values = tag?.values.toList();
    if (values == null || values.isEmpty) return null;
    return _toDouble(values.first);
  }

  double? _gpsToDecimal(IfdTag? tag, IfdTag? ref) {
    final values = tag?.values.toList();
    if (values == null || values.length < 3) return null;
    final d = _toDouble(values[0]);
    final m = _toDouble(values[1]);
    final s = _toDouble(values[2]);
    if (d == null || m == null || s == null) return null;
    var degrees = d + m / 60 + s / 3600;
    final direction = ref?.printable.trim().toUpperCase();
    if (direction == 'S' || direction == 'W') degrees = -degrees;
    return degrees;
  }

  double? _toDouble(Object? v) {
    if (v is Ratio) return v.toDouble();
    if (v is num) return v.toDouble();
    return null;
  }

  String _typeLabel() {
    final ext = p.extension(widget.item.path).toLowerCase();
    if (widget.item.isVideo) {
      return '${ext.replaceFirst('.', '').toUpperCase()} VIDEO';
    }
    if (CaptureStorage.isRawPath(widget.item.path)) return 'RAW (DNG) PHOTO';
    return '${ext.replaceFirst('.', '').toUpperCase()} PHOTO';
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String formatDate(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            color: const Color(0xF20E1215),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: FutureBuilder<_MediaDetails>(
              future: _details,
              builder: (context, snap) {
                final d = snap.data;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Icon(
                          item.isVideo
                              ? Icons.videocam_rounded
                              : Icons.photo_rounded,
                          color: Colors.cyanAccent,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            p.basename(item.path),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Divider(
                      color: Colors.white.withValues(alpha: 0.08),
                      height: 1,
                    ),
                    const SizedBox(height: 12),
                    if (d == null)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(
                            color: Colors.cyanAccent,
                            strokeWidth: 2,
                          ),
                        ),
                      )
                    else ...[
                      _InfoRow(label: 'TYPE', value: _typeLabel()),
                      if (d.width != null && d.height != null)
                        _InfoRow(
                          label: 'RESOLUTION',
                          value: '${d.width} × ${d.height}',
                        ),
                      if (item.isVideo && widget.videoMeta != null)
                        _InfoRow(
                          label: 'DURATION',
                          value: formatClipDuration(widget.videoMeta!.duration),
                        ),
                      _InfoRow(label: 'SIZE', value: formatBytes(d.sizeBytes)),
                      if (d.date != null)
                        _InfoRow(label: 'DATE', value: formatDate(d.date!)),
                      if (d.exifRows.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        const Text(
                          'EXIF',
                          style: TextStyle(
                            color: Colors.cyanAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 6),
                        for (final (label, value) in d.exifRows)
                          _InfoRow(label: label, value: value),
                      ],
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaDetails {
  const _MediaDetails({
    required this.sizeBytes,
    required this.date,
    required this.width,
    required this.height,
    required this.exifRows,
  });

  final int sizeBytes;
  final DateTime? date;
  final int? width;
  final int? height;
  final List<(String, String)> exifRows;
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
