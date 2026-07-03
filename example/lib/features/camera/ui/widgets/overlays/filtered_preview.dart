import 'dart:io';

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../../state/camera_store.dart';

/// Applies the selected preview filter as a Flutter-layer effect on iOS (Android
/// filters run in the native GL renderer). Four filters are pure per-pixel color
/// transforms (expressible as a [ColorFilter.matrix]); VIGNETTE is a radial
/// darkening overlay. Colour-matrix offsets are in 0–255 space.
class FilteredPreview extends StatelessWidget {
  final Widget child;
  const FilteredPreview({super.key, required this.child});

  static const Map<String, List<double>> _matrices = {
    'INVERT': [
      -1, 0, 0, 0, 255, //
      0, -1, 0, 0, 255, //
      0, 0, -1, 0, 255, //
      0, 0, 0, 1, 0,
    ],
    'GRAYSCALE': [
      0.299, 0.587, 0.114, 0, 0, //
      0.299, 0.587, 0.114, 0, 0, //
      0.299, 0.587, 0.114, 0, 0, //
      0, 0, 0, 1, 0,
    ],
    'SEPIA': [
      0.393, 0.769, 0.189, 0, 0, //
      0.349, 0.686, 0.168, 0, 0, //
      0.272, 0.534, 0.131, 0, 0, //
      0, 0, 0, 1, 0,
    ],
    // mix(blue,pink,luma): R=luma, G=1-luma, B=1
    'CYBERPUNK': [
      0.299, 0.587, 0.114, 0, 0, //
      -0.299, -0.587, -0.114, 0, 255, //
      0, 0, 0, 0, 255, //
      0, 0, 0, 1, 0,
    ],
  };

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) return child; // Android: native GL filter.
    return Watch((_) {
      final name = cameraStore.currentFilterName.value;
      Widget out = child;
      final matrix = _matrices[name];
      if (matrix != null) {
        out = ColorFiltered(
          colorFilter: ColorFilter.matrix(matrix),
          child: out,
        );
      }
      if (name == 'VIGNETTE') {
        out = Stack(
          fit: StackFit.expand,
          children: [
            out,
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  radius: 1.0,
                  colors: [Colors.transparent, Colors.black],
                  stops: [0.55, 1.0],
                ),
              ),
            ),
          ],
        );
      }
      return out;
    });
  }
}
