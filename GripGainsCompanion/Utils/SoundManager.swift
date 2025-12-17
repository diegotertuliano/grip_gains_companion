import AVFoundation
import AudioToolbox

/// Manages audio feedback for target weight alerts
enum SoundManager {
    private static var toneGenerator: ToneGenerator?
    private static var audioSessionConfigured = false

    private static func configureAudioSession() {
        guard !audioSessionConfigured else { return }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, options: [.mixWithOthers])
            try audioSession.setActive(true)
            audioSessionConfigured = true
        } catch {
            Log.app.error("Failed to configure audio session: \(error.localizedDescription)")
        }
    }

    /// Play a warning tone (medium pitch) for general off-target alert
    static func playWarningTone() {
        playTone(frequency: 880, duration: 0.15) // A5
    }

    /// Play a high tone indicating weight is too heavy
    static func playHighTone() {
        playTone(frequency: 1320, duration: 0.15) // E6
    }

    /// Play a low tone indicating weight is too light
    static func playLowTone() {
        playTone(frequency: 440, duration: 0.15) // A4
    }

    private static func playTone(frequency: Double, duration: Double) {
        configureAudioSession()

        // Create a new generator for each tone to allow overlapping sounds
        let generator = ToneGenerator()
        generator.play(frequency: frequency, duration: duration)

        // Keep reference to prevent deallocation during playback
        toneGenerator = generator
    }
}

/// Generates sine wave tones using AVAudioEngine
private class ToneGenerator {
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    func play(frequency: Double, duration: Double) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)

        let mixer = engine.mainMixerNode
        let sampleRate = mixer.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        engine.connect(player, to: mixer, format: format)

        // Generate sine wave samples
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let data = buffer.floatChannelData![0]
        let amplitude: Float = 0.3

        for i in 0..<Int(frameCount) {
            let phase = Double(i) / sampleRate * frequency * 2.0 * .pi
            // Apply envelope to avoid clicks
            let envelope = min(1.0, min(Double(i) / (sampleRate * 0.01), Double(Int(frameCount) - i) / (sampleRate * 0.01)))
            data[i] = Float(sin(phase) * envelope) * amplitude
        }

        do {
            try engine.start()
            player.play()
            player.scheduleBuffer(buffer, completionHandler: nil)

            // Keep references during playback
            self.audioEngine = engine
            self.playerNode = player

            // Stop after duration
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
                player.stop()
                engine.stop()
                self?.audioEngine = nil
                self?.playerNode = nil
            }
        } catch {
            Log.app.error("Failed to play tone: \(error.localizedDescription)")
        }
    }
}
