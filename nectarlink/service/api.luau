--!nonstrict
-- Auth and HTTP. Credentials stay in this module and request headers;
-- never publish them to UI state or pass them on a command line.
local M = {}

local function loopbackIsDirect()
  if not noctalia.getenv then return true end
  local function present(name)
    local value = noctalia.getenv(name)
    return type(value) == "string" and value ~= "" and value or nil
  end
  -- Noctalia's libcurl HTTP binding uses the process proxy environment.
  -- It doesn't yet offer a request-local bypass. Never send the bearer
  -- token through an HTTP proxy; require a known matching NO_PROXY entry.
  if not (present("http_proxy") or present("all_proxy") or present("ALL_PROXY")) then return true end
  local bypass = present("no_proxy") or present("NO_PROXY") or ""
  if bypass == "*" then return true end
  for entry in bypass:gmatch("[^,]+") do
    local host = entry:match("^[ \t]*([^ \t]*)[ \t]*$")
    if not host then break end -- libcurl stops at whitespace not followed by a comma.
    if host == "127.0.0.1" or host == "127.0.0.0/8" then return true end
  end
  return false
end

function M.new(onCredentialsChanged)
  local credentialBinding = nil
  local authEpoch = 0
  local function bindCredentials(binding, reason)
    if credentialBinding == binding then
      return
    end
    local previous = credentialBinding
    credentialBinding = binding
    authEpoch = authEpoch + 1
    -- Initial binding cancels nothing. Changing/losing known credentials
    -- invalidates ALL old responses, including devices, sessions and actions.
    if previous ~= nil then
      onCredentialsChanged(reason)
    end
  end
  local function decode(raw)
    if not raw then
      return nil
    end
    local ok, value = pcall(noctalia.json.decode, raw)
    return ok and value or nil
  end

  local function credentials()
    if not loopbackIsDirect() then
      bindCredentials(nil, "loopback_proxy")
      return nil, "loopback_proxy"
    end
    -- Do not publish OS errors: they may contain local paths.
    -- nil does not prove the app is absent: its file may be inaccessible.
    local readable, raw = pcall(noctalia.readFile, "~/.local/share/Nectarlink/api-token.json")
    if not readable or raw == nil then
      bindCredentials(nil, "credentials_missing")
      return nil, "credentials_missing"
    end
    local cfg = decode(raw)
    if
      type(cfg) ~= "table"
      or type(cfg.token) ~= "string"
      or #cfg.token ~= 64
      or not cfg.token:match("^%x+$")
      or type(cfg.port) ~= "number"
      or cfg.port < 1
      or cfg.port > 65535
      or cfg.port % 1 ~= 0
    then
      bindCredentials(nil, "credentials_invalid")
      return nil, "credentials_invalid"
    end
    local binding = cfg.token .. ":" .. tostring(cfg.port)
    bindCredentials(binding, "auth_changed")
    return cfg
  end

  -- Credentials live for one request only so rotation is observed on new reads.
  -- poll/readPage may pass freshly validated credentials to avoid reading the
  -- token file twice for a single HTTP request.
  local function request(path, body, callback, validatedCredentials)
    local initialEpoch = authEpoch
    local hadCredentials = credentialBinding ~= nil
    local cfg, credentialError = validatedCredentials, nil
    if cfg and not loopbackIsDirect() then
      bindCredentials(nil, "loopback_proxy")
      callback(false, 0, nil, "loopback_proxy")
      return
    elseif not cfg then
      cfg, credentialError = credentials()
    end
    if not cfg then
      callback(false, 0, nil, credentialError)
      return
    end
    -- A click may belong to the old connection. If rotation is discovered
    -- here, do not forward that old intent using the new credentials.
    if hadCredentials and initialEpoch ~= authEpoch then
      callback(false, 0, nil, "auth_changed")
      return
    end
    -- Supplied credentials must match the current binding. A mismatch is
    -- never a reason to retry an action using a new token.
    if cfg.token .. ":" .. tostring(cfg.port) ~= credentialBinding then
      callback(false, 0, nil, "auth_changed")
      return
    end
    local requestEpoch = authEpoch
    local completed = false
    local function finish(ok, status, data, reason)
      if completed then
        return
      end
      completed = true
      if requestEpoch ~= authEpoch then
        return
      end
      callback(ok, status, data, reason)
    end
    local encoded = body and noctalia.json.encode(body) or nil
    if path == "/v1/page" and type(encoded) == "string" and type(body.photo_ids) == "table"
      and next(body.photo_ids) == nil
    then
      -- Noctalia encodes an empty Lua table as an object, not a JSON array.
      encoded = encoded:gsub('"photo_ids"%s*:%s*{%s*}', '"photo_ids":[]', 1)
    end
    local started = noctalia.http({
      url = "http://127.0.0.1:" .. tostring(cfg.port) .. path,
      method = body and "POST" or "GET",
      headers = { "Authorization: Bearer " .. cfg.token, "Content-Type: application/json" },
      body = encoded,
      follow_redirects = false,
    }, function(res)
      if completed or requestEpoch ~= authEpoch then
        completed = true
        return
      end
      if type(res) ~= "table" then
        finish(false, 0, nil, "invalid_response")
        return
      end
      local status = type(res.status) == "number" and res.status or 0
      local data = decode(res.body)
      local ok = res.ok and status == 200 and type(data) == "table"
      local reason
      if not ok then
        reason = status == 401 and "unauthorized"
          or status == 404 and "unsupported"
          or status == 403 and "permission"
          or (status == 200 and type(data) ~= "table") and "invalid_response"
          or status == 0 and "api_unavailable"
          or "request_failed"
      end
      finish(ok, status, data, reason)
    end)
    if not started then
      finish(false, 0, nil, "api_unavailable")
    end
  end
  return { decode = decode, credentials = credentials, request = request }
end
return M
