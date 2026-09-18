-- Turns the DJI Mic Mini transmitter button into a Wispr Flow hands-free toggle with
-- press-again-to-send. hidutil rewrites the button's volume keys to F18 on the receiver's
-- own HID service, so the F18 bound here is a real hardware event no other device sends.
local dji_wispr = {}

local DJI_VENDOR_ID = 0x2CA3
local DJI_PRODUCT_ID = 0x4011
local DJI_MATCHING = '{"VendorID":0x2CA3,"ProductID":0x4011}'
local DJI_KEY_MAPPING = '{"UserKeyMapping":['
  .. '{"HIDKeyboardModifierMappingSrc":0xC000000E9,"HIDKeyboardModifierMappingDst":0x70000006D},'
  .. '{"HIDKeyboardModifierMappingSrc":0xC000000EA,"HIDKeyboardModifierMappingDst":0x70000006D}]}'
-- The HID service registers after USB attach or wake; mapping earlier matches nothing.
local SERVICE_SETTLE_SECONDS = 1.5
-- A press this soon after stopping sends Return instead of starting a new dictation.
local SEND_WINDOW_SECONDS = 4

-- Wispr exposes separate start/stop deep links and no state query, so the module tracks
-- state itself. Each link is a no-op in the wrong state, so drift costs one extra press.
local DictationState = { idle = "idle", listening = "listening", send_armed = "send_armed" }

local log = hs.logger.new("dji_wispr", "info")
local dictation_state = DictationState.idle
local send_window_timer = nil
local send_window_alert = nil

local function open_wispr_route(route)
  hs.task.new("/usr/bin/open", function(exit_code, _, standard_error)
    if exit_code ~= 0 then
      log.ef("wispr route failed route=%s exit_code=%d stderr=%s", route, exit_code, standard_error)
    end
  end, { "-g", "wispr-flow://" .. route }):start()
end

local function apply_dji_key_mapping()
  hs.task.new("/usr/bin/hidutil", function(exit_code, standard_output, standard_error)
    -- hidutil exits 0 with empty output when --matching finds no service, so success
    -- means the echoed row for the DJI service is present.
    if exit_code ~= 0 or not standard_output:match("%x+%s+UserKeyMapping") then
      log.ef("dji key mapping not applied exit_code=%d stderr=%s", exit_code, standard_error)
      hs.alert.show("DJI button remap failed; see the Hammerspoon console")
      return
    end
    log.i("dji key mapping applied")
  end, { "property", "--matching", DJI_MATCHING, "--set", DJI_KEY_MAPPING }):start()
end

local function is_dji_receiver(device)
  return device.vendorID == DJI_VENDOR_ID and device.productID == DJI_PRODUCT_ID
end

local function is_dji_receiver_attached()
  for _, device in ipairs(hs.usb.attachedDevices() or {}) do
    if is_dji_receiver(device) then return true end
  end
  return false
end

local function close_send_window()
  if send_window_timer then
    send_window_timer:stop()
    send_window_timer = nil
  end
  if send_window_alert then
    hs.alert.closeSpecific(send_window_alert)
    send_window_alert = nil
  end
end

local function open_send_window()
  send_window_alert = hs.alert.show("↩  Press again to send", SEND_WINDOW_SECONDS)
  send_window_timer = hs.timer.doAfter(SEND_WINDOW_SECONDS, function()
    send_window_timer = nil
    send_window_alert = nil
    dictation_state = DictationState.idle
    log.i("send window expired without a press")
  end)
end

local function send_return()
  -- Posting a keystroke needs Accessibility; without it macOS drops the event silently.
  if not hs.accessibilityState() then
    log.e("return not sent: Hammerspoon lacks Accessibility permission")
    hs.alert.show("Hammerspoon needs Accessibility to send Return")
    return
  end
  hs.eventtap.keyStroke({}, "return")
  log.f("return sent frontmost_application=%s", hs.application.frontmostApplication():name())
end

local function handle_dji_button_press()
  local previous_state = dictation_state
  if dictation_state == DictationState.idle then
    open_wispr_route("start-hands-free")
    dictation_state = DictationState.listening
  elseif dictation_state == DictationState.listening then
    open_wispr_route("stop-hands-free")
    dictation_state = DictationState.send_armed
    open_send_window()
  else
    close_send_window()
    send_return()
    dictation_state = DictationState.idle
  end
  log.f("dji button press previous_state=%s state=%s", previous_state, dictation_state)
end

local function handle_usb_event(device)
  if not is_dji_receiver(device) then return end
  if device.eventType == "added" then
    hs.timer.doAfter(SERVICE_SETTLE_SECONDS, apply_dji_key_mapping)
  else
    close_send_window()
    dictation_state = DictationState.idle
  end
end

local function handle_power_event(event)
  if event == hs.caffeinate.watcher.systemDidWake and is_dji_receiver_attached() then
    hs.timer.doAfter(SERVICE_SETTLE_SECONDS, apply_dji_key_mapping)
  end
end

function dji_wispr.start()
  dji_wispr.hotkey = hs.hotkey.bind({}, "f18", handle_dji_button_press)
  dji_wispr.usb_watcher = hs.usb.watcher.new(handle_usb_event):start()
  dji_wispr.power_watcher = hs.caffeinate.watcher.new(handle_power_event):start()
  if is_dji_receiver_attached() then apply_dji_key_mapping() end
  return dji_wispr
end

return dji_wispr
