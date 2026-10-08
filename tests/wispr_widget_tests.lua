-- Run in Hammerspoon; routes, keystrokes, timers and device events are isolated.
local module_file, preview_file = ...
assert(module_file, "Pass the Wispr module path")
local press, usb_event, canvas, countdown, expiry
local routes, returns, now = {}, 0, 0
local mouse_callbacks = {}
local fake_hs = setmetatable({}, { __index = hs })
fake_hs.logger = { new = function()
  return { i = function() end, f = function() end, e = function() end, ef = function() end }
end }
fake_hs.task = { new = function(path, _, arguments)
  assert(path == "/usr/bin/open", "No hardware remapping should run in this test")
  return { start = function() routes[#routes + 1] = arguments[2] end }
end }
fake_hs.accessibilityState = function() return true end
fake_hs.eventtap = { keyStroke = function(_, key)
  assert(key == "return")
  returns = returns + 1
end }
fake_hs.application = { frontmostApplication = function()
  return { name = function() return "Widget test" end }
end }
local function timer(callback)
  return { active = true, callback = callback, stop = function(self) self.active = false end }
end
fake_hs.timer = {
  absoluteTime = function() return now end,
  doEvery = function(_, callback) countdown = timer(callback); return countdown end,
  doAfter = function(_, callback) expiry = timer(callback); return expiry end,
}
fake_hs.canvas = { new = function(frame)
  -- Use native canvas APIs while keeping the test windows invisible.
  local native_canvas = hs.canvas.new(frame):alpha(0)
  canvas = setmetatable({}, { __index = function(_, key)
    if key == "mouseCallback" then
      return function(self, callback)
        mouse_callbacks[self] = callback
        native_canvas:mouseCallback(function(_, ...) callback(self, ...) end)
        return self
      end
    end
    local value = native_canvas[key]
    if type(value) ~= "function" then return value end
    return function(self, ...)
      local result = value(native_canvas, ...)
      return result == native_canvas and self or result
    end
  end })
  return canvas
end }
fake_hs.hotkey = { bind = function(_, _, callback) press = callback; return {} end }
local function watcher(callback)
  return { start = function(self) return self end }
end
fake_hs.usb = {
  attachedDevices = function() return {} end,
  watcher = { new = function(callback) usb_event = callback; return watcher(callback) end },
}
fake_hs.caffeinate = { watcher = { new = watcher } }
local environment = setmetatable({ hs = fake_hs }, { __index = _G })
assert(loadfile(module_file, "t", environment))().start()

local function arm_send()
  press()
  assert(routes[#routes] == "wispr-flow://start-hands-free", "An idle press must start dictation")
  press()
  assert(routes[#routes] == "wispr-flow://stop-hands-free")
  assert(canvas:isShowing() and countdown.active and expiry.active)
end

arm_send()
if preview_file then assert(canvas:imageFromCanvas():saveToFile(preview_file)) end
assert(canvas.cancel and canvas.cancel.trackMouseUp, "The send hint needs a clickable close button")
assert(canvas.cancel.trackMouseEnterExit, "The close button must track pointer entry and exit")
assert(not canvas:clickActivating(), "Cancel must keep the dictation app focused")
local callback = assert(mouse_callbacks[canvas])
local route_count = #routes
local normal_fill = canvas.cancel_background.fillColor.red
local normal_border = canvas.cancel_background.strokeColor.alpha
local normal_cross = canvas.cancel_cross_1.strokeColor.red
callback(canvas, "mouseEnter", "cancel")
assert(canvas.cancel_background.fillColor.red > normal_fill, "Hover must highlight the close button")
assert(canvas.cancel_background.strokeColor.alpha > normal_border, "Hover must brighten the border")
assert(canvas.cancel_cross_1.strokeColor.red > normal_cross, "Hover must brighten the cross")
assert(canvas.cancel_cross_2.strokeColor.red == canvas.cancel_cross_1.strokeColor.red)
if preview_file then
  local hover_preview_file = preview_file:gsub("%.png$", "-hover.png")
  assert(canvas:imageFromCanvas():saveToFile(hover_preview_file))
end
callback(canvas, "mouseExit", "cancel")
assert(canvas.cancel_background.fillColor.red == normal_fill and canvas.cancel_background.strokeColor.alpha == normal_border,
  "Leaving the button must restore its background and border")
assert(canvas.cancel_cross_1.strokeColor.red == normal_cross and canvas.cancel_cross_2.strokeColor.red == normal_cross,
  "Leaving the button must restore the cross")
assert(canvas:isShowing() and countdown.active and expiry.active and returns == 0 and #routes == route_count,
  "Hover must not cancel, send or stop the countdown")
callback(canvas, "mouseDown", "cancel")
callback(canvas, "mouseUp", "countdown")
callback(canvas, "mouseUp", "_canvas_")
assert(canvas:isShowing() and countdown.active and expiry.active, "Only releasing on close should cancel")
now = 2e9
countdown.callback()
assert(canvas.countdown.text == "6s" and canvas.progress.endAngle == 270, "Countdown must still update")
local old_canvas = canvas
callback(canvas, "mouseUp", "cancel")
assert(not countdown.active and not expiry.active, "Cancel must stop both timers")
assert(returns == 0 and #routes == route_count, "Cancel must not send Return or change dictation")

-- The next button press must start a new dictation, including before the old deadline.
arm_send()
callback(old_canvas, "mouseUp", "cancel")
callback(old_canvas, "mouseEnter", "cancel")
assert(canvas:isShowing() and countdown.active and expiry.active, "An old close callback must not cancel a new hint")
press()
assert(returns == 1 and not countdown.active and not expiry.active, "A normal third press must still send")

arm_send()
expiry.callback()
assert(not countdown.active and not expiry.active and returns == 1, "Expiry must dismiss without sending")
arm_send()
usb_event({ eventType = "removed", vendorID = 0x2CA3, productID = 0x4011 })
assert(not countdown.active and not expiry.active and returns == 1, "Disconnect must dismiss without sending")
arm_send()
mouse_callbacks[canvas](canvas, "mouseUp", "cancel")
print("Wispr widget checks passed (hover, cancel, next press, countdown, send, expiry and disconnect).")
