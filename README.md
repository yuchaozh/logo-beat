# Logo Beat

A small macOS menu-bar app that makes the illuminated Apple logo on a
PROLED XDR MacBook Pro react to system playback audio.

**Experimental hardware-control software. Not affiliated with or supported by
Apple. Hardware safety is not guaranteed. Use at your own risk.**

## Requirements

- A MacBook Pro with the dedicated illuminated logo behind a PROLED XDR display.
  Older glowing-logo MacBooks are not supported.
- A compatible macOS version exposing the private CoreBrightness interface.
  Tested locally on a Mac17,12 running macOS 27.2; other models and versions
  are not verified.
- Xcode Command Line Tools, including an SDK with Core Audio process taps.
- Permission to capture system audio.

## Build and run

Quit any running copy of Logo Beat before rebuilding.

```bash
xcode-select --install  # Only if Command Line Tools are not already installed.
git clone https://github.com/yuchaozh/logo-beat.git
cd logo-beat
bash build.sh
open "$HOME/Applications/Logo Beat.app"
```

The build generates the icon, compiles the app, ad-hoc signs it, runs focused
self-tests, and refreshes its Launch Services registration. It installs the app
in `~/Applications/Logo Beat.app`. Generated build files are not tracked.
This is a local build, not a notarized release.

Allow the macOS audio-capture prompt. If necessary, enable Logo Beat under
**System Settings > Privacy & Security > Screen & System Audio Recording**,
then choose **Start** from the waveform icon in the menu bar.

## Controls

- **Start** listens to system playback and adjusts logo brightness. It is
  disabled while running.
- **Stop and restore** releases the audio tap and restores the saved logo
  brightness mapping. It is disabled while stopped unless restoration needs
  retrying.
- **Quit** restores the mapping before exiting. If restoration fails, the app
  stays open and preserves its backup.
- After sleep, screen sleep, or locking the Mac, choose **Start** to resume.
  Low Power Mode prevents starting.

The app starts listening when opened. Silence lasting more than one second
restores the normal brightness mapping while listening continues.

## Behavior, privacy, and limitations

Logo Beat uses a private `BrightnessSystemClient` interface from CoreBrightness.
It adjusts `LEPWMBrightnessNitsMapping`, requesting 12.5-300 nits with adaptive
audio sensitivity. Requests are not measured physical brightness; Apple's
ambient-light restrictions remain in place and can limit visible changes.
The app does not change screen brightness, PWM frequency, voltage, or the
device's calibration.

Only brightness control is implemented. The interface used by this app does
not expose logo color control.

Core Audio supplies a private, unmuted system playback tap. The microphone is
not used, playback is not redirected, and audio samples are neither recorded
nor transmitted. The app contains no network requests.

Local runtime files live in `~/Library/Application Support/LogoBeat/`:

- `original-mapping.plist`: the original mapping, saved before modification.
- `status.plist`: running state, callback count, recent audio level, and
  requested brightness. This contains numeric diagnostics, not audio samples.
- `app.log`: startup, stop, restoration, and error messages.

These files are outside this repository and are not uploaded.

Private APIs may change with macOS updates. A crash or forced termination can
leave the logo mapping changed until the next launch attempts restoration.
Do not delete the mapping backup when restoration has failed. Successful
restoration removes it automatically. Apple defaults are the lowest-risk
choice, and no safety certification or warranty is provided.

## Source

| File | Purpose |
| --- | --- |
| `main.m` | Menu-bar UI, audio capture, adaptive brightness, and restoration |
| `make-icon.m` | Generates the original waveform app icon using AppKit |
| `Info.plist` | App identity, icon metadata, and audio permission description |
| `build.sh` | Native build, signing, icon generation, and self-tests |

Run the installed app's self-tests without starting capture:

```bash
"$HOME/Applications/Logo Beat.app/Contents/MacOS/LogoBeat" --self-test
```

## References

- [Apple: About the illuminated Apple logo](https://support.apple.com/en-us/149248)
- [CoreBrightness logo-control analysis](https://github.com/GOROman/macbookpro-apple-logo-analysis)

No open-source license has been selected yet.
