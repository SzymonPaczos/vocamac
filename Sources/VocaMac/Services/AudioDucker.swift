// AudioDucker.swift
// VocaMac
//
// Lowers the system output volume while a recording is open so music or a
// video does not play at full volume into the microphone, then puts it back
// the way it was. Apple's own dictation ducks other audio; macOS offers no
// per-process ducking to third parties, so this drives the default output
// device's main volume — the same control as the volume keys.

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - OutputVolumeControlling

/// The default output device and its main volume in `0...1`.
struct OutputVolumeSnapshot: Equatable {
    let deviceID: AudioDeviceID
    let volume: Float
}

/// The CoreAudio surface `AudioDucker` depends on, kept behind a protocol so
/// the ducking policy can be tested without touching real hardware.
protocol OutputVolumeControlling: AnyObject {
    /// The default output device with its current main volume, or `nil` when
    /// that device has no software-settable volume (HDMI and some AirPlay
    /// outputs) — ducking is then impossible and silently skipped.
    func defaultOutput() -> OutputVolumeSnapshot?

    /// The main volume of a specific device, or `nil` if the device is gone
    /// or has no software volume.
    func volume(of deviceID: AudioDeviceID) -> Float?

    /// Sets the main volume of a specific device. Returns `false` on failure.
    @discardableResult
    func setVolume(_ volume: Float, of deviceID: AudioDeviceID) -> Bool
}

// MARK: - SystemOutputVolumeControl

/// CoreAudio implementation of `OutputVolumeControlling`. Not unit-tested:
/// it is thin, and its behaviour depends on the output device in use.
final class SystemOutputVolumeControl: OutputVolumeControlling {

    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    func defaultOutput() -> OutputVolumeSnapshot? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        guard let volume = volume(of: deviceID) else { return nil }
        return OutputVolumeSnapshot(deviceID: deviceID, volume: volume)
    }

    func volume(of deviceID: AudioDeviceID) -> Float? {
        guard AudioObjectHasProperty(deviceID, &volumeAddress) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &volumeAddress, &settable) == noErr,
              settable.boolValue else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &volumeAddress, 0, nil, &size, &volume) == noErr else {
            return nil
        }
        return volume
    }

    @discardableResult
    func setVolume(_ volume: Float, of deviceID: AudioDeviceID) -> Bool {
        var value = Float32(min(max(volume, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &volumeAddress, 0, nil, size, &value) == noErr
    }
}

// MARK: - AudioDucker

/// Ducks the default output for the duration of a recording and restores it
/// afterwards. The volume is shared system state, so the rules are
/// conservative: restore only what was lowered, only on the device it was
/// lowered on, and only if nobody moved the slider in between.
///
/// The pending restore is also persisted, so a crash mid-dictation does not
/// leave the Mac quiet: the next launch calls `restoreAfterUnexpectedExit()`.
final class AudioDucker: AudioDucking {

    /// What `restore()` needs: where the volume was, and where it was put.
    struct PendingRestore: Codable, Equatable {
        let deviceID: UInt32
        let originalVolume: Float
        let duckedVolume: Float
    }

    static let pendingRestoreKey = "vocamac.duckOtherAudio.pendingRestore"

    /// Fraction of the current volume kept while dictating. Loud enough to
    /// keep following a video, quiet enough not to reach the microphone.
    static let duckedFraction: Float = 0.25

    /// Volumes closer than this count as untouched. CoreAudio may hand back
    /// a value that differs from what was set by float rounding.
    static let volumeTolerance: Float = 0.01

    private let control: OutputVolumeControlling
    private let defaults: UserDefaults
    private var pending: PendingRestore?

    init(
        control: OutputVolumeControlling = SystemOutputVolumeControl(),
        defaults: UserDefaults = .standard
    ) {
        self.control = control
        self.defaults = defaults
    }

    // MARK: AudioDucking

    func duck() {
        guard pending == nil else {
            VocaLogger.debug(.audioDucker, "Already ducked — ignoring second duck")
            return
        }
        guard let output = control.defaultOutput() else {
            VocaLogger.info(.audioDucker, "Default output has no software volume — not ducking")
            return
        }
        let target = output.volume * Self.duckedFraction
        guard output.volume - target > Self.volumeTolerance else {
            VocaLogger.debug(.audioDucker, "Output already at \(Self.percent(output.volume)) — nothing to duck")
            return
        }
        guard control.setVolume(target, of: output.deviceID) else {
            VocaLogger.warning(.audioDucker, "Could not set volume on device \(output.deviceID)")
            return
        }
        let record = PendingRestore(
            deviceID: output.deviceID,
            originalVolume: output.volume,
            duckedVolume: target
        )
        pending = record
        persist(record)
        VocaLogger.info(
            .audioDucker,
            "Ducked device \(output.deviceID): \(Self.percent(output.volume)) → \(Self.percent(target))"
        )
    }

    func restore() {
        guard let record = pending else { return }
        if finishRestore(record, reason: "recording ended") {
            pending = nil
            clearPersisted()
        }
    }

    func restoreAfterUnexpectedExit() {
        guard pending == nil, let record = loadPersisted() else { return }
        if finishRestore(record, reason: "previous run ended while ducked") {
            pending = nil
            clearPersisted()
        } else {
            pending = record
        }
    }

    // MARK: Restore policy

    /// Applies the restore policy for `record`.
    /// - Returns: `true` when the pending record may be discarded, `false` when
    ///   it must be kept so a later retry can still restore the original volume.
    ///
    /// Discard (`true`) when the restore write succeeded, or the user moved
    /// the volume outside ducked tolerance.
    /// Keep (`false`) when `setVolume` failed while still at the ducked volume,
    /// or `volume(of:)` returned nil (device unreadability / transient failure).
    private func finishRestore(_ record: PendingRestore, reason: String) -> Bool {
        guard let current = control.volume(of: record.deviceID) else {
            VocaLogger.warning(
                .audioDucker,
                "Could not read volume on device \(record.deviceID) — keeping pending restore for retry (\(reason))"
            )
            return false
        }
        guard abs(current - record.duckedVolume) <= Self.volumeTolerance else {
            VocaLogger.info(
                .audioDucker,
                "Volume moved to \(Self.percent(current)) while ducked — leaving it alone (\(reason))"
            )
            return true
        }
        if control.setVolume(record.originalVolume, of: record.deviceID) {
            VocaLogger.info(
                .audioDucker,
                "Restored device \(record.deviceID) to \(Self.percent(record.originalVolume)) (\(reason))"
            )
            return true
        } else {
            VocaLogger.warning(.audioDucker, "Could not restore volume on device \(record.deviceID) (\(reason))")
            return false
        }
    }

    // MARK: Persistence

    /// Encodes `record` into UserDefaults so a crash mid-dictation can restore later.
    private func persist(_ record: PendingRestore) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.pendingRestoreKey)
    }

    /// Reads a pending restore left by a previous run, or `nil` if none.
    private func loadPersisted() -> PendingRestore? {
        guard let data = defaults.data(forKey: Self.pendingRestoreKey) else { return nil }
        return try? JSONDecoder().decode(PendingRestore.self, from: data)
    }

    /// Drops the persisted pending restore so a later launch will not restore again.
    private func clearPersisted() {
        defaults.removeObject(forKey: Self.pendingRestoreKey)
    }

    /// Formats `volume` as a whole-number percent for log lines.
    private static func percent(_ volume: Float) -> String {
        "\(Int((volume * 100).rounded()))%"
    }
}
