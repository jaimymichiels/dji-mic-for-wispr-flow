-- Run in Hammerspoon; device events, tasks and menus are isolated from the live app.
local module_file = assert(..., "Pass the battery module path")
local attached, usb_callback, watcher, reader, item, retry
local shutdown_calls = 0
attached = {}
local fake_hs = setmetatable({ shutdownCallback = function() shutdown_calls = shutdown_calls + 1 end }, { __index = hs })
fake_hs.logger = { new = function() return { ef = function() end, w = function() end } end }
fake_hs.usb = {
  attachedDevices = function() return attached end,
  watcher = { new = function(callback)
    usb_callback = callback
    watcher = {
      start = function(self) self.active = true; return self end,
      stop = function(self) self.active = false; return self end,
    }
    return watcher
  end },
}
fake_hs.menubar = { new = function(visible)
  item = {
    visible = visible,
    setTitle = function(self, value) self.title = value; return self end,
    setIcon = function(self, value) self.icon = value; return self end,
    setTooltip = function(self, value) self.tooltip = value; return self end,
    setMenu = function(self, value) self.menu = value; return self end,
    removeFromMenuBar = function(self) self.visible = false; return self end,
    returnToMenuBar = function(self) self.visible = true; return self end,
    delete = function(self) self.deleted = true; self.visible = false end,
  }
  return item
end }
fake_hs.task = { new = function(path, finished, stream)
  assert(path:match("/bin/dji_battery$"), "Reader must resolve beside the installed module")
  reader = {
    stream = stream, finished = finished,
    start = function(self) self.active = true; return true end,
    terminate = function(self) self.active = false end,
  }
  return reader
end }
fake_hs.timer = { doAfter = function(_, callback)
  retry = { active = true, callback = callback, stop = function(self) self.active = false end }
  return retry
end }
local environment = setmetatable({ hs = fake_hs }, { __index = _G })
local module = assert(loadfile(module_file, "t", environment))()
local function emit(state, transmitters, message)
  local output = hs.json.encode({ state = state, transmitters = transmitters or {}, message = message }) .. "\n"
  assert(reader.stream(reader, output, ""))
end
local function event(kind)
  usb_callback({ eventType = kind, vendorID = 0x2CA3, productID = 0x4011 })
end
module.start()
assert(not item.visible and reader.active and watcher.active, "Absent receiver must hide the icon without stopping monitoring")
emit("connected", {{ unit = 1, gauge = 1, charging = false }})
assert(not item.visible, "Queued readings must not show an unplugged receiver")
attached = {{ vendorID = 0x2CA3, productID = 0x4011 }}
event("added")
assert(item.visible and module.latest_status.state == "waiting")
assert(not item.tooltip:find("hours left", 1, true), "Reconnection must clear the previous estimate")
local estimates = { "11.5", "9.6", "7.7", "5.8", "3.8", "1.9", "0.0" }
for gauge, hours in ipairs(estimates) do
  emit("connected", {{ unit = 1, gauge = gauge, charging = false }})
  assert(item.visible and item.tooltip:find("~" .. hours .. " hours left", 1, true))
  assert(item.icon:size().h == 13.5, "Small icon must be preserved")
  assert(item.tooltip:find(item.menu[2].title, 1, true), "Menu and tooltip must agree")
end
emit("connected", {{ unit = 1, gauge = 6, charging = true }})
assert(item.menu[2].title == "Transmitter 1: 1 of 6 charge steps · Low battery · ~1.9 hours left · Charging")
emit("connected", {{ unit = 2, charging = false }})
assert(item.menu[2].title == "Transmitter 2: Battery unknown")
emit("connected", {{ unit = 1, gauge = 1 }, { unit = 2, gauge = 4, charging = true }})
assert(item.menu[2].title == "Transmitter 1: Full · ~11.5 hours left")
assert(item.menu[3].title == "Transmitter 2: 3 of 6 charge steps · ~5.8 hours left · Charging")
emit("waiting", {}, "Waiting for battery data")
assert(item.visible and not item.tooltip:find("hours left", 1, true))
attached = {}
event("removed")
assert(not item.visible and reader.active and watcher.active, "Removal must preserve reconnection monitoring")
emit("error")
emit("connected", {{ unit = 1, gauge = 1 }})
assert(not item.visible, "Late output must not undo USB removal")
attached = {{ vendorID = 0x2CA3, productID = 0x4011 }}
event("added")
emit("connected", {})
assert(item.visible, "Receiver visibility must not depend on connected transmitters")
usb_callback({ eventType = "removed", vendorID = 1, productID = 2 })
assert(item.visible, "Unrelated USB events must not hide the icon")
local old_reader = reader
module.stop()
assert(item.deleted and not old_reader.active and not watcher.active)
event("added")
assert(module.menu_bar == nil, "A stopped module must not reappear")
module.start()
assert(item.visible, "Startup with an attached receiver must show the icon")
assert(not old_reader.stream(old_reader, "", ""), "Old callbacks must remain stopped after restart")
old_reader.finished(1, "", "old reader")
assert(retry == nil, "Old termination callbacks must not restart the reader")
reader.finished(1, "", "reader failed")
assert(item.visible and retry.active and item.tooltip:find("reconnecting", 1, true))
fake_hs.shutdownCallback()
assert(item.deleted and not watcher.active and not retry.active and shutdown_calls == 1)
print("Battery menu checks passed (estimates, unknown data, USB visibility, reconnects and lifecycle).")
