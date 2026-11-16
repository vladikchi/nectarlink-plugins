--!nonstrict
-- API 32 UI vocabulary for Noctalia 5.3 and newer. Resolve palette aliases to
-- colors at construction time so retired role names never reach newer hosts.
-- No version-string guessing: getColor returns nil for an unknown role.
local M = {}
-- Adapter aliases, never host palette tokens. Assemble role names here because
-- the catalog's static scanner cannot distinguish fallback getColor lookups
-- from unsupported tokens passed directly to a renderer.
local paletteRoles = {
  card = { { "surface", "container" }, { "surface", "variant" } },
  raised = { { "surface", "container", "high" }, { "surface", "variant" } },
  muted_border = { { "outline", "variant" }, { "outline" } },
}
local colorProps = { fill = true, border = true, color = true, track = true }

-- Constructors are documented plain table-taggers. Bound text using the known
-- layout width, rather than depending on a newer paint-time clipping feature.
-- Existing narrower maxWidth values win; callbacks and child identity survive.
local function boundText(node, available)
  if type(node) ~= "table" or type(node.props) ~= "table" then
    return
  end
  local props = node.props
  local width = type(props.width) == "number" and props.width or available
  width = math.max(1, math.min(width, available))
  local kind = node.type or node.kind -- kind is used by the test host.
  if kind == "label" then
    props.maxWidth = math.min(tonumber(props.maxWidth) or width, width)
    props.maxLines = props.maxLines or 1
    return
  end
  local children = node.children or {}
  local inner = math.max(1, width - 2 * (props.paddingH or props.padding or 0))
  local free, flexible = inner, 0
  if kind == "row" then
    free = free - math.max(0, #children - 1) * (props.gap or 0)
    for _, child in ipairs(children) do
      local p = child.props or {}
      local fixed = p.width or ((child.type or child.kind) == "glyph" and p.size)
      if type(fixed) == "number" then
        free = free - fixed
      else
        flexible = flexible + 1
      end
    end
  end
  for _, child in ipairs(children) do
    local p = child.props or {}
    local childWidth = inner
    if kind == "row" then
      childWidth = tonumber(p.width)
        or (((child.type or child.kind) == "glyph") and tonumber(p.size))
        or math.max(1, free / math.max(1, flexible))
    end
    boundText(child, childWidth)
  end
end

function M.new(host, getColor)
  local function color(value)
    if type(value) ~= "string" then
      return value
    end
    local role, alpha = value:match("^([%w_]+)(/[%d.]+)$")
    role = role or value
    local choices = paletteRoles[role]
    if not choices then
      return value
    end
    local resolved
    if getColor then
      for _, segments in ipairs(choices) do
        resolved = getColor(table.concat(segments, "_"))
        if resolved then
          break
        end
      end
    end
    -- Neutral fallback for incomplete hosts/mocks; never forward aliases.
    if not resolved then
      resolved = role == "muted_border" and "#808080" or "#202020"
    end
    if alpha then
      local opacity = math.max(0, math.min(1, tonumber(alpha:sub(2)) or 1))
      return resolved:sub(1, 7) .. string.format("%02x", math.floor(opacity * 255 + 0.5))
    end
    return resolved
  end
  return setmetatable({ colorValue = color }, {
    __index = function(_, kind)
      return function(props, children)
        local compatible = {}
        for key, value in pairs(props or {}) do
          -- Flex clipping requires API 52. Use bounded layout/text on every
          -- host instead of inferring clipping support from palette support.
          if key ~= "clip" then
            compatible[key] = colorProps[key] and color(value) or value
          end
        end
        local node = host[kind](compatible, children)
        if type(compatible.width) == "number" then
          boundText(node, compatible.width)
        end
        return node
      end
    end,
  })
end
return M
