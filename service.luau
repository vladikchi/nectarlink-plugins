--!nonstrict
-- Credentials stay in this service. Never publish or log the bearer token.
local snapshot = { state = "unconfigured", devices = {} }
local pending = false
local generation = 0
local ticks = 0
local panelOpen = false
local ringGeneration = 0
local ringStarted = 0
local ringRefreshing = false
local timelinePending = false
local timelineGeneration = 0
local timelineStarted = 0
local cameraGeneration = 0
local cameraStarted = 0
local notificationsPending = false
local notificationsGeneration = 0
local notificationsStarted = 0
local controlGeneration, controlStarted = 0, 0
local sessionPending, sessionRefreshing = false, false
local sessionGeneration, sessionStarted, sessionCommand, sessionCommandStarted = 0, 0, 0, 0
local typeCommand, typeStarted = 0, 0
local actionGeneration, actionStarted = 0, 0
local activePage = nil
local panelSection="home"
local pageCache, pageJobs, pageRetry = {}, {}, {}
local cacheEpoch, cacheClock = 0, 0
local lastPublished, credentialBinding = nil, nil
local warmedHome=nil
local function copy(value)
  if type(value)~="table" then return value end
  local out={}; for k,v in pairs(value) do out[k]=copy(v) end; return out
end
local function same(a,b)
  if type(a)~=type(b) then return false end
  if type(a)~="table" then return a==b end
  for k,v in pairs(a) do if not same(v,b[k]) then return false end end
  for k in pairs(b) do if a[k]==nil then return false end end
  return true
end
local function resetPages()
  pageCache={}; pageJobs={}; pageRetry={}; cacheEpoch=cacheEpoch+1; snapshot.page=nil
  snapshot.cacheEpoch=cacheEpoch
end
local function homeActive() return panelOpen and panelSection=="home" end

local function decode(raw)
  if not raw then return nil end
  local ok, value = pcall(noctalia.json.decode, raw)
  return ok and value or nil
end

local function quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function publish()
  if same(snapshot,lastPublished) then return end
  lastPublished=copy(snapshot)
  noctalia.state.set("nl.snapshot", noctalia.json.encode(snapshot))
end

local function credentials()
  local cfg = decode(noctalia.readFile("~/.local/share/Nectarlink/api-token.json"))
  if type(cfg) ~= "table" or type(cfg.token) ~= "string" or #cfg.token ~= 64
      or not cfg.token:match("^%x+$") or type(cfg.port) ~= "number"
      or cfg.port < 1 or cfg.port > 65535 or cfg.port % 1 ~= 0 then return nil end
  local binding=cfg.token..":"..tostring(cfg.port)
  if credentialBinding and credentialBinding~=binding then resetPages() end
  credentialBinding=binding
  return cfg
end

local function request(path, body, callback)
  local cfg = credentials()
  if not cfg then callback(false, 0, nil); return end
  local started = noctalia.http({
    url = "http://127.0.0.1:" .. tostring(cfg.port) .. path,
    method = body and "POST" or "GET",
    headers = { "Authorization: Bearer " .. cfg.token, "Content-Type: application/json" },
    body = body and noctalia.json.encode(body) or nil,
  }, function(res)
    callback(res.ok and res.status == 200, res.status, decode(res.body))
  end)
  if not started then callback(false, 0, nil) end
end

local function pollTimeline(warm)
  if (not homeActive() and not warm) or noctalia.getConfig("panel_timeline") == false or timelinePending then return end
  timelinePending = true; timelineStarted = ticks
  timelineGeneration = timelineGeneration + 1
  local own = timelineGeneration
  request("/v1/timeline?limit=20", nil, function(ok, _, data)
    if own ~= timelineGeneration then return end
    timelinePending = false
    snapshot.timelineState = ok and data and type(data.items) == "table" and "ready" or "offline"
    -- Publish only display fields; never paths, clipboard details or targets.
    snapshot.timeline = {}
    if snapshot.timelineState == "ready" then
      for _, item in ipairs(data.items) do
        if type(item) == "table" and type(item.deviceId) == "string" then
          table.insert(snapshot.timeline, { id = item.id, deviceId = item.deviceId,
            kind = item.kind, title = item.title, direction = item.direction })
        end
      end
    end
    publish()
  end)
