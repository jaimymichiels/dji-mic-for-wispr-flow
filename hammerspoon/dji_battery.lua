-- Transmitter battery status. A native helper reads DJI's status interface;
-- Hammerspoon handles display and lifecycle without touching dictation state.
local dji_battery = {}
local log = hs.logger.new("dji_battery", "info")
local module_path = hs.fs.pathToAbsolute(debug.getinfo(1, "S").source:sub(2))
local module_directory = module_path:match("^(.*)/[^/]+$")
local helper_path = module_directory .. "/bin/dji_battery"
local icon_scale = 0.75
-- DJI's transmitter runtime rating, measured with noise cancellation off:
-- https://www.dji.com/mic-mini/specs
local transmitter_runtime_hours = 11.5
local logo_image = assert(hs.image.imageFromPath(module_directory .. "/assets/dji-logo.svg"))
local inverted_logo
do
  local canvas = hs.canvas.new({ x = 0, y = 0, w = 32, h = 18 })
  -- Hammerspoon images use the canvas's default compositing rule.
  canvas:canvasDefaultFor("compositeRule", "destinationOut")
  canvas:appendElements(
    { type = "rectangle", action = "fill", frame = { x = 0, y = 0, w = 32, h = 18 },
      roundedRectRadii = { xRadius = 3, yRadius = 3 }, fillColor = { white = 0 }, compositeRule = "sourceOver" },
    { type = "image", image = logo_image, imageAlpha = 1, imageScaling = "scaleProportionally",
      frame = { x = 2, y = 1, w = 28, h = 16 } }
  )
  inverted_logo = canvas:imageFromCanvas()
  canvas:delete()
end
local reader, retry_timer, usb_watcher = nil, nil, nil
local receiver_present = false
local running, generation, pending = false, 0, ""
local display_key = nil
local previous_shutdown, shutdown_callback
local start_reader

local function is_dji_receiver(device)
  return device.vendorID == 0x2CA3 and device.productID == 0x4011
end

local function receiver_is_attached()
  for _, device in ipairs(hs.usb.attachedDevices() or {}) do
    if is_dji_receiver(device) then return true end
  end
  return false
end

local function battery_description(tx)
  local text
  if not tx.gauge then text = "Battery unknown"
  elseif tx.gauge == 1 then text = "Full"
  elseif tx.gauge == 7 then text = "Empty"
  else text = string.format("%d of 6 charge steps%s", 7 - tx.gauge, tx.gauge >= 6 and " · Low battery" or "") end
  if tx.gauge then
    -- Use the same approximate charge fraction as the icon's six fill steps.
    local hours_left = transmitter_runtime_hours * (7 - tx.gauge) / 6
    text = text .. string.format(" · ~%.1f hours left", hours_left)
  end
  if tx.charging then text = text .. " · Charging" end
  return string.format("Transmitter %d: %s", tx.unit, text)
end

