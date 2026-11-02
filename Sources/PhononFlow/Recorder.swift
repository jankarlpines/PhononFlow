import AVFoundation

/// Captures the default mic as 16 kHz mono float samples.
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    /// 10 ms RMS levels waiting to be drawn, oldest first.
    private var levelQueue: [Float] = []

    /// Next level for a ~60 Hz display tick: replays the 10 ms levels in real time
    /// (≈1.7 per tick) and drops backlog so the meter never lags more than ~80 ms.
    func takePeak() -> Float {
        lock.lock(); defer { lock.unlock() }
        if levelQueue.count > 8 { levelQueue.removeFirst(levelQueue.count - 8) }
        let n = min(2, levelQueue.count)
        guard n > 0 else { return 0 }
        let v = levelQueue.prefix(n).max() ?? 0
        levelQueue.removeFirst(n)
        return v
    }

    struct NoInput: Error {}

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); levelQueue.removeAll(); lock.unlock()
        let input = engine.inputNode
        // Ask the input device for small (~5 ms) buffers so the meter reacts quickly.
        if let unit = input.audioUnit {
            var frames: UInt32 = 256
            AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                 &frames, UInt32(MemoryLayout<UInt32>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NoInput() }
        converter = AVAudioConverter(from: format, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 256, format: format) { [weak self] buf, _ in
            self?.process(buf)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        let n = Int(out.frameLength)
        guard n > 0, let ch = out.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch, count: n))
        // RMS per 10 ms so short syllables register instead of being averaged away.
        var chunkLevels: [Float] = []
        var i = 0
        while i < n {
            let end = min(i + 160, n)
            var sum: Float = 0
            for j in i..<end { sum += ch[j] * ch[j] }
            chunkLevels.append(sqrt(sum / Float(end - i)))
            i = end
        }
        lock.lock(); samples.append(contentsOf: chunk); levelQueue.append(contentsOf: chunkLevels); lock.unlock()
    }

    /// 16-bit PCM WAV, 16 kHz mono.
    static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let rate: UInt32 = 16000
        let dataSize = UInt32(samples.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataSize)
        d.reserveCapacity(d.count + samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }
}