end

local function pollNotifications(warm)
  if (not homeActive() and not warm) or noctalia.getConfig("panel_notifications") == false or notificationsPending then return end
  notificationsPending = true; notificationsStarted = ticks
  notificationsGeneration = notificationsGeneration + 1
  local own = notificationsGeneration
  request("/v1/notifications", nil, function(ok, status, data)
    if own ~= notificationsGeneration then return end
    notificationsPending = false
    snapshot.notificationsState = ok and data and type(data.notifications) == "table" and "ready"
      or (status == 404 and "unsupported" or "offline")
    snapshot.notifications = {}
    if snapshot.notificationsState == "ready" then
      for _, item in ipairs(data.notifications) do
        if type(item) == "table" and type(item.deviceId) == "string" and type(item.key) == "string" then
          table.insert(snapshot.notifications, { deviceId = item.deviceId, key = item.key,
            appName = item.appName, title = item.title, text = item.text })
        end
      end
    end
    publish()
  end)
end

local sessionKinds = { "pc_audio", "watch", "phone_audio", "screen", "webcam", "keyboard" }
local function pollSessions(warm)
  if (not homeActive() and not sessionRefreshing and not warm) or sessionPending then return end
  sessionPending = true; sessionStarted = ticks
  sessionGeneration = sessionGeneration + 1
  local own = sessionGeneration
  request("/v1/sessions", nil, function(ok, status, data)
    if own ~= sessionGeneration then return end
    sessionPending = false; snapshot.sessions = {}
    snapshot.sessionsState = ok and data and type(data.devices) == "table" and "ready" or (status == 404 and "unsupported" or "offline")
    if snapshot.sessionsState == "ready" then
      for _, device in ipairs(data.devices) do
        if type(device.id) == "string" then
          local view = { allowed = {} }
          for _, kind in ipairs(sessionKinds) do
            view[kind] = type(device[kind]) == "string" and device[kind] or "off"
            view.allowed[kind] = type(device.allowed) == "table" and device.allowed[kind] == true
          end
          snapshot.sessions[device.id] = view
        end
      end
    end
    if sessionRefreshing then sessionRefreshing = false; snapshot.sessionBusy = false end
    publish()
  end)
end

local function poll()
  if pending then return end
  if not credentials() then
    resetPages()
    snapshot.state = "unconfigured"; snapshot.devices = {}; snapshot.timeline = {}
    snapshot.timelineState = nil; timelineGeneration = timelineGeneration + 1
    timelinePending = false
    snapshot.notifications = {}; notificationsGeneration = notificationsGeneration + 1
    notificationsPending = false
    snapshot.sessions = {}; snapshot.sessionsState = "offline"
    sessionGeneration = sessionGeneration + 1; sessionPending = false; publish(); return
  end
  pending = true
  generation = generation + 1
  local own = generation
  request("/v1/devices", nil, function(ok, status, data)
    if own ~= generation then return end
    pending = false
    if ok and data and type(data.devices) == "table" then
      local known={}; for _,d in ipairs(data.devices) do known[d.id]=true end
      for _,d in ipairs(snapshot.devices) do if not known[d.id] then resetPages(); break end end
      snapshot.state = "ready"; snapshot.devices = data.devices
    else
      snapshot.state = status == 401 and "unauthorized" or "offline"
      if status==401 then resetPages() end
      snapshot.devices = {}
      snapshot.timeline = {}; snapshot.timelineState = "offline"
      timelineGeneration = timelineGeneration + 1; timelinePending = false
      snapshot.notifications = {}; snapshot.notificationsState = "offline"
      notificationsGeneration = notificationsGeneration + 1; notificationsPending = false
      snapshot.sessions = {}; snapshot.sessionsState = "offline"
      sessionGeneration = sessionGeneration + 1; sessionPending = false
    end
    if ringRefreshing then ringRefreshing = false; snapshot.ringBusy = false end
    publish()
  end)
