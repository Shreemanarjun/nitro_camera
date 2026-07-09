import AVFoundation
import CoreMedia

/// Format negotiation: picks the best `AVCaptureDevice.Format` by summing
/// weighted constraint penalties (lower = better) — a faithful port of
/// vision-camera v5's constraint scoring.
///
/// vision-camera analogue: ios/Hybrid Objects/Constraints/ConstraintResolver.swift
/// (+ Constraints/ResolvableConstraint/*.swift for the per-constraint penalties).
enum ConstraintResolver {

    /// Priority order (higher weight dominates): resolution → fps → phase-detect
    /// autofocus → HDR-capable → high photo quality.
    ///
    /// Resolution penalty = `100 × relativeAspectDiff` (past a 2% tolerance) +
    /// `|ln(actualPixels / targetPixels)|` (scale-invariant). FPS penalty = 0 in
    /// range, else the raw fps-distance to the nearest supported range. The others
    /// are small integer penalties, so resolution + fps decide the winner and the
    /// rest break ties — exactly as upstream.
    static func bestFormat(
        for device: AVCaptureDevice,
        targetWidth: Int64,
        targetHeight: Int64,
        targetFps: Int64
    ) -> AVCaptureDevice.Format? {
        // Orientation-independent target (long/short edges).
        let targetLong = Double(max(targetWidth, targetHeight))
        let targetShort = Double(max(1, min(targetWidth, targetHeight)))
        let targetAspect = targetLong / targetShort
        let targetPixels = max(1, targetLong * targetShort)
        let desiredFps = Double(targetFps)

        // weight = (N - index) for constraints in priority order [res, fps, af, hdr, photoQ].
        let wRes = 5.0, wFps = 4.0, wAf = 3.0, wHdr = 2.0, wPhoto = 1.0

        func penalty(_ f: AVCaptureDevice.Format) -> Double {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let long = Double(max(dims.width, dims.height))
            let short = Double(max(1, min(dims.width, dims.height)))

            // Resolution: aspect (100× past 2% tolerance) + log-pixel distance.
            let aspectDiff = abs((long / short) - targetAspect) / targetAspect
            let aspectPenalty = aspectDiff < 0.02 ? 0.0 : 100.0 * aspectDiff
            let logPixel = abs(log((long * short) / targetPixels))
            var total = (aspectPenalty + logPixel) * wRes

            // FPS: 0 if inside a supported range, else nearest-range distance.
            if desiredFps > 0 {
                let fpsPenalty = f.videoSupportedFrameRateRanges.map { r -> Double in
                    if desiredFps >= r.minFrameRate && desiredFps <= r.maxFrameRate { return 0 }
                    return max(r.minFrameRate - desiredFps, desiredFps - r.maxFrameRate)
                }.min() ?? 1000
                total += fpsPenalty * wFps
            }

            // Phase-detection autofocus preference.
            if #available(iOS 13.0, *) {
                total += (f.autoFocusSystem == .phaseDetection ? 0.0 : 1.0) * wAf
            }
            // Prefer HDR-capable + high-quality-photo formats (so later toggles work).
            total += (f.isVideoHDRSupported ? 0.0 : 1.0) * wHdr
            if #available(iOS 15.0, *) {
                total += (f.isHighPhotoQualitySupported ? 0.0 : 1.0) * wPhoto
            }
            return total
        }

        return device.formats.min(by: { penalty($0) < penalty($1) })
    }
}
