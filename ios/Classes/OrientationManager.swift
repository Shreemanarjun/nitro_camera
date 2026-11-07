import Foundation
import UIKit

/// Physical-orientation observation → 0/90/180/270 degrees.
///
/// UIDevice orientation notifications report the SENSOR-measured device
/// rotation even when the UI orientation is locked — mapped to degrees and
/// emitted only on change (faceUp/faceDown/unknown are ignored).
///
/// vision-camera analogue: ios/Hybrid Objects/Orientation/HybridDeviceOrientationManager.swift
/// (theirs samples CMMotionManager's accelerometer; UIDevice notifications give
/// the same sensor-driven answer without polling).
final class OrientationManager {

    /// Emits the new orientation in degrees (0/90/180/270) on change (main queue).
    var onOrientationChanged: ((Int64) -> Void)?

    private var observer: NSObjectProtocol?
    private var lastOrientationDeg: Int64 = -1

    func setEnabled(_ enabled: Bool) {
        // UIDevice orientation generation + notification delivery live on main.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if enabled {
                guard self.observer == nil else { return }
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                self.observer = NotificationCenter.default.addObserver(
                    forName: UIDevice.orientationDidChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.emitIfChanged()
                }
                // Emit the current orientation now (vision-camera #4150): the
                // notification only fires on a change, so a new subscriber of
                // a phone held still would otherwise never learn it.
                self.emitIfChanged()
            } else {
                guard let observer = self.observer else { return }
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
                self.lastOrientationDeg = -1
            }
        }
    }

    /// Main queue only. faceUp / faceDown / unknown are skipped.
    private func emitIfChanged() {
        let degrees: Int64
        switch UIDevice.current.orientation {
        case .portrait:           degrees = 0
        case .landscapeLeft:      degrees = 90
        case .portraitUpsideDown: degrees = 180
        case .landscapeRight:     degrees = 270
        default:                  return
        }
        guard degrees != lastOrientationDeg else { return }
        lastOrientationDeg = degrees
        onOrientationChanged?(degrees)
    }
}
