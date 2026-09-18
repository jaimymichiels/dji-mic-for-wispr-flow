# Research notes

Collected on 2026-09-18 while building this. Environment: macOS 27.0 on a MacBook Pro, DJI Mic Mini receiver over USB-C, Wispr Flow 1.6.886, Hammerspoon 1.1.1, Karabiner-Elements 16.3.0.

## 1. What the DJI button sends

- **Only the transmitter's link button sends anything.** The receiver's own button sends no HID events at all ([conchoecia/dji-mic-button](https://github.com/conchoecia/dji-mic-button)).
- **It sends a volume key.** A press makes the receiver send consumer usage `0xE9` (`volume_increment`) over its USB HID interface. One project also maps `0xEA` (`volume_decrement`) ([caezium/dji-mic-wispr-flow](https://github.com/caezium/dji-mic-wispr-flow)), so this repo remaps both.
- **Receiver IDs:** it reports as "Wireless Mic Rx", VID `0x2CA3` (11427), PID `0x4011` (16401). The Mic Mini and Mic Mini 2 report the same IDs.
- **The press is momentary**, down and up in one motion. There's no hold, so push-to-talk is impossible and a hands-free toggle is the only option.
- **USB-C only.** In Bluetooth mode the receiver is a bare audio device (HFP) and sends no button events.
- **It has its own HID event service.** On macOS the receiver shows up as its own service (`AppleUserHIDEventService`, usage page `0x0C`, usage `0x01`). To see it:
  ```sh
  hidutil list --matching '{"VendorID":0x2CA3,"ProductID":0x4011}'
  ```

## 2. Why Hammerspoon alone can't do it

### Hammerspoon has no way to identify the source device

I checked Hammerspoon at commit [`23e387e`](https://github.com/Hammerspoon/hammerspoon/tree/23e387e) (2026-07-08):

- **Event properties:** `hs.eventtap.event.properties` exposes only Apple's standard `CGEventField` constants ([`libeventtap_event.m#L1481-L1532`](https://github.com/Hammerspoon/hammerspoon/blob/23e387e/extensions/eventtap/libeventtap_event.m#L1481-L1532)). None of them identify the source device for key events. `keyboardEventKeyboardType` is the keyboard *layout* type (ANSI/ISO/JIS), and it isn't set on the media-key events the DJI sends.
- **Raw event data:** `getRawEventData` ([L479](https://github.com/Hammerspoon/hammerspoon/blob/23e387e/extensions/eventtap/libeventtap_event.m#L479)) returns keycode, flags, type and some `NSEvent` fields. Nothing about the device.
- **Private sender-ID APIs:** Hammerspoon never calls `CGEventCopyIOHIDEvent` or `IOHIDEventGetSenderID`. The private IOHIDEvent headers in `extensions/eventtap/` are only used to synthesize trackpad gestures (`TouchEvents.c`).
- **`hs.hid`:** covers only Caps Lock and keyboard LEDs.
- **Per-device input:** only `hs.razer` and `hs.streamdeck` read input from a specific device through IOHIDManager. Both are hardcoded to their own vendor/product IDs ([`HSRazerManager.m#L57-L75`](https://github.com/Hammerspoon/hammerspoon/blob/23e387e/extensions/razer/HSRazerManager.m#L57-L75)). Both open the device non-exclusively (`kIOHIDOptionsTypeNone`), so they couldn't block an event anyway.

The maintainers have given the same answer for years:

- [#1083](https://github.com/Hammerspoon/hammerspoon/issues/1083), asmagill (2016): *"by the time the Quartz Event Services hands things off to an application, there doesn't seem to be a way to get a vendor ID for a key event... for a tablet, yes, but not for a key."*
- Same thread, cmsj (January 2023): *"I don't think any of Apple's APIs for this have changed, unfortunately. I would suggest doing it with Karabiner, since it has access to the lower level device info."*
- [#1205](https://github.com/Hammerspoon/hammerspoon/issues/1205), cmsj (2017): *"the API that hs.hotkey uses has no way to distinguish between which input device a hotkey came from."*
- [#1587](https://github.com/Hammerspoon/hammerspoon/issues/1587), cmsj (2017): *"the only reliable way to do this would be with IOKit."*
- [#2921](https://github.com/Hammerspoon/hammerspoon/issues/2921) (2021): the person asking ended up remapping per device with `hidutil --matching`. That's where the approach in this repo comes from.

On macOS itself, the public `CGEvent` API carries a vendor ID only for drawing-tablet proximity events (`kCGTabletProximityEventVendorID`).

### The private sender-ID route

The chain is `CGEventCopyIOHIDEvent(event)` → `IOHIDEventGetSenderID()` → `IORegistryEntryIDMatching` → read `VendorID` / `ProductID` from the registry. It isn't reliable:

- OpenLogi [#920](https://github.com/AprilNEA/OpenLogi/issues/920) (macOS 26.5): some events carry no underlying IOHIDEvent at all.
- OpenLogi [PR #1442](https://github.com/AprilNEA/OpenLogi/pull/1442): *"On macOS 27, `IOHIDEventGetSenderID()` returns 0 for the CGEvents backing a Logitech mouse button transition."*

`probes/sender_probe.swift` tests this route for the DJI's media key (`just probe`, Phase 1). It needs Input Monitoring for the terminal and hasn't been run. It's no longer needed, because the `hidutil` route works.

### Faking Wispr's Fn hotkey

- **Why it probably fails:** the main source is [Nick Liu's post](https://www.nick-liu.com/posts/tahoe-hotkey-dead-end/). On macOS 26.5, WindowServer drops keystrokes that an unsigned daemon synthesizes before they reach Carbon hotkey listeners. It also reports that `hs.eventtap.keyStroke` can't trigger `hs.hotkey`. That's a different setup from Hammerspoon (signed, with Accessibility) posting to Wispr, and nobody has tested that combination.
- **What Wispr says:** its [Setup Guide](https://docs.wisprflow.ai/articles/3152211871-setup-guide) says *"On Macs with the Apple fn key, fn is the default; without it, Flow uses Ctrl+Opt."* An earlier Wispr help article, now returning 404, said *"The Apple Fn key only fires from the built-in MacBook keyboard."* That suggests Wispr reads Fn from the hardware itself.
- **Conclusion:** treat "Hammerspoon can't trigger Wispr's Fn hotkey" as likely, not proven. The deep links avoid the question entirely.

## 3. Wispr Flow deep links

- **Where they're documented:** nowhere official. I found them on a [third-party skill page](https://skills.lc/Vesely/skills/vesely-skills-wispr-skill-md) and confirmed them in Wispr's own bundle:
  ```sh
  grep -aoE 'wispr-flow://[a-z-]+' "/Applications/Wispr Flow.app/Contents/Resources/app.asar" | sort -u
  ```
  In 1.6.886 that finds `start-hands-free`, `stop-hands-free` and `switch-mic` (plus `auth`, `billing`, `linkedin`, `open`).
- **How they behave:**
  - `start-hands-free` is ignored unless Wispr is idle.
  - `stop-hands-free` only acts in hands-free mode.
  - There's no toggle link and no way to ask Wispr's state.
- **Open them with `open -g`** so the text field keeps focus.
- **Why Hammerspoon sits in the middle:** Wispr's own shortcut rules require a modifier key or a mouse button ([supported hotkeys](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts)), so a bare F18 can't be bound in Wispr directly.
- **The mic can't show Wispr's state.** The receiver's audio input reports `kAudioDevicePropertyDeviceIsRunningSomewhere = true` even while Wispr is idle (`just mic-in-use`), so it can't tell you when Wispr is listening.

## 4. The native route: `hidutil` per-device `UserKeyMapping`

- **Value format:** `(usage page << 32) | usage`. Volume Increment is `0xC000000E9` and F18 is `0x70000006D`. Apple's [TN2450](https://developer.apple.com/library/archive/technotes/tn2450/_index.html) documents only the Keyboard page (`0x07`). [nanoant](https://www.nanoant.com/mac/macos-function-key-remapping-with-hidutil) shows a Consumer-page VolumeUp working as a source on a keyboard service.
- **Scope and permissions:** `--matching '{"VendorID":0x2CA3,"ProductID":0x4011}'` limits the mapping to the receiver's service. It needs no sudo. Reading the property back confirmed it, and the built-in keyboard's services kept `UserKeyMapping = (null)`.
- **Verified on hardware** (`just test-remap`): three transmitter presses produced three Carbon F18 hotkey events, and output volume didn't change. That confirms a Consumer-page source works on a device that only sends media keys.
- **Silent success:** `hidutil property --set` exits 0 with empty output when `--matching` finds no service.
- **Not persistent:** mappings are lost on reboot or when the device's service goes away (TN2450), so the module reapplies them when the receiver is plugged in and when the Mac wakes.
- **No permission needed for the hotkey:** `hs.hotkey` uses Carbon's `RegisterEventHotKey` ([`libhotkey.m#L258`](https://github.com/Hammerspoon/hammerspoon/blob/23e387e/extensions/hotkey/libhotkey.m#L258)), which needs no Accessibility, and the remapped F18 is a real hardware event.

## 5. The Karabiner-Elements route

- **The rule:** `consumer_key_code` `volume_increment` / `volume_decrement`, limited to the receiver with `device_if` on its VID/PID, mapped to Fn+Space (Wispr's default hands-free shortcut) or to F18. Both rules are in `karabiner/dji_mic_wispr.json`.
- **Enable the device:** Karabiner ignores devices that only send media keys unless you enable them in its Devices tab (`is_consumer: true` in `karabiner.json`).
- **Driver extension:** it must be approved first, `org.pqrs.Karabiner-DriverKit-VirtualHIDDevice` from team `G43BCU2T37`. Approve it at System Settings → General → Login Items & Extensions → Driver Extensions. If it isn't listed, this submits the activation request ([upstream README](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/blob/main/README.md)):
  ```sh
  /Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager activate
  ```
- **How to tell it isn't approved:**
  - `systemextensionsctl list` has no entry for it.
  - `/var/log/karabiner/virtual_hid_device_service.log` repeats `virtual_hid_keyboard is not ready` every 5 s.
  - `~/.local/share/karabiner/log/console_user_server.log` shows the settings window's setup guidance moving to `driver_extension`.
- **Permissions:** Karabiner 16.x needs Accessibility, which replaced Input Monitoring from 16.0.0 ([required settings](https://karabiner-elements.pqrs.org/docs/manual/misc/required-macos-settings/)).
- **Conflict with the native route:** once the driver is approved and the receiver is enabled, Karabiner takes over the device, so the `hidutil` mapping no longer applies. Use one route or the other.

## 6. Checking an MDM-managed Mac

- **Which policy applies:** system extensions are governed by the `com.apple.system-extension-policy` payload. To read what's actually applied:
  ```sh
  plutil -p "/Library/Managed Preferences/com.apple.system-extension-policy.plist"
  plutil -p "/Library/Managed Preferences/$USER/complete.plist"   # merged view, with source payloads
  ```
- **`AllowUserOverrides`:** defaults to `true`. With `false` it *"restricts users from approving additional system extensions that configuration profiles don't explicitly allow,"* and it's `false` if any profile sets it to `false` ([Apple's schema](https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.system-extension-policy.yaml)). Extensions that aren't allowlisted won't load on their own, but with `true` a user can approve them.
- **Managed login items** (`com.apple.servicemanagement`): these only force the listed items on. They don't block anything else.
- **Security agents are separate.** Endpoint security and compliance agents enforce their own policies outside configuration profiles.
- **The native route avoids the question.** Hammerspoon is an ordinary Developer ID app (team `VQCYSNZB89`) with no system extension.

## 7. The macOS 27 Accessibility quirk

- **What happened:** after Hammerspoon was enabled in System Settings (on macOS 27 the list is titled "Device Control and Data Access"), macOS's permissions service logged `AUTHREQ_RESULT … authValue=2` (allowed) for Hammerspoon's Accessibility checks. Hammerspoon's Preferences window still showed "WARNING! Accessibility is not enabled!".
- **Why:** that window only refreshes when macOS broadcasts the `com.apple.accessibility.api` notification ([`MJPreferencesWindowController.m#L99`](https://github.com/Hammerspoon/hammerspoon/blob/23e387e/Hammerspoon/MJPreferencesWindowController.m#L99), [L137](https://github.com/Hammerspoon/hammerspoon/blob/23e387e/Hammerspoon/MJPreferencesWindowController.m#L137)).
- **Fix:** quit and reopen Hammerspoon. After that, `hs.accessibilityState()` returned `true`.
- **Diagnosis:** check `hs -c 'hs.accessibilityState()'` for the live state, and grep the `tccd` log for `AUTHREQ_RESULT` to see what macOS decided. Use `/usr/bin/log`, because zsh's builtin `log` shadows it.

## 8. Ideas not built yet

- **Switch Wispr's mic on plug-in:** open `wispr-flow://switch-mic?mic_name=Wireless` when the receiver is plugged in, and `switch-mic?mic_name=MacBook` when it's unplugged. The name matches from the start and ignores case.
- **Two transmitters, two actions:** if the kit's two transmitters send different usages (`0xE9` versus `0xEA`), map them to F18 and F19 and give each its own action. `just probe` would show which is which.
- **Menu bar status:** an `hs.menubar` item showing whether the mapping is active and whether you're dictating.
- **Skip Hammerspoon (experimental):** map straight to Apple's Fn (`0xFF00000003`), so two presses become a Fn double-tap, which starts Wispr's hands-free mode. Wispr may ignore Fn that doesn't come from an Apple keyboard.
