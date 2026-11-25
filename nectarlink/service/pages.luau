--!nonstrict
-- Bounded read-only cache. One request per key; epoch discards obsolete replies.
-- This module cannot send SMS, dial or execute Deck actions.
local M = {}
local size = require("../cache_size.luau")
local access = require("../message_access.luau")
local function featureReason(data, page)
  if data.unsupported == true then return "feature_unsupported" end
  local upgrade = data.upgrade
  if type(upgrade) ~= "table" then return "permission" end
  if page == "apps" and data.feature == "mirroring.app_windows"
    and upgrade.action == "raisePower" and upgrade.target == "elevated"
  then return "apps_elevated" end
  if upgrade.action == "enableToggle" then return "feature_toggle_disabled" end
  if upgrade.action == "updateApp" then
    if upgrade.target == "phone" then return "feature_update_phone" end
    if upgrade.target == "desktop" then return "feature_update_desktop" end
  end
  return "permission"
end
-- Validate fields the UI consumes as strings, numbers and arrays.
-- A malformed response must not evict the last valid cached result.
local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) <= 9007199254740991
end
local function optionalFields(value, names, kind)
  for _, name in ipairs(names) do
    local field = value[name]
    if field ~= nil and (type(field) ~= kind or (kind == "number" and not finite(field))) then
      return false
    end
  end
  return true
end
local function array(value, validItem)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for key, item in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or not validItem(item) then
      return false
    end
    count = count + 1
  end
  for index = 1, count do
    if value[index] == nil then
      return false
    end
  end
  return true
end
local function validData(data)
  if
    type(data) ~= "table"
    or not optionalFields(data, { "notice", "appScope" }, "string")
    or not optionalFields(data, {
      "more", "reply", "dial", "control", "smsIncomplete", "localChatsIncomplete",
    }, "boolean")
  then
    return false
  end
  if
    not array(data.items, function(item)
      return type(item) == "table"
        and type(item.id) == "string"
        and optionalFields(
          item,
          { "title", "subtitle", "kind", "number", "thumbnailPath", "iconPath", "appScope" },
          "string"
        )
        and optionalFields(item, { "date", "size", "duration" }, "number")
        and optionalFields(item, { "outgoing" }, "boolean")
        and (item.size == nil or item.size >= 0)
        and (item.duration == nil or item.duration >= 0)
        and (
          item.addresses == nil
          or array(item.addresses, function(address)
            return type(address) == "string"
          end)
        )
    end)
  then
    return false
  end
  if
    data.albums ~= nil
    and not array(data.albums, function(album)
      return type(album) == "table"
        and type(album.id) == "string"
        and optionalFields(album, { "name" }, "string")
    end)
  then
    return false
  end
  if data.active ~= nil then
    local active = data.active
    if
      type(active) ~= "table"
      or type(active.state) ~= "string"
      or not optionalFields(active, { "id", "name", "number" }, "string")
      or (active.state ~= "ended" and type(active.id) ~= "string")
    then
      return false
    end
  end
  return true
end

