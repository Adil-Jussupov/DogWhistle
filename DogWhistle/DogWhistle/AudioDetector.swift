//
//  AudioListener.swift
//  DogWhistle
//
//  Created by Adil on 7/26/25.
//

import Foundation
import AVFoundation
import Accelerate

class AudioDetector: ObservableObject {
    private let engine = AVAudioEngine()
    private let fftSize = 4096
    private let sampleRate: Double = 44100
    private let minFreq: Double = 17000
    private var isRunning = false

    @Published var signalDetected = false
    private var debounceTimer: Timer?

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Configure mic input
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setPreferredSampleRate(sampleRate)
            try session.setActive(true)
        } catch {
            print("❌ AVAudioSession error: \(error)")
            return
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: format) { buffer, _ in
            self.analyze(buffer: buffer)
        }

        do {
            try engine.start()
            print("🎧 Listening for >17kHz...")
        } catch {
            print("❌ Engine start error: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        signalDetected = false
    }

    private func analyze(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)

                channelData.withMemoryRebound(to: DSPComplex.self, capacity: fftSize) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                }

                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                var magnitudes = [Float](repeating: 0.0, count: fftSize / 2)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))

                let freqResolution = sampleRate / Double(fftSize)
                let minIndex = Int(minFreq / freqResolution)
                let threshold: Float = 10.0

                let rangeMagnitudes = magnitudes[minIndex..<magnitudes.count]
                let maxMagnitude = rangeMagnitudes.max() ?? 0

                if maxMagnitude > threshold {
                    DispatchQueue.main.async {
                        self.signalDetected = true
                        self.debounceTimer?.invalidate()
                        self.debounceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
                            self.signalDetected = false
                        }
                    }
                }
            }
        }

        vDSP_destroy_fftsetup(fftSetup)
    }
}