end

local function onlineDevice(id)
  if snapshot.state ~= "ready" then return false end
  for _, d in ipairs(snapshot.devices) do if d.id == id and d.online then return true end end
  return false
end

local function canTransfer()
  return #snapshot.devices == 1 and onlineDevice(snapshot.devices[1].id)
end

local function launch(task)
  local executable = noctalia.getConfig("executable")
  local helper = noctalia.getConfig("helper")
  if not executable or executable=="" then executable="nectarlink-desktop" end
  if not helper or helper=="" then
    local directory=noctalia.pluginDir and noctalia.pluginDir()
    if not directory then return end
    helper=directory.."/colors.py"
  end
  -- API 52 accepts argv: paths and arguments never pass through a shell.
  local command = {"python",helper,task or "open",executable}
  noctalia.runAsync(command, function(res)
    if res.exitCode ~= 0 then noctalia.notifyError("NectarLink", "Не удалось выполнить действие") end
  end, 5000)
end

local function pageIdentity(cmd)
  local v=cmd.value; local fields={cmd.device,v.page,v.thread or "",v.album or "",tostring(v.before or ""),v.before_id or "",tostring(v.offset or 0),v.search or "",tostring(v.limit or 5)}
  for i,value in ipairs(fields) do local text=tostring(value); fields[i]=tostring(#text)..":"..text end
  return table.concat(fields)
end
local pageTTL={messages=10,calls=2,photos=60,apps=150,deck=15} -- 2-second ticks
local function cacheTime() return noctalia.nowMs and noctalia.nowMs() or ticks*2000 end
local function previewData(data)
  local out=copy(data); local valid=true
  if noctalia.fileExists then
    for _,item in ipairs(out.items or {}) do
      for _,field in ipairs({"thumbnailPath","iconPath"}) do
        if type(item[field])=="string" and not noctalia.fileExists(item[field]) then item[field]=nil; valid=false end
      end
    end
  end
  return out,valid
end
local function showPage(cmd,entry,refreshing,stale,err)
  local data=entry and previewData(entry.data) or nil
  snapshot.page={key=cmd.value.key,status=data and "ready" or (err or "loading"),data=data,refreshing=refreshing or false,stale=stale or false}
end
local function trimPages()
  local count=0; for _ in pairs(pageCache) do count=count+1 end
  if count<=24 then return end
  local oldest,stamp=nil,math.huge
  for key,e in pairs(pageCache) do if e.used<stamp then oldest=key; stamp=e.used end end
  if oldest then pageCache[oldest]=nil end
end
local function invalidateKind(device,kind)
  for key,e in pairs(pageCache) do if e.device==device and e.kind==kind then pageCache[key]=nil; pageRetry[key]=nil end end
  for key,e in pairs(pageJobs) do if e.device==device and e.kind==kind then pageJobs[key]=nil end end
end
local function readPage(cmd,quiet,force)
  if not credentials() then resetPages(); snapshot.state="unconfigured"; publish(); return end
  local v=cmd.value; local key=pageIdentity(cmd); local entry=pageCache[key]
  cacheClock=cacheClock+1; if entry then entry.used=cacheClock end
  local valid=true; if entry then local _; _,valid=previewData(entry.data) end
  local age=entry and cacheTime()-entry.at or 0
  local fresh=entry and not entry.failed and age>=0 and age<(pageTTL[v.page] or 10)*2000 and valid
  if v.page~="deck" and not onlineDevice(cmd.device) then
    showPage(cmd,entry,false,true,"failed"); publish(); return
  end
  force=force==true or (not quiet and v.force==true)
  local backendForce=force or (entry and entry.failed) or false
  if not quiet and (entry or pageJobs[key]) then showPage(cmd,entry,pageJobs[key]~=nil,entry~=nil and not fresh); publish() end
  if fresh and not force then return end
  if pageJobs[key] then return end
  if not force and pageRetry[key] and ticks<pageRetry[key] then
    if not entry then showPage(cmd,nil,false,true,"failed"); publish() end
    return
  end
  local job={epoch=cacheEpoch,started=ticks,device=cmd.device,kind=v.page}; pageJobs[key]=job
  if not quiet or not entry then showPage(cmd,entry,true,entry~=nil); publish() end
  request("/v1/page",{device=cmd.device,page=v.page,thread=v.thread,album=v.album,before=v.before,before_id=v.before_id,offset=v.offset,search=v.search,limit=v.limit,force=backendForce},function(ok,status,data)
    if pageJobs[key]~=job or job.epoch~=cacheEpoch then return end
    pageJobs[key]=nil
    if status==401 then resetPages(); snapshot.state="unauthorized"; publish(); return end
    ok=ok and type(data)=="table" and type(data.items)=="table"
    if ok then
      cacheClock=cacheClock+1
      pageCache[key]={data=data,at=cacheTime(),used=cacheClock,device=cmd.device,kind=v.page}; pageRetry[key]=nil; trimPages()
    else pageRetry[key]=ticks+15; if pageCache[key] then pageCache[key].failed=true end end
    if panelOpen and activePage and pageIdentity(activePage)==key then
      showPage(activePage,pageCache[key],false,not ok,status==404 and "unsupported" or "failed"); publish()
    end
  end)
end
noctalia.state.watch("nl.command", function(raw)
  local cmd = decode(raw)
  if type(cmd) ~= "table" then return end
  if cmd.action == "page" and type(cmd.value)=="table" then
    local v=cmd.value
    local known={messages=true,calls=true,photos=true,apps=true,deck=true}
    if not known[v.page] or type(v.key)~="string" or type(cmd.device)~="string" then return end
    -- A page command is also an explicit panel-open signal. State watchers may
    -- coalesce the earlier visible command in the same frame; never drop the read.
    panelOpen=true; panelSection=v.page; activePage=cmd; readPage(cmd,false)
  elseif cmd.action == "page_leave" then
    activePage=nil; panelSection=cmd.value=="guide" and "guide" or "home"; snapshot.page=nil; publish()
  elseif cmd.action == "page_action" and type(cmd.value)=="table" then
    if snapshot.pageActionBusy or not panelOpen then return end
    local v=cmd.value
    if v.confirm~=true or type(v.request_id)~="string" then return end
    local known={sms=true,reply=true,dial=true,photo=true,app=true,deck=true,answer=true,decline=true,silence=true}
    if not known[v.action] or (v.action~="deck" and not onlineDevice(cmd.device)) then return end
    actionGeneration=actionGeneration+1; local own=actionGeneration; actionStarted=ticks
    snapshot.pageActionBusy=true; snapshot.pageActionResult=nil; publish()
    request("/v1/page-action",{device=cmd.device,action=v.action,request_id=v.request_id,confirm=true,id=v.id,text=v.text,recipients=v.recipients},function(ok,_,data)
      if own~=actionGeneration then return end
      snapshot.pageActionBusy=false
      snapshot.pageActionResult=nil
      if not ok then noctalia.notifyError("NectarLink","Действие не подтверждено. Перед повтором проверьте телефон/ПК.") end
      local kind=({sms="messages",reply="messages",dial="calls",answer="calls",decline="calls",silence="calls"})[v.action]
      if kind then invalidateKind(cmd.device,kind) end
      publish()
      if kind and activePage and panelOpen and activePage.device==cmd.device and activePage.value.page==kind then readPage(activePage,true,true) end
    end)
  elseif cmd.action == "visible" then
    panelOpen = cmd.value == true or (type(cmd.value)=="table" and cmd.value.open==true)
    if panelOpen then panelSection=type(cmd.value)=="table" and cmd.value.page or "home" end
    poll()
    if not panelOpen then
      activePage=nil
      -- Keep a completed view so reopening this same page can draw it before
      -- the IPC cache reply. Pending/failed views must never stay stuck.
      if snapshot.page and snapshot.page.status=="ready" then snapshot.page.refreshing=false
      else snapshot.page=nil end
      publish()
    end
    if panelOpen then pollTimeline(); pollNotifications(); pollSessions() end
  elseif cmd.action == "refresh" then poll(); pollTimeline(); pollNotifications(); pollSessions()
  elseif cmd.action == "open" then launch(nil)
  elseif cmd.action == "timeline" then launch("open-timeline")
  elseif cmd.action == "files" and canTransfer() then launch("send-files")
  elseif cmd.action == "clipboard" and canTransfer() then launch("send-clipboard")
  elseif cmd.action == "session" and type(cmd.value) == "table" then
    local value = cmd.value
    local session = snapshot.sessions and snapshot.sessions[cmd.device]
    if not session or snapshot.sessionBusy or type(value.on) ~= "boolean" then return end
    local known = false
    for _, kind in ipairs(sessionKinds) do if value.kind == kind then known = true end end
    if not known or (value.on and (not onlineDevice(cmd.device) or not session.allowed[value.kind])) then return end
    sessionCommand = sessionCommand + 1; local own = sessionCommand
    sessionCommandStarted = ticks; snapshot.sessionBusy = true; publish()
    request("/v1/session", {device=cmd.device,kind=value.kind,on=value.on}, function(ok, status, data)
      if own ~= sessionCommand then return end
      sessionGeneration = sessionGeneration + 1; sessionPending = false
      sessionRefreshing = ok
      if not ok then
        snapshot.sessionBusy = false
        local messages = {another_device="Сессия занята другим телефоном",nothing_playing="Сначала включите видео на компьютере",unavailable="Функция недоступна с текущими разрешениями",
          invalid_json="Ошибка формата запроса между плагином и API",invalid_session="API не распознал тип сессии",no_device="Телефон недоступен для API",
          session_failed="Приложение не смогло запустить сессию"}
        noctalia.notifyError("NectarLink", messages[type(data)=="table" and data.error or ""] or (status==0 and "Нет связи с локальным API NectarLink" or "Не удалось изменить сессию (HTTP "..tostring(status)..")"))
      end
      publish(); pollSessions()
    end)
  elseif cmd.action == "type_text" and type(cmd.value) == "string" then
    local session = snapshot.sessions and snapshot.sessions[cmd.device]
    if snapshot.typeBusy or not onlineDevice(cmd.device) or not session or session.keyboard ~= "enabled" or #cmd.value==0 or #cmd.value>16384 then return end
    typeCommand = typeCommand + 1; local own = typeCommand
    typeStarted = ticks; snapshot.typeBusy = true; snapshot.typeDeliveryDevice = nil; publish()
    request("/v1/type",{device=cmd.device,text=cmd.value},function(ok, _, data)
      if own ~= typeCommand then return end
      snapshot.typeBusy = false
      if ok and type(data)=="table" and data.acknowledged==true then snapshot.typeSent = (snapshot.typeSent or 0) + 1; snapshot.typeSentDevice = cmd.device
      elseif ok and type(data)=="table" and data.sent==true then snapshot.typeDeliveryDevice = cmd.device
      else noctalia.notifyError("NectarLink","Отправка не подтверждена. Текст сохранён; перед повтором проверьте телефон — часть могла дойти.") end
      publish()
    end)
  elseif cmd.action == "phone_toggle" and onlineDevice(cmd.device) and type(cmd.value) == "table" then
    if snapshot.controlBusy then return end
    local value = cmd.value
    if type(value.id) ~= "string" then return end
    if value.id=="ringer" then
      if value.mode~="ring" and value.mode~="vibrate" and value.mode~="silent" then return end
      if value.on~=nil then return end
    elseif type(value.on)~="boolean" or value.mode~=nil then return end
    local allowed = false
    for _, d in ipairs(snapshot.devices) do
      if d.id == cmd.device and d.controls and d.controls.allowed then allowed = d.controls.allowed[value.id] == true end
    end
    if not allowed then return end
    controlGeneration = controlGeneration + 1
    local own = controlGeneration
    controlStarted = ticks; snapshot.controlBusy = true; publish()
    request("/v1/phone-toggle", { device = cmd.device, id = value.id, on = value.on, mode=value.mode,
      confirm_disconnect = value.confirm_disconnect == true }, function(ok)
      if own ~= controlGeneration then return end
      snapshot.controlBusy = false
      generation = generation + 1; pending = false
      if not ok then noctalia.notifyError("NectarLink", "Телефон не выполнил переключение. Проверяю состояние.") end
      publish(); poll()
    end)
  elseif cmd.action == "camera" and type(cmd.device) == "string" and onlineDevice(cmd.device) then
    if snapshot.cameraBusy then return end
    cameraGeneration = cameraGeneration + 1
    local own = cameraGeneration
    cameraStarted = ticks; snapshot.cameraBusy = true; publish()
    request("/v1/camera", { device = cmd.device, mode = "photo" }, function(ok)
      if own ~= cameraGeneration then return end
      snapshot.cameraBusy = false; publish()
      if not ok then noctalia.notifyError("NectarLink", "Не удалось запустить камеру") end
    end)
  elseif cmd.action == "ring" and type(cmd.device) == "string" and onlineDevice(cmd.device) then
    if snapshot.ringBusy then return end
    ringGeneration = ringGeneration + 1
    local own = ringGeneration
    ringStarted = ticks
    snapshot.ringBusy = true; publish()
    request("/v1/ring", { device = cmd.device, on = cmd.value == true }, function(ok)
      if own ~= ringGeneration then return end
      -- Discard polls started before this command; fetch the shared app state.
      generation = generation + 1; pending = false
      ringRefreshing = ok
      if not ok then
        snapshot.ringBusy = false
        noctalia.notifyError("NectarLink", "Телефон не принял запрос")
      end
      publish(); poll()
    end)
  end
end)

function update()
  noctalia.setUpdateInterval(2000)
  ticks = ticks + 1
  -- One small read-only warmup per connection. Never prefetch every tab or
  -- continuously poll hidden Home; the visible page always has priority.
  local ids={}
  if snapshot.state=="ready" then
    for _,d in ipairs(snapshot.devices) do if d.online then table.insert(ids,d.id) end end
  end
  table.sort(ids)
  local binding=#ids>0 and table.concat(ids,":")..":"..tostring(cacheEpoch) or nil
  if not binding then warmedHome=nil
  elseif not panelOpen and warmedHome~=binding then
    warmedHome=binding; pollTimeline(true); pollNotifications(true); pollSessions(true)
  elseif homeActive() then warmedHome=binding end
  for key,job in pairs(pageJobs) do
    if ticks-job.started>=15 then
      pageJobs[key]=nil; pageRetry[key]=ticks+15
      if pageCache[key] then pageCache[key].failed=true end
      if panelOpen and activePage and pageIdentity(activePage)==key then
        showPage(activePage,pageCache[key],false,true,"failed"); publish()
      end
    end
  end
  for key,untilTick in pairs(pageRetry) do if ticks>=untilTick then pageRetry[key]=nil end end
  if snapshot.pageActionBusy and ticks-actionStarted>=15 then
    actionGeneration=actionGeneration+1; snapshot.pageActionBusy=false
    snapshot.pageActionResult=nil
    noctalia.notifyError("NectarLink","Нет подтверждения. Перед повтором проверьте телефон/ПК; автоматического повтора нет."); publish()
  end
  if sessionPending and ticks-sessionStarted>=15 then
    sessionGeneration=sessionGeneration+1; sessionPending=false
    snapshot.sessions={}; snapshot.sessionsState="offline"; publish()
  end
  if snapshot.sessionBusy and ticks-sessionCommandStarted>=15 then
    sessionCommand=sessionCommand+1; snapshot.sessionBusy=false; sessionRefreshing=false
    sessionGeneration=sessionGeneration+1; sessionPending=false
    noctalia.notifyError("NectarLink","Нет ответа на управление сессией. Проверяю состояние.")
    publish(); pollSessions()
  end
  if snapshot.typeBusy and ticks-typeStarted>=15 then
    typeCommand=typeCommand+1; snapshot.typeBusy=false
    noctalia.notifyError("NectarLink","Нет подтверждения отправки. Текст оставлен в поле; автоматического повтора нет.")
    publish()
  end
  if snapshot.controlBusy and ticks - controlStarted >= 15 then
    controlGeneration = controlGeneration + 1; snapshot.controlBusy = false
    generation = generation + 1; pending = false
    noctalia.notifyError("NectarLink", "Нет ответа на переключение. Проверяю состояние.")
    publish(); poll()
  end
  if snapshot.cameraBusy and ticks - cameraStarted >= 15 then
    cameraGeneration = cameraGeneration + 1; snapshot.cameraBusy = false
    noctalia.notifyError("NectarLink", "Нет ответа на запрос камеры")
    publish()
  end
  if timelinePending and ticks - timelineStarted >= 15 then
    timelineGeneration = timelineGeneration + 1; timelinePending = false
    snapshot.timeline = {}; snapshot.timelineState = "offline"; publish()
  end
  if notificationsPending and ticks - notificationsStarted >= 15 then
    notificationsGeneration = notificationsGeneration + 1; notificationsPending = false
    snapshot.notifications = {}; snapshot.notificationsState = "offline"; publish()
  end
  if snapshot.ringBusy and ticks - ringStarted >= 15 then
    ringGeneration = ringGeneration + 1; ringRefreshing = false; snapshot.ringBusy = false
    generation = generation + 1; pending = false
    noctalia.notifyError("NectarLink", "Нет ответа. Проверяю состояние телефона.")
    publish(); poll()
  end
  -- A stuck callback must not wedge polling forever (30 s maximum).
  if ticks % 15 == 0 and pending then generation = generation + 1; pending = false end
  if (panelOpen and ticks%2==0) or (not panelOpen and ticks%15==1) then poll() end
  if homeActive() and ticks%5==1 then pollTimeline() end
  if homeActive() and ticks%3==1 then pollNotifications() end
  if homeActive() and ticks%2==0 then pollSessions() end
  if panelOpen and activePage and onlineDevice(activePage.device) then
    if activePage.value.page=="calls" and ticks%3==0 then readPage(activePage,true,true)
    elseif ticks%5==0 then readPage(activePage,true,false) end
  end
end

function onConfigChanged()
  -- The panel submits the new app geometry/limit after the epoch changes.
  if activePage and activePage.value.page=="apps" then activePage=nil end
  resetPages()
  generation = generation + 1; pending = false
  timelineGeneration = timelineGeneration + 1; timelinePending = false
  notificationsGeneration = notificationsGeneration + 1; notificationsPending = false
  sessionGeneration=sessionGeneration+1; sessionPending=false
  if noctalia.getConfig("panel_timeline") == false then snapshot.timeline = {}; snapshot.timelineState = nil; publish() end
  if noctalia.getConfig("panel_notifications") == false then snapshot.notifications = {}; snapshot.notificationsState = nil; publish() end
  poll(); pollTimeline(); pollNotifications(); pollSessions()
  if panelOpen and activePage then readPage(activePage,false,true) end
end
