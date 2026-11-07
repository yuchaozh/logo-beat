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
- **Launch at login** is opt-in and uses macOS's native login-item service.
  Nothing is registered automatically. Enable the option to launch Logo Beat
  when you log in; disable it to remove that registration without stopping
  the current session. If it says **approval needed**, allow it under
  **System Settings > General > Login Items & Extensions**, or click again to
  cancel the pending request. Registration failures are shown explicitly and
  the checkmark reflects macOS's actual state, not a saved preference.
- After sleep, screen sleep, or locking the Mac, choose **Start** to resume.
  Low Power Mode prevents starting.

The app starts listening when opened. By default, silence lasting more than
one second restores the normal brightness mapping while listening continues.

## Playground and light effects

| Feature | How to use it |
| --- | --- |
| DJ pulses | Choose **Animation > DJ pulses** for softened pulses on detected audio onsets, with a quieter glow between them. |
| Automatic | Choose **Animation > Automatic** for gentle breathing during silence and dynamic music response during playback. Switching back to breathing waits for more than one second of silence to avoid flickering between modes. |
| Breathing Mac | Choose **Animation > Breathing Mac** to follow music and breathe gently during silence. Alternatively, enable **Breathe when music pauses** for any mode. |
| Mood presets | Choose **Chill** for slower transitions and a 180-nit ceiling, **Party** for DJ pulses up to 300 nits, or **Heartbeat** for paired swells up to 240 nits. |
| Dancing icon | The menu-bar waveform bounces with playback volume. Toggle **Dancing menu-bar icon** to return to a static icon. |
| Rhythm game | Choose **Play rhythm game...**, play music, and press Space or click **Tap** when the ring swells. Earn timing points and combos; held-key repeats do not score. |
| Morse messages | Choose **Send Morse message...** and enter 1-24 English letters, digits, or spaces. **Cancel Morse message** returns to the chosen effect. |
| MacBook preview | **Open Playground...** shows a miniature MacBook light show, audio bars, requested brightness, and game feedback. |

Mood presets also select a matching animation: Chill and Heartbeat use Volume;
Party uses DJ pulses. **Automatic** stays selected when changing moods.
Automatic uses DJ-style dynamics (or Heartbeat's paired swells) during music,
and breathing during silence. You can change the animation afterward. Animation, mood,
idle-breathing, and dancing-icon preferences are saved locally.

The rhythm game uses audio-onset detection, not exact musical tempo analysis.
Some tracks or notification sounds can trigger unexpected beats. Only the
Playground window handles Space: there is no global keyboard monitoring.
Closing it ends the game without stopping logo control. A new game resets the
score; missed beats or unmatched taps break the combo.

Morse messages temporarily override the music effect and return to it when
finished. Dots use a 0.65-second unit, dashes three units, with standard
symbol/letter/word gaps. Transitions are softened, so this is decorative Morse
and not precision signaling. Apple light limits can reduce its contrast.
Messages are kept only as an in-memory sequence and are never logged or
saved, but the visible pattern is not private or encrypted.

All effects use the existing brightness mapping and restoration path.
Breathing and Morse continue controlling the logo during silence when
explicitly selected; **Stop and restore** or **Quit** cancels them and releases
the light. Detected pulses are rate-limited and brightness transitions are
smoothed instead of hard-strobing. This does not certify the effects as safe
for photosensitive viewers; stop the app if the animation causes discomfort.

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
- `status.plist`: running state, callback count, recent audio level, requested
  brightness, selected effect/mood, and game/Morse activity. This contains
  diagnostics, not audio samples or message text.
- `app.log`: startup, stop, restoration, and error messages.

Preferences are saved in the local `local.logobeat` defaults domain.
Login launch registration is managed by macOS rather than this preferences
file. Ad-hoc signed rebuilds may require macOS to approve the updated app again.
These files and preferences are outside this repository and are not uploaded.

Private APIs may change with macOS updates. A crash or forced termination can
leave the logo mapping changed until the next launch attempts restoration.
Do not delete the mapping backup when restoration has failed. Successful
restoration removes it automatically. Apple defaults are the lowest-risk
choice, and no safety certification or warranty is provided.

## Source

| File | Purpose |
| --- | --- |
| `main.m` | Menu-bar UI, audio capture, adaptive brightness, and restoration |
| `Playful.h`, `Playful.m` | Animation engine, Morse timing, rhythm scoring, dancing icon, and MacBook preview |
| `make-icon.m` | Generates the original waveform app icon using AppKit |
| `Info.plist` | App identity, icon metadata, and audio permission description |
| `build.sh` | Native build, signing, icon generation, and self-tests |

Run the installed app's self-tests without starting capture:

```bash
"$HOME/Applications/Logo Beat.app/Contents/MacOS/LogoBeat" --self-test
```

The tests cover mode behavior, brightness bounds, transition pacing, Morse
encoding and cancellation, rhythm scoring, repeat-key handling, native menu
validation, and controller restoration using a fake brightness client. They
also verify automatic silence/music transitions and login-item state/error
handling with a fake service. They do not register a real login item, open a
window, capture playback, or modify the real logo.
`build.sh` also renders an off-screen preview to
`build/playground-preview.png`. A live check on supported hardware is still
needed to assess timing, room-light limitations, and the complete window UX.

## References

- [Apple: About the illuminated Apple logo](https://support.apple.com/en-us/149248)
- [CoreBrightness logo-control analysis](https://github.com/GOROman/macbookpro-apple-logo-analysis)

No open-source license has been selected yet.
