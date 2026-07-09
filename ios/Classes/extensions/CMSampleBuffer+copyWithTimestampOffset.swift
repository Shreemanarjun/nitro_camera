import CoreMedia
import Foundation

// vision-camera analogue: ios/Extensions/CoreMedia/CMSampleBuffer+copyWithTimestampOffset.swift
// (theirs throws a dedicated TimestampAdjustmentError; we keep the shared
// CameraError domain — same failure behavior, one error type fewer).

extension CMSampleBuffer {
    /// Returns a copy of this sample buffer with presentation AND decode
    /// timestamps shifted by [offset]. Used to close the pause gap in a
    /// recording's timeline (encoders render an un-shifted gap as frozen video).
    func copyWithTimestampOffset(_ offset: CMTime) throws -> CMSampleBuffer {
        var count: CMItemCount = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(
            self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard status == noErr, count > 0 else { throw CameraError.captureFailed }

        var infos = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(duration: .invalid,
                                          presentationTimeStamp: .invalid,
                                          decodeTimeStamp: .invalid),
            count: count)
        status = CMSampleBufferGetSampleTimingInfoArray(
            self, entryCount: count, arrayToFill: &infos, entriesNeededOut: nil)
        guard status == noErr else { throw CameraError.captureFailed }

        let shifted = infos.map { info in
            CMSampleTimingInfo(
                duration: info.duration,
                presentationTimeStamp: CMTimeAdd(info.presentationTimeStamp, offset),
                decodeTimeStamp: info.decodeTimeStamp.isValid
                    ? CMTimeAdd(info.decodeTimeStamp, offset) : info.decodeTimeStamp)
        }
        var copy: CMSampleBuffer?
        status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: self,
            sampleTimingEntryCount: shifted.count, sampleTimingArray: shifted,
            sampleBufferOut: &copy)
        guard status == noErr, let copy = copy else { throw CameraError.captureFailed }
        return copy
    }
}
