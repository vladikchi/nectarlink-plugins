--!nonstrict
-- Warm only the first screen of a few read-only sections for the selected phone.
local M = {}
local kinds = { "messages", "photos", "apps" }
local interval = { messages = 120000, photos = 300000, apps = 600000 }

function M.new(pages, snapshot, visibility, online, geometry)
  local records, epoch, stableDevice, stableSince = {}, nil, nil, nil

  local function record(device)
    if epoch ~= snapshot.cacheEpoch then
      records, epoch = {}, snapshot.cacheEpoch
      stableDevice, stableSince = nil, nil
    end
    if not records[device] then records[device] = { visited = {}, attempts = {}, retried = {} } end
    return records[device]
  end

  local function visit(command)
    local kind = command.value.page
    if interval[kind] and snapshot.pageCacheV2 then
      record(command.device).visited[kind] = pages.time()
    end
  end

  local function update()
    if not snapshot.pageCacheV2 or snapshot.state ~= "ready" then
      stableDevice, stableSince = nil, nil
      return
    end
    local device
    for _, phone in ipairs(snapshot.devices) do
      if phone.id == visibility.device then
        device = phone.id
        break
      end
      if not device and phone.online then device = phone.id end
    end
    if not device or not online(device) then
      stableDevice, stableSince = nil, nil
      return
    end
    local state, now = record(device), pages.time()
    if stableDevice ~= device then stableDevice, stableSince = device, now end
    if visibility.open or pages.hasJob() or now - stableSince < 10000 then return end

    for _, kind in ipairs(kinds) do
      local denied = snapshot.deniedPages and snapshot.deniedPages[kind .. ":" .. device]
      if not denied and (kind ~= "messages" or (snapshot.privateMessages and not snapshot.messagesDenied)) then
        local limit = kind == "apps" and geometry.appsLayout().limit
          or (kind == "messages" and geometry.page.limits.messages or nil)
        local cmd = { device = device, value = { page = kind, limit = limit, key = "warm:" .. kind } }
        local at, last = pages.cachedAt(cmd), state.attempts[kind]
        local recent = state.visited[kind] and now - state.visited[kind] < 1800000
        local due = not last and not at
          or (not at and last and not state.retried[kind] and now - last >= 120000)
          or (recent and now - (at or 0) >= interval[kind] and (not last or now - last >= interval[kind]))
        if due then
          if last then state.retried[kind] = true end
          state.attempts[kind] = now
          pages.read(cmd, true, false, "warm")
          return
        end
      end
    end
  end

  return {
    update = update, visit = visit,
    forget = function(device) records[device] = nil end,
    rearm = function(kind)
      for _, state in pairs(records) do state.attempts[kind], state.retried[kind] = nil, nil end
    end,
  }
end

return M
