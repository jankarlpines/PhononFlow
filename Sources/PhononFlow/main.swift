import Cocoa
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case idle, recording(handsFree: Bool, start: Date), transcribing }

    private var statusItem: NSStatusItem!
    private let overlay = OverlayController()
    private let recorder = Recorder()
    private let server = PhononServer()
    private let monitor = HotkeyMonitor(hotkey: Hotkey.load())
    private var state: State = .idle
    private var serverStatus = "Starting…"
    private var axTimer: Timer?
    private let startSound: NSSound? = {
        let s = NSSound(named: "Tink")
        s?.volume = 0.5
        return s
    }()
    private let stopSound: NSSound? = {
        let s = NSSound(named: "Pop")
        s?.volume = 0.45
        return s
    }()

    /// A quick tap (shorter than this) switches to hands-free; holding longer is push-to-talk.
    private let tapThreshold: TimeInterval = 0.3

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        server.onStatus = { [weak self] s in DispatchQueue.main.async { self?.serverStatus = s } }
        server.start()

        overlay.levelSource = { [weak self] in self?.recorder.takePeak() ?? 0 }

        monitor.onPress = { [weak self] in self?.hotkeyPressed() }
        monitor.onRelease = { [weak self] in self?.hotkeyReleased() }
        monitor.onOtherKey = { [weak self] in
            guard let self, case .recording(false, _) = self.state else { return }
            self.cancel()
        }
        monitor.onEscape = { [weak self] in
            guard let self, case .recording = self.state else { return false }
            self.cancel()
            return true
        }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        startHotkeyMonitor(prompt: true)
    }

    func applicationWillTerminate(_ note: Notification) { server.stop() }

    // MARK: Accessibility / hotkey

    private func startHotkeyMonitor(prompt: Bool) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts), monitor.start() { axTimer?.invalidate(); return }
        guard axTimer == nil else { return }
        axTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, AXIsProcessTrusted(), self.monitor.start() else { return }
            self.axTimer?.invalidate()
            self.axTimer = nil
        }
    }

    // MARK: Dictation flow

    private func hotkeyPressed() {
        switch state {
        case .idle: startRecording()
        case .recording(true, _): finish()
        default: break
        }
    }

    private func hotkeyReleased() {
        guard case .recording(false, let start) = state else { return }
        if Date().timeIntervalSince(start) < tapThreshold {
            state = .recording(handsFree: true, start: start)
            overlay.show(.handsFree)
        } else {
            finish()
        }
    }

    private func startRecording() {
        do {
            try recorder.start()
        } catch {
            overlay.flash("No microphone available")
            return
        }
        state = .recording(handsFree: false, start: Date())
        startSound?.stop()
        startSound?.play()
        setIcon(recording: true)
        overlay.startMeter()
        overlay.show(.listening)
        overlay.buzz()
    }

    private func cancel() {
        _ = recorder.stop()
        overlay.stopMeter()
        state = .idle
        setIcon(recording: false)
        overlay.hide()
    }

    private func finish() {
        state = .transcribing
        overlay.stopMeter()
        stopSound?.stop()
        stopSound?.play()
        overlay.show(.transcribing)
        overlay.buzz()
        // Keep a short tail so the last word isn't clipped when the key comes up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            let samples = recorder.stop()
            setIcon(recording: false)
            guard samples.count > 16000 / 4 else { state = .idle; overlay.hide(); return }
            let wav = Recorder.wav(samples)
            Task { @MainActor in
                do {
                    let text = try await server.transcribe(wav: wav).trimmingCharacters(in: .whitespacesAndNewlines)
                    overlay.hide()
                    if !text.isEmpty { Paster.insert(text + " ") }
                } catch {
                    overlay.flash(server.ready ? "Transcription failed" : "Model still loading")
                }
                state = .idle
            }
        }
    }

    private func setIcon(recording: Bool) {
        let name = recording ? "waveform.circle.fill" : "waveform"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "PhononFlow")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: "Phonon-2 · \(serverStatus)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if !AXIsProcessTrusted() {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAccessibility)))
        }
        let hk = item("Hotkey: \(monitor.hotkey.display)   Change…", #selector(changeHotkey))
        menu.addItem(hk)

        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func changeHotkey() {
        guard monitor.isRunning else { openAccessibility(); return }
        if case .recording = state { cancel() }
        overlay.show(.message("Press a new hotkey…  (esc to cancel)"))
        monitor.capture { [weak self] hk in
            guard let self else { return }
            if let hk {
                self.monitor.hotkey = hk
                hk.save()
                self.overlay.flash("Hotkey set: \(hk.display)")
            } else {
                self.overlay.hide()
            }
        }
    }

    @objc private func openAccessibility() {
        startHotkeyMonitor(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            overlay.flash("Couldn't change login item")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