function M.new(cache, visibility, clock, snapshot, api, publish, onlineDevice, copy, limits)
  -- cache owns original responses; snapshot.page is the displayed projection.
  -- clock.ticks measures scheduler intervals, nowMs measures entry age.
  local credentials = api.credentials
  local request = api.request
  local PAGE_TTL_TICKS = { messages = 10, calls = 2, photos = 60, apps = 150, deck = 15 }
  local maxBytes = limits.pageCacheBytes or 4 * 1024 * 1024
  cache.errors = cache.errors or {}
  local lastPhoto = {}

  local function resetPages()
    cache.entries = {}
    cache.jobs = {}
    cache.retry = {}
    cache.errors = {}
    lastPhoto = {}
    cache.epoch = cache.epoch + 1
    snapshot.page = nil
    snapshot.threads = nil
    snapshot.cacheEpoch = cache.epoch
    snapshot.messagesDenied = nil
    snapshot.deniedPages = nil
    snapshot.pageRevocations = nil
    snapshot.smsDenied = nil
  end

  local function threadIndex(command)
    local query = command.value
    return snapshot.pageCacheV2 == true and query.page == "messages" and (query.thread or "") == ""
  end

  local function pageIdentity(command)
    -- Length prefixes prevent collisions from separators inside search/id fields.
    local query = command.value
    if threadIndex(command) then
      return "threads:" .. command.device
    end
    local fields = {
      command.device,
      query.page,
      query.thread or "",
      query.album or "",
      tostring(query.before or ""),
      query.before_id or "",
      tostring(query.offset or 0),
      query.search or "",
      tostring(query.limit or 5),
    }
    for i, value in ipairs(fields) do
      local text = tostring(value)
      fields[i] = tostring(#text) .. ":" .. text
    end
    return table.concat(fields)
  end

  local function cacheTime()
    return noctalia.nowMs and noctalia.nowMs() or clock.ticks * limits.updateIntervalMs
  end

  local function previewData(data)
    -- Runtime JSON/state transfer copies data. Clone a page only when removing
    -- a missing preview, not on every warm read.
    local out = data
    local valid = true
    if noctalia.fileExists then
      for index, item in ipairs(data.items or {}) do
        for _, field in ipairs({ "thumbnailPath", "iconPath" }) do
          if type(item[field]) == "string" and not noctalia.fileExists(item[field]) then
            if out == data then
              out = copy(data)
            end
            out.items[index][field] = nil
            valid = false
          end
        end
      end
    end
    return out, valid
  end

  local function showPage(command, entry, refreshing, stale, err, preparedData, reason, surface)
    local data = preparedData or (entry and previewData(entry.data) or nil)
    if data and threadIndex(command) then
      local query = command.value
      local offset, limit = query.offset or 0, query.limit or 7
      local items = {}
      for i = offset + 1, math.min(offset + limit, #data.items) do
        items[#items + 1] = data.items[i]
      end
      data = { items = items, more = #data.items > offset + limit, notice = data.notice }
    end
    snapshot[surface or "page"] = {
      key = command.value.key,
      device = command.device,
      kind = command.value.page,
      thread = command.value.thread or "",
      status = data and "ready" or (err or "loading"),
      data = data,
      refreshing = refreshing or false,
      stale = stale or false,
      error = reason,
      partial = entry and entry.partial or nil,
    }
  end

  local function forCurrent(key, apply)
    if not visibility.open then return end
    if visibility.activePage and pageIdentity(visibility.activePage) == key then
      apply(visibility.activePage, "page")
    end
    if visibility.threads and pageIdentity(visibility.threads) == key then
      apply(visibility.threads, "threads")
    end
  end

  local function isLanding(query)
    return (query.thread or "") == "" and (query.album or "") == ""
      and (query.offset or 0) == 0 and query.before == nil and (query.search or "") == ""
  end

  local function trimPages()
    -- Entry counts alone are insufficient: one page may contain large text.
    -- Estimate sizes on response arrival, not on every warm read.
    while true do
      local count, bytes, oldest, stamp, rank = 0, 0, nil, math.huge, math.huge
      for key, entry in pairs(cache.entries) do
        count = count + 1
        entry.weight = entry.weight or size(entry.data, maxBytes)
        bytes = bytes + entry.weight
        local priority = (entry.landing or lastPhoto[entry.device] == key) and 1 or 0
        if priority < rank or (priority == rank and entry.used < stamp) then
          oldest, stamp, rank = key, entry.used, priority
        end
      end
      if count <= limits.pageCacheLimit and bytes <= maxBytes then
        return
      end
      cache.entries[oldest] = nil
    end
  end

  local function invalidateKind(device, kind, thread)
    local function matches(e)
      return (not device or e.device == device) and (not kind or e.kind == kind)
        and (not thread or e.thread == thread)
    end
    for key, e in pairs(cache.entries) do
      if matches(e) then
        cache.entries[key] = nil
        cache.retry[key] = nil
        cache.errors[key] = nil
      end
    end
    for key, e in pairs(cache.jobs) do
      if matches(e) then
        cache.jobs[key] = nil
      end
    end
    if device and (not kind or kind == "photos") then lastPhoto[device] = nil end
    for _, surface in ipairs({ "page", "threads" }) do
      local shown = snapshot[surface]
      if shown and matches(shown) then snapshot[surface] = nil end
    end
  end

  local function deny(device, kind, reason)
    invalidateKind(device, kind)
    local scope = device and (kind .. ":" .. device) or kind
    snapshot.pageRevocations = snapshot.pageRevocations or {}
    snapshot.pageRevocations[scope] = (snapshot.pageRevocations[scope] or 0) + 1
    if not device then
      snapshot.messagesDenied = true
    else
      snapshot.deniedPages = snapshot.deniedPages or {}
      snapshot.deniedPages[kind .. ":" .. device] = true
    end
    local function showDenied(current, surface)
      if current and current.value.page == kind and (not device or current.device == device) then
        local key = pageIdentity(current)
        cache.retry[key] = clock.ticks + limits.pageRetryTicks
        cache.errors[key] = reason
        showPage(current, nil, false, false, "failed", nil, reason, surface)
      end
    end
    if visibility.open then
      showDenied(visibility.activePage, "page")
      showDenied(visibility.threads, "threads")
    end
  end

  local function revokePrivate()
    invalidateKind(nil, "messages")
    snapshot.pageRevocations = snapshot.pageRevocations or {}
    snapshot.pageRevocations.messages = (snapshot.pageRevocations.messages or 0) + 1
    snapshot.messagesDenied = nil
  end

  local function allowPrivate()
    snapshot.messagesDenied = nil
    for key, reason in pairs(cache.errors) do
      if reason == "private_api_disabled" then cache.retry[key], cache.errors[key] = nil, nil end
    end
  end

  local function setNotificationPolicy(policy, previousInstance)
    local function readsChats(entry)
      return entry.kind == "messages" and not access.smsThread(entry.thread)
    end
    for key, job in pairs(cache.jobs) do
      if readsChats(job) then cache.jobs[key], cache.retry[key], cache.errors[key] = nil, nil, nil end
    end
    for key, reason in pairs(cache.errors) do
      if reason == "chat_unavailable" then cache.retry[key], cache.errors[key] = nil, nil end
    end
    local function scrub(entry)
      if not readsChats(entry) then return true end
      if access.chatThread(entry.thread) then
        return entry.data and access.allowsScope(policy, entry.data.appScope, previousInstance)
      end
      local data = access.withoutHiddenChats(entry.data, policy, previousInstance)
      if data ~= entry.data then entry.data, entry.weight = data, nil end
      return true
    end
    for key, entry in pairs(cache.entries) do
      if not scrub(entry) then cache.entries[key] = nil
      elseif entry.kind == "messages" and entry.thread == "" then
        entry.policyStale = true -- A now-visible chat may need to be added back.
        cache.retry[key], cache.errors[key] = nil, nil
      end
    end
    for _, surface in ipairs({ "page", "threads" }) do
      local view = snapshot[surface]
      if view and readsChats(view) then
        if not scrub(view) then snapshot[surface] = nil
        else view.refreshing = false end
      end
    end
  end

  local function allowApps(device)
    if snapshot.deniedPages then snapshot.deniedPages["apps:" .. device] = nil end
    local prefix = tostring(#device) .. ":" .. device .. "4:apps"
    for key in pairs(cache.retry) do
      if key:sub(1, #prefix) == prefix then cache.retry[key], cache.errors[key] = nil, nil end
    end
  end

  local function setSmsAccess(device, allowed)
    if allowed == true then
      if snapshot.smsDenied then snapshot.smsDenied[device] = nil end
      return
    end
    if allowed ~= false or (snapshot.smsDenied and snapshot.smsDenied[device]) then return end
    snapshot.smsDenied = snapshot.smsDenied or {}
    snapshot.smsDenied[device] = true
    snapshot.pageRevocations = snapshot.pageRevocations or {}
    local scope = "sms:" .. device
    snapshot.pageRevocations[scope] = (snapshot.pageRevocations[scope] or 0) + 1
    local function matches(e)
      return e.device == device and e.kind == "messages" and (e.thread == "" or access.smsThread(e.thread))
    end
    for key, entry in pairs(cache.entries) do
      if matches(entry) then
        if access.smsThread(entry.thread) then
          cache.entries[key] = nil
        else
          entry.data = access.withoutSms(entry.data)
          entry.weight = nil
          entry.failed = true
        end
        cache.retry[key], cache.errors[key] = nil, nil
      end
    end
    for key, job in pairs(cache.jobs) do
      if matches(job) then
        cache.jobs[key], cache.retry[key], cache.errors[key] = nil, nil, nil
      end
    end
    for _, surface in ipairs({ "page", "threads" }) do
      local view = snapshot[surface]
      if view and matches(view) then
        if access.smsThread(view.thread) then
          snapshot[surface] = nil
        else
          view.data = access.withoutSms(view.data)
          view.refreshing = false
        end
      end
    end
  end

  local readPage
  local function followRefresh(key, job)
    if not job.refreshRequested or job.epoch ~= cache.epoch then return end
    forCurrent(key, function(current, pane)
      if job.refreshRequested then
        job.refreshRequested = nil
        readPage(current, false, true, pane)
      end
    end)
  end

  local function keepPreview(key, job)
    local previous = cache.entries[key]
    if (previous and not previous.partial) or not job.preview or not job.preview.partial then return end
    local data = job.preview.data
    local weight = size(data, maxBytes)
    if weight > maxBytes then return end
    cache.clock = cache.clock + 1
    cache.entries[key] = {
      data = data, partial = true, at = cacheTime(), used = cache.clock, weight = weight,
      device = job.device, kind = job.kind, thread = job.thread,
    }
    trimPages()
  end

  readPage = function(command, quiet, force, surface)
    -- Quiet reads do not queue another refresh; only an explicit click does.
    local config, credentialError = credentials()
    if not config then
      resetPages()
      snapshot.state = "unconfigured"
      snapshot.error = credentialError
      publish()
      return
    end
    local query = command.value
    local thread = query.thread or ""
    local function smsDenied()
      return query.page == "messages" and snapshot.smsDenied and snapshot.smsDenied[command.device]
    end
    if smsDenied() and access.smsThread(thread) then
      if not quiet then
        showPage(command, nil, false, false, "failed", nil, "sms_denied", surface)
        publish()
      end
      return
    end
    local key = pageIdentity(command)
    local index = threadIndex(command)
    local warm = surface == "warm"
    local progressivePhoto = snapshot.pageCacheV2 == true and query.page == "photos"
    if not warm and not quiet and query.page == "photos" then lastPhoto[command.device] = key end
    local entry = cache.entries[key]
    cache.clock = cache.clock + 1
    if entry then
      entry.used = cache.clock
    end
    local valid = true
    local displayData
    if entry then
      displayData, valid = previewData(entry.data)
    end
    local age = entry and cacheTime() - entry.at or 0
    local pendingDetails = progressivePhoto and entry and entry.detailsRetryAt
    local retryDetails = pendingDetails and not quiet and force ~= true and query.force ~= true
      and cacheTime() >= entry.detailsRetryAt
    local fresh = entry
      and not entry.partial
      and not entry.failed
      and not entry.policyStale
      and age >= 0
      and age < (PAGE_TTL_TICKS[query.page] or 10) * limits.updateIntervalMs
      and valid
    if query.page ~= "deck" and not onlineDevice(command.device) then
      if not warm then
        showPage(command, entry, false, true, "failed", displayData, "phone_offline", surface)
        publish()
      end
      return
    end
    force = force == true or (not quiet and query.force == true)
    local backendForce = force or (entry and entry.failed) or false
    if not quiet and (entry or cache.jobs[key]) then
      showPage(
        command,
        entry or (cache.jobs[key] and cache.jobs[key].preview),
        cache.jobs[key] ~= nil,
        entry ~= nil and not fresh,
        nil,
        displayData,
        entry and entry.error,
        surface
      )
      publish()
    end
    -- Every offset reads the same index. Paging never waits for a phone
    -- refresh: that is done explicitly or by the scheduler.
    if not force and not retryDetails
      and (fresh or (index and entry and not entry.partial and not entry.policyStale and not quiet)) then
      return
    end
    if cache.jobs[key] then
      local pending = cache.jobs[key]
      if not quiet then
        if force and not pending.forced then pending.refreshRequested = true end
        if not entry and pending.localPreview then pending.localPreview(query) end
      end
      return
    end
    if not force and cache.retry[key] and clock.ticks < cache.retry[key] then
      if not entry and not warm then
        -- Retain the last error reason while throttling repeated reads.
        showPage(command, nil, false, true, "failed", nil, cache.errors[key] or "request_failed", surface)
        publish()
      end
      return
    end
    local job =
      { epoch = cache.epoch, started = clock.ticks, device = command.device, kind = query.page, thread = thread }
    job.forced = backendForce
    local function validJob()
      return cache.jobs[key] == job and job.epoch == cache.epoch
    end
    local function emit(result, refreshing, stale, status, reason)
      forCurrent(key, function(current, pane)
        showPage(current, result, refreshing, stale, status, nil, reason, pane)
      end)
      publish()
    end
    local function rejected(status, data)
      if status == 401 then
        resetPages()
        snapshot.state = "unauthorized"
        snapshot.error = "unauthorized"
        publish()
        return true
      end
      local code = type(data) == "table" and data.error
      if query.page == "messages" and thread:sub(1, 5) == "chat:" and
        ((status == 404 and code == "chat_unavailable") or (status == 403 and code == "feature_denied"))
      then
        -- Older builds report a missing/hidden chat as a feature denial.
        -- Neither response is sufficient reason to evict unrelated threads.
        local reason = status == 404 and "chat_unavailable" or featureReason(data, query.page)
        invalidateKind(command.device, "messages", thread)
        local active = visibility.activePage
        if visibility.open and active and active.device == command.device
          and active.value.page == "messages" and active.value.thread == thread
        then
          local activeKey = pageIdentity(active)
          cache.retry[activeKey], cache.errors[activeKey] = clock.ticks + limits.pageRetryTicks, reason
          showPage(active, nil, false, false, "failed", nil, reason)
        end
        publish()
        return true
      end
      if status == 403 and code == "sms_denied" and query.page == "messages" then
        setSmsAccess(command.device, false)
        if cache.jobs[key] == job then cache.jobs[key] = nil end
        publish()
        return true
      end
      if status == 403 and ((query.page == "messages" and code == "not_allowed") or code == "feature_denied") then
        local reason = code == "not_allowed" and "private_api_disabled" or featureReason(data, query.page)
        local device = command.device
        if query.page == "messages" and code ~= "feature_denied" then device = nil end
        deny(device, query.page, reason)
        cache.retry[key] = clock.ticks + limits.pageRetryTicks
        cache.errors[key] = reason
        publish()
        return true
      end
      return false
    end
    local function save(data, at)
      cache.clock = cache.clock + 1
      local result = {
        data = data, at = at or cacheTime(), used = cache.clock,
        device = command.device, kind = query.page, weight = size(data, maxBytes),
        thread = thread,
        landing = index or ((query.page == "apps" or query.page == "photos") and isLanding(query)),
      }
      -- A valid oversized result is displayed but not retained in the LRU.
      cache.entries[key] = result.weight <= maxBytes and result or nil
      cache.retry[key] = nil
      cache.errors[key] = nil
      trimPages()
      return result
    end
    local function fail(reason)
      cache.jobs[key] = nil
      keepPreview(key, job)
      cache.retry[key] = clock.ticks + limits.pageRetryTicks
      cache.errors[key] = reason
      local previous = cache.entries[key]
      if previous then
        previous.failed = true
        previous.error = reason
      end
      return previous or job.preview
    end
    local function missingThumbnails(data)
      local ids = {}
      for _, item in ipairs(data.items) do
        if not item.thumbnailPath then ids[#ids + 1] = item.id end
      end
      return ids
    end
    local function loadDetails(result, data, ids)
      job.preview = result
      job.details = true
      job.started = clock.ticks
      emit(result, true, false)
      request("/v1/page", {
        device = command.device, page = "photos", photo_ids = ids, force = force,
      }, function(ok, status, details)
        if not validJob() or rejected(status, details) then return end
        cache.jobs[key] = nil
        local valid = ok and validData(details)
        local failed = not valid or details.photoDetailsIncomplete == true
        if valid then
          local paths = {}
          for _, item in ipairs(details.items) do paths[item.id] = item.thumbnailPath end
          local merged = copy(data)
          for _, item in ipairs(merged.items) do item.thumbnailPath = paths[item.id] or item.thumbnailPath end
          merged.albums = details.albums or merged.albums
          failed = failed or not merged.albums or #missingThumbnails(merged) > 0
          result = save(merged, result.at)
        end
        result.detailsRetryAt = failed and (cacheTime() + limits.pageRetryTicks * limits.updateIntervalMs) or nil
        result.error = failed and "photo_details_unavailable" or nil
        emit(result, false, failed, nil, result.error)
        followRefresh(key, job)
      end, config)
    end
    cache.jobs[key] = job
    if retryDetails then
      loadDetails(entry, displayData, missingThumbnails(displayData))
      return
    end
    if not warm and (not quiet or not entry) then
      showPage(command, entry, true, entry ~= nil, nil, displayData, nil, surface)
      publish()
    end
    local function localPreview(visibleQuery)
      if job.localPreviewStarted or snapshot.messagesDenied or not snapshot.localMessageThreads
        or (visibleQuery.offset or 0) ~= 0 or not validJob()
      then return end
      job.localPreviewStarted = true
      request("/v1/page", {
        device = command.device, page = "messages", limit = visibleQuery.limit, local_only = true,
        thread_index = index or nil,
      }, function(ok, status, data)
        if not validJob() or rejected(status, data) then return end
        if ok and validData(data) and #data.items > 0 then
          if smsDenied() then data = access.withoutSms(data) end
          data = access.withoutHiddenChats(data, snapshot.notificationPolicy)
          job.preview = { data = data, partial = true }
          emit(job.preview, true, true)
        end
      end, config)
    end
    if not entry and query.page == "messages" and thread == "" then
      job.localPreview = localPreview
      if not warm then
        localPreview(query)
        if not validJob() then return end
      end
    end
    request("/v1/page", {
      device = command.device,
      page = query.page,
      thread = query.thread,
      album = query.album,
      before = query.before,
      before_id = query.before_id,
      offset = query.offset,
      search = query.search,
      limit = query.limit,
      force = backendForce,
      thread_index = index or nil,
      photo_rows_only = progressivePhoto or nil,
    }, function(ok, status, data, reason)
      -- Removed/replaced job or changed epoch: this response no longer has an owner.
      if not validJob() or rejected(status, data) then return end
      if ok and not validData(data) then ok, reason = false, "invalid_response" end
      if not ok then
        if status == 409 and type(data) == "table" and data.error == "timeout" then reason = "timeout" end
        reason = reason or (status == 404 and "unsupported" or "request_failed")
        emit(fail(reason), false, true, status == 404 and "unsupported" or "failed", reason)
        followRefresh(key, job)
        return
      end
      if query.page == "messages" and thread == "" then
        if smsDenied() then data = access.withoutSms(data) end
        data = access.withoutHiddenChats(data, snapshot.notificationPolicy)
      elseif query.page == "messages" and access.chatThread(thread)
        and not access.allowsScope(snapshot.notificationPolicy, data.appScope)
      then
        rejected(404, { error = "chat_unavailable" })
        return
      end
      if query.page == "messages" and (data.smsIncomplete or data.localChatsIncomplete) then
        local previous = cache.entries[key]
        if (not previous or previous.partial) and (index or (query.offset or 0) == 0) and #data.items > 0 then
          job.preview = { data = data, partial = true }
        end
        local incomplete = data.localChatsIncomplete and "local_chats_unavailable" or "sms_unavailable"
        emit(fail(incomplete), false, true, "failed", incomplete)
        followRefresh(key, job)
        return
      end
      if query.page == "messages" then snapshot.messagesDenied = nil end
      if snapshot.deniedPages then snapshot.deniedPages[query.page .. ":" .. command.device] = nil end
      local ids
      if progressivePhoto then
        ids = missingThumbnails(data)
        if #ids == 0 and data.albums and not force then ids = nil end
        local previous = cache.entries[key]
        if not data.albums and previous then data.albums = previous.data.albums end
      end
      local result = save(data)
      if not ids then
        cache.jobs[key] = nil
        emit(result, false, false)
        followRefresh(key, job)
        return
      end

      -- The grid is ready; album metadata and missing images do not gate it.
      loadDetails(result, data, ids)
    end, config)
  end
  return {
    reset = resetPages,
    identity = pageIdentity,
    show = showPage,
    eachCurrent = forCurrent,
    deny = deny,
    revokePrivate = revokePrivate,
    allowPrivate = allowPrivate,
    setNotificationPolicy = setNotificationPolicy,
    allowApps = allowApps,
    cancelInactiveRefreshes = function()
      for key, job in pairs(cache.jobs) do
        if job.refreshRequested then
          local current = false
          forCurrent(key, function() current = true end)
          if not current then job.refreshRequested = nil end
        end
      end
    end,
    setSmsAccess = setSmsAccess,
    timeout = function(key, job)
      if cache.jobs[key] ~= job then return end
      cache.jobs[key] = nil
      keepPreview(key, job)
      cache.retry[key] = clock.ticks + limits.pageRetryTicks
      cache.errors[key] = "timeout"
      local entry = cache.entries[key]
      local reason = "timeout"
      if job.details then
        reason = "photo_details_unavailable"
        if entry then
          entry.detailsRetryAt = cacheTime() + limits.pageRetryTicks * limits.updateIntervalMs
          entry.error = reason
          -- Detail retries have their own deadline; the rows remain usable.
          cache.retry[key], cache.errors[key] = nil, nil
        end
      elseif entry then
        entry.failed, entry.error = true, reason
      end
      forCurrent(key, function(current, surface)
        showPage(current, entry or job.preview, false, true, "failed", nil, reason, surface)
      end)
      publish()
      followRefresh(key, job)
    end,
    invalidate = invalidateKind,
    read = readPage,
    hasJob = function() return next(cache.jobs) ~= nil end,
    cachedAt = function(command)
      local entry = cache.entries[pageIdentity(command)]
      return entry and not entry.partial and entry.at or nil
    end,
    time = cacheTime,
    isIndex = threadIndex,
  }
end
return M