local function battery_icon(transmitters)
  local count = math.max(1, #transmitters)
  local width = 0
  for index = 1, count do
    local tx = transmitters[index]
    width = width + (tx and tx.gauge and 32 or 44) + (index > 1 and 6 or 0)
  end
  local canvas = hs.canvas.new({ x = 0, y = 0, w = width, h = 18 })
  local x = 0
  for index = 1, count do
    local tx = transmitters[index]
    local logo_frame = { x = x + 2, y = 1, w = 28, h = 16 }
    if tx and tx.gauge then
      local filled_width = 32 * (7 - tx.gauge) / 6
      if filled_width > 0 then
        canvas:appendElements(
          { type = "rectangle", action = "clip", frame = { x = x, y = 0, w = filled_width, h = 18 } },
          { type = "image", image = inverted_logo, imageAlpha = 1,
            frame = { x = x, y = 0, w = 32, h = 18 } },
          { type = "resetClip" }
        )
      end
      if filled_width < 32 then
        -- Show the plain logo in the empty portion. Both halves use
        -- transparency, so the template icon adapts to light and dark bars.
        canvas:appendElements(
          { type = "rectangle", action = "clip",
            frame = { x = x + filled_width, y = 0, w = 32 - filled_width, h = 18 } },
          { type = "image", image = logo_image, imageAlpha = 1, imageScaling = "scaleProportionally", frame = logo_frame },
          { type = "resetClip" }
        )
      end
      x = x + 38
    else
      canvas:appendElements(
        { type = "image", image = logo_image, imageAlpha = 0.35, imageScaling = "scaleProportionally", frame = logo_frame },
        { type = "text", text = "?", textSize = 10, textAlignment = "center",
          textColor = { white = 0 }, frame = { x = x + 33, y = 2.5, w = 10, h = 14 } }
      )
      x = x + 50
    end
  end
  local image = canvas:imageFromCanvas()
  canvas:delete()
  return image:size({ w = width * icon_scale, h = 18 * icon_scale })
end

local function render(status)
  dji_battery.latest_status = status
  if not dji_battery.menu_bar then return end
  if not receiver_present then
    dji_battery.menu_bar:removeFromMenuBar()
    display_key = nil
    return
  end
  local transmitters = status.state == "connected" and status.transmitters or {}
  local key, descriptions, low, charging = status.state, {}, false, false
  for _, tx in ipairs(transmitters) do
    key = key .. string.format(":%d:%s:%s", tx.unit, tostring(tx.gauge), tostring(tx.charging))
    descriptions[#descriptions + 1] = battery_description(tx)
    low = low or (tx.gauge ~= nil and tx.gauge >= 6)
    charging = charging or tx.charging == true
  end
  key = key .. (status.message or "")
  if key == display_key then return end
  display_key = key
  local message = status.message or (#transmitters == 0 and "No transmitter connected" or nil)
  dji_battery.menu_bar:setTitle(low and "!" or charging and "⚡" or "")
    :setIcon(battery_icon(transmitters), true)
    :setTooltip("DJI Mic batteries\n" .. (message or table.concat(descriptions, "\n")))
  local menu = { { title = "DJI Mic batteries", disabled = true } }
  if message then menu[#menu + 1] = { title = message, disabled = true } end
  for _, description in ipairs(descriptions) do menu[#menu + 1] = { title = description, disabled = true } end
  menu[#menu + 1] = { title = "-" }
  menu[#menu + 1] = { title = "Seven battery levels; no exact percentage", disabled = true }
  menu[#menu + 1] = { title = "Reconnect battery reader", fn = function() dji_battery.start() end }
  menu[#menu + 1] = { title = "Hide until Hammerspoon reloads", fn = function()
    -- Keep a recovery control visible after this item's own menu disappears.
    hs.menuIcon(true)
    hs.alert.show("To show DJI batteries again:\nHammerspoon icon → Reload Config", nil, nil, 8)
    dji_battery.stop()
  end }
  dji_battery.menu_bar:setMenu(menu)
  dji_battery.menu_bar:returnToMenuBar()
end

-- Native menus pause hs.task output delivery while common-mode timers continue.
-- The helper owns USB freshness; delivery gaps here aren't receiver failures.
local function consume(output)
  pending = pending .. (output or "")
  while true do
    local newline = pending:find("\n", 1, true)
    if not newline then break end
    local line = pending:sub(1, newline - 1)
    pending = pending:sub(newline + 1)
    local ok, status = pcall(hs.json.decode, line)
    if ok and type(status) == "table" and type(status.state) == "string"
      and type(status.transmitters) == "table" then
      render(status)
    end
  end
  if #pending > 8192 then pending = "" end
end

start_reader = function()
  if not running then return end
  pending = ""
  local current_generation = generation
  reader = hs.task.new(helper_path, function(exit_code, _, standard_error)
    if not running or current_generation ~= generation then return end
    reader = nil
    log.ef("battery reader exited code=%d stderr=%s", exit_code, standard_error)
    render({ state = "error", transmitters = {}, message = "Battery reader stopped; reconnecting…" })
    retry_timer = hs.timer.doAfter(2, start_reader)
  end, function(_, standard_output, standard_error)
    if not running or current_generation ~= generation then return false end
    consume(standard_output)
    if standard_error ~= "" then log.w(standard_error) end
    return true
  end, { "--watch" })
  if not reader or not reader:start() then
    reader = nil
    render({ state = "error", transmitters = {}, message = "Battery reader unavailable. Reinstall the DJI Mic integration." })
  end
end

function dji_battery.stop()
  running = false
  generation = generation + 1
  if retry_timer then retry_timer:stop(); retry_timer = nil end
  if usb_watcher then usb_watcher:stop(); usb_watcher = nil end
  if reader then reader:terminate(); reader = nil end
  if dji_battery.menu_bar then dji_battery.menu_bar:delete(); dji_battery.menu_bar = nil end
  if hs.shutdownCallback == shutdown_callback then hs.shutdownCallback = previous_shutdown end
  display_key = nil
  return dji_battery
end

function dji_battery.start()
  dji_battery.stop()
  running = true
  receiver_present = receiver_is_attached()
  dji_battery.menu_bar = hs.menubar.new(false, "dji_mic_battery")
  usb_watcher = hs.usb.watcher.new(function(event)
    if not running or not is_dji_receiver(event) then return end
    receiver_present = receiver_is_attached()
    render({ state = receiver_present and "waiting" or "disconnected", transmitters = {},
      message = receiver_present and "Reading DJI transmitter batteries…" or "Connect the DJI receiver using USB-C." })
  end):start()
  render({ state = "waiting", transmitters = {}, message = "Reading DJI transmitter batteries…" })
  previous_shutdown = hs.shutdownCallback
  shutdown_callback = function()
    local previous = previous_shutdown
    dji_battery.stop()
    if previous then previous() end
  end
  hs.shutdownCallback = shutdown_callback
  start_reader()
  return dji_battery
end

return dji_battery
