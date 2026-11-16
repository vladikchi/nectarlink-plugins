-- API 32 contract checks; no real host, profile, network or processes.
dofile("tests/test_runtime.lua")
local compat = require("./ui/compat.luau")
local host = setmetatable({}, {
  __index = function(_, kind)
    return function(props, children)
      assert(props.clip == nil, "API 52 clip must never reach the host")
      return { type = kind, props = props, children = children or {} }
    end
  end,
})
local old = { surface_variant = "#123456", outline = "#abcdef" }
local new =
  { surface_container = "#223344", surface_container_high = "#445566", outline_variant = "#ddeeff" }
for _, palette in ipairs({ old, new }) do
  local ui = compat.new(host, function(role)
    return palette[role]
  end)
  local callback = function()
    error("construction must not execute callbacks")
  end
  local input = {
    fill = "card/0.5",
    border = "muted_border/0.35",
    clip = true,
    width = 120,
    onClick = callback,
  }
  local label = ui.label({ text = string.rep("Long name 🦀", 100), maxLines = 1 })
  local node = ui.row(input, { ui.glyph({ size = 20 }), label })
  assert(input.clip == true and input.fill == "card/0.5", "caller props must not change")
  assert(node.props.onClick == callback)
  assert(node.props.fill == (palette.surface_container or palette.surface_variant) .. "80")
  assert(node.props.border == (palette.outline_variant or palette.outline) .. "59")
  assert(label.props.maxWidth == 100 and label.props.maxLines == 1)
  assert(ui.colorValue("primary/0.18") == "primary/0.18")
  assert(ui.colorValue("#123456") == "#123456")
  assert(ui.box({ fill = "card/0" }).props.fill:sub(-2) == "00")
  assert(ui.box({ fill = "card/1" }).props.fill:sub(-2) == "ff")
  assert(
    ui.box({ fill = "raised" }).props.fill
      == (palette.surface_container_high or palette.surface_variant)
  )
  -- Palette lookup is performed per construction, not frozen at module load.
  local token = palette.surface_container and "surface_container" or "surface_variant"
  palette[token] = "#010203"
  assert(ui.box({ fill = "card" }).props.fill == "#010203")
end
local ui = compat.new(host, function(role)
  return old[role]
end)
local text = ui.label({ text = "bounded", maxWidth = 15 })
ui.column({ width = 100, paddingH = 10 }, { text })
assert(text.props.maxWidth == 15, "existing narrower bounds must win")
local flexible = ui.label({ text = "flexible" })
ui.row({ width = 100, gap = 5 }, { ui.box({ width = 40 }), flexible })
assert(flexible.props.maxWidth == 55)
-- Exercise the complete real panel against a host that rejects new props and
-- raw adapter aliases. Navigation must not dispatch consequential commands.
local commands, tree, watcher = {}, nil, nil
_G.ui = host
panel = {
  render = function(node)
    tree = node
  end,
}
local fixture = {
  state = "ready",
  devices = {
    {
      id = "demo",
      name = string.rep("Phone 🦀", 100),
      online = true,
      battery = { level = 50 },
      ringing = false,
    },
  },
}
noctalia = {
  getColor = function(role)
    return old[role]
  end,
  getConfig = function()
    return nil
  end,
  json = {
    encode = function(v)
      return v
    end,
    decode = function(v)
      return v
    end,
  },
  state = {
    get = function()
      return fixture
    end,
    watch = function(_, cb)
      watcher = cb
    end,
    set = function(_, value)
      commands[#commands + 1] = value
    end,
  },
}
dofile("panel.luau")
onOpen()
local function validate(node)
  assert(node.props.clip == nil)
  for _, key in ipairs({ "fill", "border", "color", "track" }) do
    local value = node.props[key]
    local role = type(value) == "string" and value:match("^[%w_]+") or nil
    assert(role ~= "card" and role ~= "raised" and role ~= "muted_border")
    assert(not value or not value:find("surface_container", 1, true))
  end
  if node.type == "label" then
    assert(node.props.maxWidth and node.props.maxWidth > 0 and node.props.maxWidth <= 828)
    assert(node.props.maxLines and node.props.maxLines > 0)
  end
  for _, child in ipairs(node.children) do
    validate(child)
  end
end
for _, page in ipairs({ "home", "messages", "calls", "photos", "apps", "deck", "guide" }) do
  onNavigate(page)
  validate(tree)
  assert(tree.props.width == 828 and tree.props.height == 438)
end
for _, command in ipairs(commands) do
  assert(command.action == "visible" or command.action == "page" or command.action == "page_leave")
end
onClose()
print(
  "PASS: old/new palette aliases, alpha, theme refresh, API 32 props, bounded text and untouched callbacks"
)
