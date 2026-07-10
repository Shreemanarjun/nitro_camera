import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../../../state/camera_store.dart';

/// Read-back panel: the negotiated [ResolvedCameraConfig], the live
/// `getSessionState()`, and the rolling native event log. Demonstrates the
/// session-introspection + event-stream APIs.
class SessionPanel extends StatelessWidget {
  const SessionPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final s = cameraStore;
    return Watch((_) {
      final resolved = s.resolvedConfig.value;
      final events = s.sessionEvents.value;
      final state = s.sessionState(); // live getSessionState()
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Header('NEGOTIATED CONFIG'),
          Text(
            resolved == null
                ? '—'
                : '${resolved.videoWidth}×${resolved.videoHeight} @ ${resolved.selectedFps}fps'
                    ' · ${resolved.pixelFormat.name}'
                    ' · af:${resolved.autoFocusSystem.value}'
                    '${resolved.videoHdrEnabled ? ' · HDR' : ''}',
            style: _mono,
          ),
          const SizedBox(height: 10),
          const _Header('LIVE SESSION STATE'),
          Text(
            state == null
                ? '—'
                : 'running:${state.running} · ${state.width}×${state.height}'
                    ' @ ${state.fps}fps · ${state.pixelFormat.name}',
            style: _mono,
          ),
          const SizedBox(height: 10),
          const _Header('SESSION EVENTS'),
          if (events.isEmpty)
            const Text('no events yet', style: _mono)
          else
            ...events.reversed.take(6).map((e) => Text(
                  '• ${e.type.name}'
                  '${e.reason.name != 'none' ? ' (${e.reason.name})' : ''}'
                  '${e.message.isNotEmpty ? ': ${e.message}' : ''}',
                  style: TextStyle(
                    color: e.isError ? Colors.redAccent : Colors.white54,
                    fontSize: 9,
                    fontFamily: 'monospace',
                  ),
                )),
        ],
      );
    });
  }
}

const _mono = TextStyle(
  color: Colors.cyanAccent,
  fontSize: 10,
  fontFamily: 'monospace',
  fontWeight: FontWeight.w600,
);

class _Header extends StatelessWidget {
  final String title;
  const _Header(this.title);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4, top: 4),
        child: Text(title,
            style: const TextStyle(
                color: Colors.white30,
                fontSize: 8,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.4)),
      );
}
