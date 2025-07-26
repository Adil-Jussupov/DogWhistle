//
//  AudioEngineManager.swift
//  DogWhistle
//
//  Created by Adil on 7/26/25.
//

import Foundation
import AVFoundation
import Accelerate
import UserNotifications

class AudioEngineManager: ObservableObject {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var audioFormat: AVAudioFormat!
    
    private let sampleRate: Double = 44100
    private let frequency: Double = 19000
    private var buffer: AVAudioPCMBuffer!
    private var fftSize = 2048
    
    private var lastDetectionTime: Date?
    private let silenceThreshold: TimeInterval = 4.0
    
    private var isRecording = false
    private var recorder: AVAudioRecorder?

    @Published var needsConsent = false
    @Published var recordedFileURL: URL?

    func start() {
        requestNotificationPermission()
        startEmitter()
        startListener()
    }

    func stop() {
        engine.stop()
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        stopRecording()
    }

    // MARK: - Emitter
    private func startEmitter() {
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        audioFormat = outputFormat

        let frameCount = AVAudioFrameCount(outputFormat.sampleRate)
        buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            let theta = 2.0 * Double.pi * frequency * Double(i) / outputFormat.sampleRate
            samples[i] = Float(sin(theta))
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            print("🔊 Emitting tone at \(frequency) Hz")
        } catch {
            print("❌ Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    // MARK: - Listener
    private func startListener() {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: format) { buffer, _ in
            self.analyzeBuffer(buffer: buffer)
        }
    }

    private func analyzeBuffer(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)

                channelData.withMemoryRebound(to: DSPComplex.self, capacity: fftSize) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                }

                var magnitudes = [Float](repeating: 0.0, count: fftSize / 2)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))

                let freqIndex = Int(frequency / sampleRate * Double(fftSize))
                let magnitude = magnitudes[freqIndex]

                DispatchQueue.main.async {
                    if magnitude > 100.0 {
                        self.lastDetectionTime = Date()
                        if !self.isRecording {
                            self.startRecording()
                        }
                    } else {
                        if let lastTime = self.lastDetectionTime,
                           Date().timeIntervalSince(lastTime) > self.silenceThreshold {
                            if self.isRecording {
                                self.stopRecording()
                                self.sendConsentNotification()
                            }
                        }
                    }
                }
            }
        }
    }


    // MARK: - Recorder
    private func startRecording() {
        let filename = UUID().uuidString + ".m4a"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.prepareToRecord()
            recorder?.record()
            isRecording = true
            print("🎙 Started recording")
        } catch {
            print("❌ Failed to start recorder: \(error)")
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recordedFileURL = recorder?.url
        isRecording = false
        print("🛑 Recording stopped at \(String(describing: recorder?.url))")
        needsConsent = true
    }

    // MARK: - Local Notification
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted {
                print("🔔 Notification permission granted.")
            }
        }
    }

    private func sendConsentNotification() {
        let content = UNMutableNotificationContent()
        content.title = "DogWhistle"
        content.body = "Conversation ended. Tap to review and give AI consent."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
