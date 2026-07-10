//
//  AudioAndHapticEngine.swift
//  TrueDepthFusion
//
//  Created by Aaron Thompson on 8/22/18.
//

import AudioToolbox
import Foundation
import UIKit
import AudioToolbox

final class SoundEffect {
    private var soundID: SystemSoundID = 0

    init?(soundNamed name: String, type: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: type) else {
            return nil
        }
        AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
    }

    deinit {
        AudioServicesDisposeSystemSoundID(soundID)
    }

    func play() {
        AudioServicesPlaySystemSound(soundID)
    }
}

class AudioAndHapticEngine {
    
    static let shared = AudioAndHapticEngine()
    
    init() {
        [
            _hapticImpactMedium,
            _hapticSelection,
            _hapticNotification
        ].forEach { $0.prepare() }
    }
    
    func countdownCountedDown() {
        _hapticImpactMedium.impactOccurred()
        _countdownSoundEffect?.play()
    }
    
    func scanningBegan() {
        _startScanningTimer()
        _scanningBeganEffect?.play()
    }
    
    func scanningFinished() {
        _stopScanningTimer()
        
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + .milliseconds(100)) {
            self._hapticNotification.notificationOccurred(UINotificationFeedbackGenerator.FeedbackType.success)
            self._scanningFinishedEffect?.play()
        }
    }
    
    func scanningCanceled() {
        _stopScanningTimer()
        
        _hapticNotification.notificationOccurred(UINotificationFeedbackGenerator.FeedbackType.error)
        _scanningCanceledEffect?.play()
    }
    
    // MARK: - Private
    
    private let _countdownSoundEffect = SoundEffect(soundNamed: "Countdown", type: "m4a")
    private let _scanningBeganEffect = SoundEffect(soundNamed: "ScanningBegan", type: "m4a")
    private let _scanningContinuedEffect = SoundEffect(soundNamed: "ScanningContinued", type: "wav")
    private let _scanningFinishedEffect = SoundEffect(soundNamed: "ScanningFinished", type: "m4a")
    private let _scanningCanceledEffect = SoundEffect(soundNamed: "ScanningCanceled", type: "m4a")
    
    private let _hapticImpactMedium = UIImpactFeedbackGenerator(style: UIImpactFeedbackGenerator.FeedbackStyle.medium)
    private let _hapticSelection = UISelectionFeedbackGenerator()
    private let _hapticNotification = UINotificationFeedbackGenerator()
    
    private let _scanningTimerInterval = 1.0 / 10.0
    private var _scanningTimer: Timer?
    
    private func _startScanningTimer() {
        _scanningTimer = Timer.scheduledTimer(withTimeInterval: _scanningTimerInterval, repeats: true, block: { [weak self] timer in
            self?._hapticSelection.selectionChanged()
            // It really feels better without the sound effect
            // self?._scanningContinuedEffect.play()
        })
    }
    
    private func _stopScanningTimer() {
        _scanningTimer?.invalidate()
        _scanningTimer = nil
    }

}
