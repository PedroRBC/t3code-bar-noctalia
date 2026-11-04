--!nonstrict
local L = require("./limits.luau")
local threads = { loading = true, data = { online = false, counts = {}, threads = {} } }
local limits = { loading = true, updatedAt = 0, accounts = {} }
local threadsBusy, limitsBusy = false, false
local nextLimits, generation = 0, 0
local statuses = { approval = true, input = true, connecting = true, goal = true, working = true,
  failed = true, planReady = true, done = true, idle = true }

local function publishLimits()
  limits.refreshing = limitsBusy
  noctalia.state.set("limits", limits)
end
local function integer(value, fallback, lo, hi)
  return math.floor(math.max(lo, math.min(hi, tonumber(value) or fallback)))
end
local function validThreads(data)
  if type(data) ~= "table" or data.ok ~= true or type(data.online) ~= "boolean"
    or type(data.threads) ~= "table" or type(data.counts) ~= "table" then return false end
  for _, key in ipairs({ "waiting", "working" }) do
    if type(data.counts[key]) ~= "number" or data.counts[key] < 0 then return false end
  end
  for _, thread in ipairs(data.threads) do
    if type(thread) ~= "table" or type(thread.id) ~= "string" or type(thread.title) ~= "string"
      or not statuses[thread.status] then return false end
  end
  return true
end
local function pollThreads()
  if threadsBusy then return end
  threadsBusy = true
  local accepted = noctalia.runAsync({ "python3", noctalia.pluginDir() .. "/scripts/t3bar.py", "threads", "--latest",
    tostring(integer(noctalia.getConfig("latest_count"), 10, 0, 50)) }, function(result)
    threadsBusy = false
    threads.loading = false
    local data
    if result.exitCode == 0 and not result.timedOut and not result.stdoutTruncated then
      local ok, value = pcall(noctalia.json.decode, result.stdout)
      if ok then data = value end
    end
    if validThreads(data) then threads.data, threads.error = data, nil
    else
      local code = type(data) == "table" and data.error or "unavailable"
      local known = { missing = true, unavailable = true, incompatibleSchema = true, busy = true, invalidData = true }
      threads.error = known[code] and code or "invalidData"
    end
    noctalia.state.set("threads", threads)
  end, 5000)
  if not accepted then
    threadsBusy = false
    threads.loading, threads.error = false, "unavailable"
    noctalia.state.set("threads", threads)
  end
end

local function refreshLimits()
  if limitsBusy then return end
  local url = noctalia.getConfig("hub_url") or ""
  local key = noctalia.getConfig("management_key") or ""
  nextLimits = noctalia.nowMs() + integer(noctalia.getConfig("limits_refresh_minutes"), 5, 1, 60) * 60000
  local configError = L.configError(url, key)
  if configError then
    limits.loading, limits.error = false, configError
    publishLimits()
    return
  end
  url = url:gsub("/+$", "")
  limitsBusy = true
  publishLimits()
  local epoch = generation
  local function finish(accounts, err)
    limitsBusy = false
    limits.loading, limits.error = false, err
    if accounts then limits.accounts, limits.updatedAt = accounts, noctalia.nowMs() end
    publishLimits()
  end
  local function request(path, body, callback)
    local encoded
    if body then
      encoded = noctalia.json.encode(body)
      if not encoded then finish(nil, { key = "errors.invalid_data" }) return end
    end
    local accepted = noctalia.http({ url = url .. "/v0/management/" .. path,
      method = body and "POST" or "GET", body = encoded,
      headers = { "Authorization: Bearer " .. key, "Content-Type: application/json" },
      follow_redirects = false }, function(response)
      if epoch ~= generation then limitsBusy = false return end
      local data, err = L.decodeResponse(response, noctalia.json)
      callback(data, err)
    end)
    if not accepted then callback(nil, { key = "errors.network" }) end
  end
  request("auth-files", nil, function(data, err)
    if err then finish(nil, err) return end
    local accounts, accountError = L.authAccounts(data)
    if not accounts then finish(nil, accountError) return end
    local normalized, firstError = {}, nil
    local checkedAt = noctalia.nowMs()
    local readAccount
    readAccount = function(index)
      local account = accounts[index]
      -- Like T3, a failed account drops out of the pools; keep the last good data only if all failed.
      if not account then finish((#normalized > 0 or not firstError) and normalized or nil, firstError) return end
      request("api-call", L.apiCall(account), function(envelope, err)
        local usage, normalizedAccount
        if not err then
          usage, err = L.decodeResponse({ ok = true, status = envelope.status_code, body = envelope.body }, noctalia.json)
        end
        if not err then normalizedAccount, err = L.normalize(account, usage, checkedAt) end
        if normalizedAccount then table.insert(normalized, normalizedAccount) else firstError = firstError or err end
        readAccount(index + 1)
      end)
    end
    readAccount(1)
  end)
end

noctalia.state.watch("limits_request", function(request)
  if type(request) ~= "table" then return end
  if request.force == true or noctalia.nowMs() - limits.updatedAt > 60000 then refreshLimits() end
end)

function update()
  pollThreads()
  if noctalia.nowMs() >= nextLimits then refreshLimits() end
end
function onConfigChanged()
  generation = generation + 1
  limits = { loading = true, updatedAt = 0, accounts = {} }
  nextLimits = 0
  publishLimits()
  refreshLimits()
end

noctalia.setUpdateInterval(2000)
noctalia.state.set("threads", threads)
publishLimits()
update()
