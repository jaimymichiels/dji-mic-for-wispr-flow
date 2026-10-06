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
local SEND_WINDOW_SECONDS = 8
-- Keep the send hint centered on the active display.
local SEND_WIDGET_SCREEN_Y = 0.5

-- Wispr exposes separate start/stop deep links and no state query, so the module tracks
-- state itself. Each link is a no-op in the wrong state, so drift costs one extra press.
local DictationState = { idle = "idle", listening = "listening", send_armed = "send_armed" }

local log = hs.logger.new("dji_wispr", "info")
local dictation_state = DictationState.idle
local send_window_timer = nil
local send_countdown_timer = nil
local send_window_canvas = nil

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
  if send_countdown_timer then
    send_countdown_timer:stop()
    send_countdown_timer = nil
  end
  if send_window_canvas then
    send_window_canvas:delete()
    send_window_canvas = nil
  end
end

local function open_send_window()
  close_send_window()
  local screen_frame = hs.screen.mainScreen():frame()
  local width, height, padding = 270, 48, 12
  local started_at = hs.timer.absoluteTime()
  send_window_canvas = hs.canvas.new({
    x = screen_frame.x + (screen_frame.w - width) / 2 - padding,
    y = screen_frame.y + screen_frame.h * SEND_WIDGET_SCREEN_Y - height / 2 - padding,
    w = width + padding * 2,
    h = height + padding * 2,
  }):level("overlay"):behavior({ "canJoinAllSpaces", "fullScreenAuxiliary" })
    :canvasMouseEvents(false, false, false, false)
  send_window_canvas:appendElements(
    {
      type = "rectangle", action = "strokeAndFill",
      frame = { x = padding, y = padding, w = width, h = height },
      roundedRectRadii = { xRadius = height / 2, yRadius = height / 2 },
      fillColor = { white = 0.08, alpha = 0.97 },
      strokeColor = { white = 1, alpha = 0.14 }, strokeWidth = 1,
      withShadow = true,
      shadow = { blurRadius = 10, color = { white = 0, alpha = 0.3 }, offset = { w = 0, h = -3 } },
    },
    {
      type = "rectangle", action = "fill",
      frame = { x = padding + 12, y = padding + 10, w = 28, h = 28 },
      roundedRectRadii = { xRadius = 9, yRadius = 9 },
      fillColor = { white = 1, alpha = 0.1 },
    },
    {
      -- Draw the Return symbol with equal insets instead of relying on font baselines.
      type = "segments", action = "stroke",
      coordinates = {
        { x = padding + 32, y = padding + 18 },
        { x = padding + 32, y = padding + 24 },
        { x = padding + 29, y = padding + 27,
          c1x = padding + 32, c1y = padding + 25.65, c2x = padding + 30.65, c2y = padding + 27 },
        { x = padding + 20, y = padding + 27 },
      },
      strokeColor = { white = 0.95 }, strokeWidth = 1.5, strokeCapStyle = "round",
    },
    {
      type = "segments", action = "stroke",
      coordinates = {
        { x = padding + 23, y = padding + 24 },
        { x = padding + 20, y = padding + 27 },
        { x = padding + 23, y = padding + 30 },
      },
      strokeColor = { white = 0.95 }, strokeWidth = 1.5,
      strokeCapStyle = "round", strokeJoinStyle = "round",
    },
    {
      type = "text", text = "Press again to send", textSize = 13,
      textColor = { white = 0.95 },
      frame = { x = padding + 50, y = padding + 15, w = 158, h = 20 },
    },
    {
      type = "circle", action = "stroke", radius = 15,
      center = { x = padding + 238, y = padding + height / 2 },
      strokeColor = { white = 1, alpha = 0.12 }, strokeWidth = 2,
    },
    {
      id = "progress", type = "arc", action = "stroke", radius = 15,
      center = { x = padding + 238, y = padding + height / 2 },
      startAngle = 0, endAngle = 360, arcRadii = false,
      strokeColor = { white = 0.85 }, strokeWidth = 2, strokeCapStyle = "round",
    },
    {
      id = "countdown", type = "text", text = string.format("%ds", math.ceil(SEND_WINDOW_SECONDS)),
      textSize = 11, textAlignment = "center", textColor = { white = 0.9 },
      frame = { x = padding + 220, y = padding + 16, w = 36, h = 18 },
    }
  ):show()
  -- Use elapsed time so delayed callbacks don't stretch the visible countdown.
  send_countdown_timer = hs.timer.doEvery(0.05, function()
    local elapsed = (hs.timer.absoluteTime() - started_at) / 1e9
    local remaining = math.max(0, SEND_WINDOW_SECONDS - elapsed)
    send_window_canvas.countdown.text = string.format("%ds", math.ceil(remaining))
    send_window_canvas.progress.endAngle = 360 * remaining / SEND_WINDOW_SECONDS
  end)
  send_window_timer = hs.timer.doAfter(SEND_WINDOW_SECONDS, function()
    close_send_window()
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
