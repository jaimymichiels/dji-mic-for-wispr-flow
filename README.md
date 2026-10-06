<h1 align="center">DJI Mic for Wispr Flow</h1>

<p align="center">
  Use the button on your DJI Mic Mini to dictate with <a href="https://wisprflow.ai">Wispr Flow</a> on macOS.<br>
  Click to talk, click to stop, click once more to send.
</p>

<p align="center">
  <img alt="macOS 27" src="https://img.shields.io/badge/macOS-27-1b1f24?logo=apple&amp;logoColor=white">
  <img alt="Hammerspoon" src="https://img.shields.io/badge/Hammerspoon-module-3e63dd">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-1f7a4d">
</p>

<p align="center">
  <img src="docs/images/three-clicks.svg" width="848" alt="Click the transmitter button and Wispr starts listening. Click again and it stops and pastes your text. Click a third time within 4 seconds and Return is pressed, sending the message. After sending, or after 4 seconds with no click, it goes back to idle.">
</p>

It uses a macOS built-in tool (`hidutil`) and a small [Hammerspoon](https://www.hammerspoon.org) module:
- No Karabiner, and no driver or system extension to approve.
- No sudo.
- Your keyboard's volume keys keep working.

Wait for your text to appear before the third click. A click before Wispr pastes sends Return too early.

After stopping, a compact dark pill appears in the screen center with “Press again to send” and a four-second countdown. Its ring shrinks as the send window runs out; the hint disappears when you send or the time expires.

## Requirements

- macOS (tested on 27.0)
- A DJI Mic Mini or Mic Mini 2 with the **receiver plugged into the Mac by USB-C**. The button doesn't reach the Mac over Bluetooth.
- [Wispr Flow](https://wisprflow.ai) (tested on 1.6.886)
- [Hammerspoon](https://www.hammerspoon.org) (tested on 1.1.1)
- [`just`](https://github.com/casey/just)

Other DJI Mic models are untested. They may use different IDs; see [Adapting it](#adapting-it).

## Install

```sh
brew install --cask hammerspoon
brew install just
git clone https://github.com/saqibnizami/dji-mic-for-wispr-flow.git
cd dji-mic-for-wispr-flow
just install
```

`just install` does three things:
1. Links the module into `~/.hammerspoon/`.
2. Adds two lines to your `init.lua`, leaving everything else in it alone.
3. Reloads Hammerspoon.

Open Hammerspoon once first if it has never run.

## Setup

1. **Allow sending Return.** Go to System Settings → Privacy & Security → Accessibility and turn on **Hammerspoon**. Then quit and reopen Hammerspoon. Starting and stopping dictation work without this; only the third-click send needs it.
2. **Start at login.** Hammerspoon → Preferences → tick **Launch Hammerspoon at login**.

Click the button once and Wispr should start listening.

## How it works

<p align="center">
  <img src="docs/images/how-it-works.svg" width="880" alt="The DJI receiver and your keyboard both send the same Volume Up key. In the macOS HID layer, which still knows which device sent a key, hidutil remaps Volume Up to F18 on the DJI receiver only. Below that layer apps only see the key: Hammerspoon catches F18 and opens a Wispr Flow link, while the keyboard's Volume Up still changes the system volume.">
</p>

The DJI receiver reports the button as a **volume-up key**, the same key your keyboard sends. You can't just remap volume-up in an app like Hammerspoon, because by the time a keypress reaches it, macOS no longer says which device it came from. You'd hijack your keyboard's volume key too.

One layer lower, macOS still knows. Its built-in `hidutil` can remap keys on **one device only**. So the receiver's volume-up becomes **F18**, a key nothing else sends, before any app sees it. Hammerspoon then treats F18 as the button and drives Wispr Flow through its `wispr-flow://` links.

The module also takes care of a few details:
- **Keeps the remap in place.** macOS drops the remap when the receiver is unplugged or the Mac restarts, so the module reapplies it when it loads, when the receiver is plugged in, and after the Mac wakes.
- **Tells you when something's wrong.** If the remap fails, or sending needs Accessibility, you get an on-screen alert instead of a click that does nothing.
- **Stays in step with Wispr.** Wispr's links can start or stop dictation but can't tell you which state it's in, so the module keeps track. If it ever gets out of step, one extra click fixes it.

[docs/research.md](docs/research.md) has the full story with sources:
- Why Hammerspoon alone can't tell devices apart.
- What the button actually sends.
- The Karabiner alternative.
- How to check whether a managed Mac allows each approach.

## Adapting it

Everything to change is at the top of [`hammerspoon/dji_wispr.lua`](hammerspoon/dji_wispr.lua).

- **A different device.** A foot pedal, a macro pad or another wireless receiver works the same way. Find its IDs with `hidutil list`, then update `DJI_VENDOR_ID`, `DJI_PRODUCT_ID` and `DJI_MATCHING`. If it doesn't send volume keys, also change the sources in `DJI_KEY_MAPPING`.
- **A different key.** If something already uses F18, switch the destination in `DJI_KEY_MAPPING` to F19 (`0x70000006E`) or F20 (`0x70000006F`), and change the key in `hs.hotkey.bind` to match.
- **A longer send window.** Raise `SEND_WINDOW_SECONDS`.
- **A different hint position.** Change `SEND_WIDGET_SCREEN_Y` (`0.5` centers it vertically on the usable screen).
- **A different dictation app.** Point `open_wispr_route` at that app's URL scheme or shortcut.

## Troubleshooting

**Hammerspoon says "Accessibility is not enabled" but System Settings shows it on.** Quit and reopen Hammerspoon. Its preferences window doesn't always notice the change. To check the live state:

```sh
/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c 'hs.accessibilityState()'
```

**The button changes the volume again.** The remap is gone. Unplug and replug the receiver, or reload Hammerspoon. `just mapping` shows whether it's applied.

**Nothing happens when I click.** Check that the receiver is on USB-C, not Bluetooth, and that the transmitter is linked to it. `just console` logs every click as `dji button press …`.

**Karabiner-Elements is installed.** If Karabiner is set to modify the receiver, it takes the device over and this remap stops applying. Either set the receiver to ignored in Karabiner's Devices settings, or use the Karabiner rules in [`karabiner/`](karabiner/) instead of this remap.

## Development

| Command | What it does |
|---|---|
| `just test-remap` | Checks that the button arrives as F18 without changing the volume. Needs no permissions; quit Hammerspoon first. |
| `just probe` | A deeper two-phase probe. Needs Input Monitoring for your terminal; quit Hammerspoon first. |
| `just mapping` | Shows the remap currently applied to the receiver. |
| `just console` | Shows the module's log lines from Hammerspoon. |
| `just mic-in-use` | Lists which microphones are being captured right now. |
| `just lint` | Lints the scripts, syntax-checks the Lua, and validates the Karabiner rules. |

Building the probes needs the Xcode Command Line Tools. `just lint` also needs `shellcheck` and `luajit`. The test and probe scripts undo their remap when they exit, including on Ctrl-C.

The diagrams in `docs/images/` are hand-written SVGs. Each one has its own light and dark palette.

## Credits

- [conchoecia/dji-mic-button](https://github.com/conchoecia/dji-mic-button) worked out what the button sends.
- [caezium/dji-mic-wispr-flow](https://github.com/caezium/dji-mic-wispr-flow) built the Karabiner version.
- [Johnixr/dji-mic-dictation](https://github.com/Johnixr/dji-mic-dictation) had the click-again-to-send idea.

## License

[MIT](LICENSE)
