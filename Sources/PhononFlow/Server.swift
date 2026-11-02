import Foundation

/// Runs `phonon serve` in the background so Phonon-2 stays loaded, and talks to it over HTTP.
final class PhononServer {
    static let port = 8765
    let base = URL(string: "http://127.0.0.1:\(PhononServer.port)")!
    private var process: Process?
    private(set) var ready = false
    var onStatus: (String) -> Void = { _ in }

    private var phononPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/PhononFlow/.venv/bin/phonon"
    }

    func start() {
        Task {
            if await healthy() { setReady(); return }
            launch()
            onStatus("Loading model…")
            for _ in 0..<240 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if await healthy() { setReady(); return }
                if let p = process, !p.isRunning { break }
            }
            onStatus("Model failed to start — see ~/Library/Logs/PhononFlow-server.log")
        }
    }

    private func setReady() {
        ready = true
        onStatus("Ready")
    }

    private func launch() {
        guard FileManager.default.isExecutableFile(atPath: phononPath) else {
            onStatus("phonon not found at \(phononPath)")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: phononPath)
        p.arguments = ["serve", "--port", "\(PhononServer.port)", "--host", "127.0.0.1"]
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PhononFlow-server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = log
            p.standardError = log
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        do { try p.run(); process = p } catch { onStatus("Couldn't start phonon: \(error.localizedDescription)") }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    func healthy() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func transcribe(wav: Data) async throws -> String {
        // Wait (briefly) for the model if the user dictates during startup.
        for _ in 0..<120 where !ready { try await Task.sleep(nanoseconds: 250_000_000) }
        let boundary = "phononflow-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", "phonon-2")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: base.appendingPathComponent("v1/audio/transcriptions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.upload(for: req, from: body)
        struct Resp: Decodable { let text: String }
        return try JSONDecoder().decode(Resp.self, from: data).text
    }
}
