--!nonstrict
local snapshot = nil
local lastView=nil
local function setting(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "boolean" then return value end
  return fallback
end
local function render()
  local phone = nil
  for _, d in ipairs(snapshot and snapshot.devices or {}) do
    if d.online then phone = d; break end
  end
  local color = phone and "on_surface" or "outline_variant"
  local fields={phone~=nil,phone and phone.name or "",phone and phone.battery and phone.battery.level or "",
    phone and phone.battery and phone.battery.charging or false,barWidget.isVertical(),setting("hide_offline",false),
    setting("show_percentage",true),setting("show_charging",true),setting("show_name",false)}
  for i,v in ipairs(fields) do local s=tostring(v); fields[i]=tostring(#s)..":"..s end
  local signature=table.concat(fields)
  if signature==lastView then return end
  lastView=signature
  barWidget.setVisible(phone ~= nil or not setting("hide_offline", false))
  local children = { ui.glyph({ name = "device-mobile", size = 18, color = color }) }
  if phone and phone.battery and phone.battery.level then
    if phone.battery.charging and setting("show_charging", true) then
      table.insert(children, ui.glyph({ name = "battery-charging", size = 16, color = "primary" }))
    end
    if setting("show_percentage", true) then
      table.insert(children, ui.label({ text = tostring(phone.battery.level) .. "%", color = color }))
    end
  end
  if phone and setting("show_name", false) and not barWidget.isVertical() then
    table.insert(children, ui.label({ text = phone.name, maxLines = 1, color = color }))
  end
  barWidget.render((barWidget.isVertical() and ui.column or ui.row)({ gap = 5, align = "center" }, children))
  local rows = { { key = "NectarLink", value = phone and phone.name or "Телефон не подключён" } }
  if phone and phone.battery then
    table.insert(rows, { key = "Питание", value = phone.battery.charging and "Заряжается" or "От аккумулятора" })
  end
  barWidget.setTooltip(rows)
end
noctalia.state.watch("nl.snapshot", function(raw)
  snapshot = raw and noctalia.json.decode(raw) or nil; render()
end)
function update()
  noctalia.setUpdateInterval(10000)
  local raw = noctalia.state.get("nl.snapshot")
  snapshot = raw and noctalia.json.decode(raw) or nil; render()
end
function onClick() noctalia.togglePanel("local/nectarlink:controls") end
function onRightClick() noctalia.togglePanel("local/nectarlink:controls") end
function onConfigChanged() render() end
