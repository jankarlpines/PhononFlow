# PhononFlow

A tiny Wispr Flow–style dictation app for macOS. Hold a hotkey, speak, and the text is typed where your cursor is, transcribed fully on-device by [Phonon-2](https://huggingface.co/FermionResearch/Phonon-2) (Fermion Research, MLX on Apple Silicon).

## Use

- **Hold the hotkey** (default `fn`) → talk → release: text is pasted at the cursor.
- **Tap the hotkey** → hands-free mode; tap again to stop.
- **Esc** cancels.
- Start/stop sounds plus a trackpad haptic; a small pill at the bottom of the screen shows a live, center-out waveform.
- Menu bar: model status, **Hotkey… Change**, **Launch at Login**, Quit. Hotkeys can be a lone modifier (fn, Right ⌥, …) or a combo (⌥Space, F5, …).

## Setup

Requires Apple Silicon, macOS 14+, Xcode command-line tools and [uv](https://github.com/astral-sh/uv).

```bash
git clone <this repo> ~/PhononFlow   # the app expects ~/PhononFlow/.venv/bin/phonon
cd ~/PhononFlow
./setup.sh          # installs Phonon-2 into .venv and builds the app
```

Then open `~/Applications/PhononFlow.app` and grant **Accessibility** (hotkey + paste) and **Microphone**. If you use `fn`, set System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**.

After code changes, run `./build.sh`.

## How it works

- `Server.swift` launches `phonon serve --port 8765` in the background to keep the model warm (~0.1 s per clip). Log: `~/Library/Logs/PhononFlow-server.log`.
- `Hotkey.swift`: a CGEvent tap for push-to-talk, hands-free, and hotkey capture.
- `Recorder.swift`: AVAudioEngine → 16 kHz mono WAV, plus 10 ms levels for the meter.
- `Overlay.swift`: the click-through SwiftUI pill.
- `Paster.swift`: clipboard + ⌘V, then restores the clipboard.

### Signing

`build.sh` signs with a self-signed identity named **"PhononFlow Local Signing"** if one is in your keychain, so macOS keeps the Accessibility grant across rebuilds. Without it, the app is signed ad-hoc and you'll need to re-grant Accessibility after every build. To create one:

```bash
cat > /tmp/pf.cfg <<'CFG'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=PhononFlow Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/pf.key -out /tmp/pf.pem -days 3650 -config /tmp/pf.cfg
openssl pkcs12 -export -legacy -inkey /tmp/pf.key -in /tmp/pf.pem -out /tmp/pf.p12 -passout pass:pf
security import /tmp/pf.p12 -k ~/Library/Keychains/login.keychain-db -P pf -T /usr/bin/codesign
rm /tmp/pf.key /tmp/pf.p12
```

## License

App code: MIT. Phonon-2 model: CC-BY-4.0 (Fermion Research, derived from NVIDIA Parakeet TDT 0.6B v3).
