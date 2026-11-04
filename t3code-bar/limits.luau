local M = {}
local MINUTE = 60000
local ORDER = { session = 1, weekly = 2, monthly = 3, other = 4 }

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function clamp(value) return math.max(0, math.min(100, value)) end
local function round(value) return math.floor(value + 0.5) end
local function failure(key, status) return { key = "errors." .. key, status = status } end
local function array(value)
  if type(value) ~= "table" then return false end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then return false end
    count = count + 1
  end
  return count == #value
end

function M.timestamp(value)
  if type(value) ~= "string" then return nil end
  local y, m, d, h, n, s, tail = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
  if not y then return nil end
  y, m, d, h, n, s = tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(n), tonumber(s)
  local fraction = tail:match("^(%.%d+)") or ""
  local zone = tail:sub(#fraction + 1)
  local offset = 0
  if zone ~= "Z" then
    local sign, oh, om = zone:match("^([+-])(%d%d):(%d%d)$")
    if not sign or tonumber(oh) > 23 or tonumber(om) > 59 then return nil end
    offset = (tonumber(oh) * 60 + tonumber(om)) * (sign == "+" and 1 or -1)
  end
  local leap = y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
  local monthDays = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if not monthDays[m] or d < 1 or d > monthDays[m] or h > 23 or n > 59 or s > 59 then return nil end
  -- Civil dates avoid the local timezone and DST rules in os.time().
  y = y - (m <= 2 and 1 or 0)
  local era = math.floor(y / 400)
  local year = y - era * 400
  local day = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local days = era * 146097 + year * 365 + math.floor(year / 4) - math.floor(year / 100) + day - 719468
  return ((days * 24 + h) * 60 + n - offset) * MINUTE + (s + (tonumber(fraction) or 0)) * 1000
end

function M.configError(url, key)
  if type(url) ~= "string" or url:match("^%s*$") or type(key) ~= "string" or key:match("^%s*$") then
    return failure("configure")
  end
  if url:find("[%c%s?#]") or not url:match("^https?://[^/@]+[^/]*")
    or url:match("^https?://[^/]*@") or key:find("[%c]") then return failure("hub_url") end
  return nil
end

function M.decodeResponse(response, json)
  if type(response) ~= "table" or not response.ok then return nil, failure("network") end
  local status = response.status
  if status == 401 or status == 403 then return nil, failure("management_key") end
  if not finite(status) or status < 200 or status >= 300 then return nil, failure("http", status) end
  if type(response.body) ~= "string" then return nil, failure("invalid_data") end
  local ok, data = pcall(json.decode, response.body)
  if not ok or type(data) ~= "table" then return nil, failure("invalid_data") end
  return data
end

function M.authAccounts(data)
  if type(data) ~= "table" or not array(data.files) then return nil, failure("invalid_data") end
  local accounts = {}
  for _, account in ipairs(data.files) do
    if type(account) ~= "table" then return nil, failure("invalid_data") end
    if account.disabled ~= true and (account.provider == "codex" or account.provider == "claude") then
      if type(account.id) ~= "string" or type(account.auth_index) ~= "string"
        or (account.email ~= nil and type(account.email) ~= "string")
        or (account.disabled ~= nil and type(account.disabled) ~= "boolean")
        or (account.id_token ~= nil and type(account.id_token) ~= "table") then
        return nil, failure("invalid_data")
      end
      for _, key in ipairs({ "chatgpt_account_id", "plan_type", "chatgpt_plan_type" }) do
        local value = (account.id_token or {})[key]
        if value ~= nil and type(value) ~= "string" then return nil, failure("invalid_data") end
      end
      table.insert(accounts, account)
    end
  end
  return accounts
end

function M.apiCall(account)
  local codex = account.provider == "codex"
  local header = { Authorization = "Bearer $TOKEN$" }
  if codex then
    header["Content-Type"] = "application/json"
    header["OpenAI-Beta"] = "codex-1"
    header.Originator = "Codex Desktop"
    local id = (account.id_token or {}).chatgpt_account_id
    if type(id) == "string" and id ~= "" then header["Chatgpt-Account-Id"] = id end
  else
    header["anthropic-beta"] = "oauth-2025-04-20"
    header["User-Agent"] = "claude-code/2.1.273"
  end
  return { auth_index = account.auth_index, method = "GET", header = header,
    url = codex and "https://chatgpt.com/backend-api/wham/usage" or "https://api.anthropic.com/api/oauth/usage" }
end

function M.initials(email)
  local localPart = type(email) == "string" and email:match("^([^@]+)") or ""
  local initials = ""
  for part in localPart:gmatch("[%w]+") do initials = initials .. part:sub(1, 1) end
  return initials ~= "" and initials:sub(1, 2):upper() or "?"
end

function M.normalize(account, usage, checkedAt)
  if type(usage) ~= "table" then return nil, failure("invalid_data") end
  local windows = {}
  local function add(id, kind, used, reset, minutes, model)
    if not finite(used) then error("invalid percentage") end
    table.insert(windows, { id = id, kind = kind, usedPercent = clamp(used), resetsAt = reset,
      windowDurationMins = minutes, model = model })
  end
  local ok = pcall(function()
    if account.provider == "codex" then
      local rate = usage.rate_limit
      if rate ~= nil and type(rate) ~= "table" then error("invalid rate limit") end
      local token = account.id_token or {}
      local plan = usage.plan_type or token.plan_type or token.chatgpt_plan_type
      for _, slot in ipairs({ "primary", "secondary" }) do
        local window = (rate or {})[slot .. "_window"]
        if window ~= nil then
          if type(window) ~= "table" then error("invalid window") end
          local minutes = slot == "secondary" and 10080 or ((plan == "free" or plan == "go") and 43200 or 300)
          if window.limit_window_seconds ~= nil then
            if not finite(window.limit_window_seconds) then error("invalid duration") end
            minutes = window.limit_window_seconds / 60
          end
          local reset = window.reset_at
          if reset ~= nil and not finite(reset) then error("invalid reset") end
          add(slot, minutes >= 43200 and "monthly" or (minutes >= 10080 and "weekly" or "session"),
            window.used_percent, reset and reset > 0 and reset * 1000 or nil, minutes)
        end
      end
    else
      for _, entry in ipairs({ { "five_hour", "session", 300 }, { "seven_day", "weekly", 10080 } }) do
        local window = usage[entry[1]]
        if window ~= nil then
          if type(window) ~= "table" then error("invalid window") end
          add(entry[1], entry[2], window.utilization, M.timestamp(window.resets_at), entry[3])
        end
      end
      if usage.limits ~= nil and not array(usage.limits) then error("invalid scoped limits") end
      for _, limit in ipairs(usage.limits or {}) do
        if type(limit) ~= "table" then error("invalid scoped limit") end
        local model = type(limit.scope) == "table" and limit.scope.model
        if limit.kind == "weekly_scoped" and type(model) == "table" and type(model.display_name) == "string"
          and finite(limit.percent) then
          add("seven_day_" .. model.display_name:lower():gsub("[^a-z0-9]+", "_"), "weekly", limit.percent,
            M.timestamp(limit.resets_at), 10080, model.display_name)
        end
      end
      local spend, extra = usage.spend, usage.extra_usage
      local used
      local function percentAmounts(a, b)
        if finite(a) and finite(b) and a >= 0 and b > 0 then return clamp(a / b * 100) end
        return nil
      end
      if type(spend) == "table" and spend.enabled == true and type(spend.used) == "table" and type(spend.limit) == "table"
        and type(spend.used.currency) == "string" and type(spend.limit.currency) == "string"
        and spend.used.currency:match("^%s*(.-)%s*$") == spend.limit.currency:match("^%s*(.-)%s*$")
        and finite(spend.used.exponent) and spend.used.exponent == spend.limit.exponent then
        used = percentAmounts(spend.used.amount_minor, spend.limit.amount_minor)
      end
      if used == nil and type(extra) == "table" and extra.is_enabled == true then
        used = percentAmounts(extra.used_credits, extra.monthly_limit) or extra.utilization
      end
      if finite(used) and used >= 0 then add("monthly_spend", "monthly", used) end
    end
  end)
  if not ok then return nil, failure("invalid_data") end
  table.sort(windows, function(a, b)
    return ORDER[a.kind] < ORDER[b.kind] or (a.kind == b.kind and a.id < b.id)
  end)
  return { key = account.id, driver = account.provider, initials = M.initials(account.email),
    sortName = (account.email or account.id):lower(), checkedAt = checkedAt, windows = windows }
end

function M.remainingPercent(window) return round(100 - clamp(window.usedPercent)) end
function M.elapsedShare(window, now)
  local length = (window.windowDurationMins or 0) * MINUTE
  if not window.resetsAt or length <= 0 then return nil end
  return math.max(0, math.min(1, (length - (window.resetsAt - now)) / length))
end
function M.paceOfShares(used, elapsed)
  local gap = used - elapsed * 100
  return gap > 5 and "ahead" or (gap < -5 and "under" or "on")
end

local function poolKey(driver, window)
  return driver == "codex" and window.kind or window.kind .. ":" .. window.id
end
function M.poolMember(account, reported, now)
  local spent
  if reported.kind == "session" then
    for _, window in ipairs(account.windows) do
      if window.usedPercent >= 100 and ((account.driver == "codex" and window.kind == "weekly")
        or (account.driver == "claude" and window.id == "seven_day")) then spent = window break end
    end
  end
  if not spent then return { account = account, window = reported, refillPercent = reported.usedPercent } end
  local reset, refill = nil, 0
  local cutoff = math.max(now, account.checkedAt)
  if spent.resetsAt and reported.resetsAt and spent.resetsAt > cutoff and reported.resetsAt > cutoff then
    if reported.resetsAt <= spent.resetsAt then reset, refill = spent.resetsAt, 100
    elseif reported.usedPercent >= 100 then reset, refill = reported.resetsAt, 100
    else reset, refill = spent.resetsAt, 100 - clamp(reported.usedPercent) end
  end
  return { account = account, refillPercent = refill,
    window = { id = reported.id, kind = reported.kind, usedPercent = 100, resetsAt = reset, model = reported.model } }
end

function M.collectLimitPools(accounts, now)
  local result = {}
  for _, driver in ipairs({ "codex", "claude" }) do
    local members, orderWindow = {}, nil
    for _, account in ipairs(accounts) do
      if account.driver == driver then
        table.insert(members, account)
        for _, window in ipairs(account.windows) do
          if not orderWindow or ORDER[window.kind] < ORDER[orderWindow.kind] then orderWindow = window end
        end
      end
    end
    local function orderReset(account)
      for _, window in ipairs(account.windows) do
        if orderWindow and poolKey(driver, window) == poolKey(driver, orderWindow) then
          return M.poolMember(account, window, now).window.resetsAt or math.huge
        end
      end
      return math.huge
    end
    table.sort(members, function(a, b)
      local ar, br = orderReset(a), orderReset(b)
      if ar ~= br then return ar < br end
      if a.sortName ~= b.sortName then return a.sortName < b.sortName end
      return a.key < b.key
    end)
    local windows, byKey = {}, {}
    for _, account in ipairs(members) do
      for _, reported in ipairs(account.windows) do
        local member = M.poolMember(account, reported, now)
        local key = poolKey(driver, member.window)
        for _, existing in ipairs(byKey[key] or {}) do
          if existing.account == account then key = member.window.kind .. ":" .. member.window.id break end
        end
        if not byKey[key] then byKey[key] = {} table.insert(windows, { key = key, order = #windows + 1, members = byKey[key] }) end
        table.insert(byKey[key], member)
      end
    end
    for _, pool in ipairs(windows) do
      local first = pool.members[1].window
      pool.id, pool.kind, pool.model = driver == "codex" and pool.key or first.id, first.kind, first.model
      pool.columns, pool.resets = {}, {}
      local used, timedUsed, elapsed, timed = 0, 0, 0, 0
      for _, member in ipairs(pool.members) do
        local window = member.window
        used = used + window.usedPercent
        local share = M.elapsedShare(window, now)
        if share ~= nil then timedUsed, elapsed, timed = timedUsed + window.usedPercent, elapsed + share, timed + 1 end
        if window.resetsAt then
          table.insert(pool.resets, { at = window.resetsAt, restoresPercent = round(member.refillPercent / #pool.members) })
        end
      end
      for _, account in ipairs(members) do
        local column = { account = account }
        for _, member in ipairs(pool.members) do if member.account == account then column = member break end end
        table.insert(pool.columns, column)
      end
      pool.usedPercent, pool.remainingPercent = round(used / #pool.members), round(100 - used / #pool.members)
      pool.pace = timed > 0 and M.paceOfShares(timedUsed / timed, elapsed / timed) or nil
      table.sort(pool.resets, function(a, b) return a.at < b.at end)
    end
    table.sort(windows, function(a, b)
      return ORDER[a.kind] < ORDER[b.kind] or (a.kind == b.kind and a.order < b.order)
    end)
    if #members > 0 then table.insert(result, { driver = driver, windows = windows }) end
  end
  return result
end

local function english(key, values)
  if key == "time.days_hours" then return values.days .. "d " .. values.hours .. "h" end
  if key == "time.hours_minutes" then return values.hours .. "h " .. values.minutes .. "m" end
  if key == "time.minutes" then return values.minutes .. "m" end
  if key == "limits.resets_now" then return "resets now" end
  if key == "limits.resets_momentarily" then return "Resets momentarily" end
  return "resets in " .. values.time
end
function M.formatDuration(ms, tr)
  tr = tr or english
  local minutes = math.floor(math.max(0, ms) / MINUTE)
  local days, hours = math.floor(minutes / 1440), math.floor(minutes % 1440 / 60)
  if days > 0 then return tr("time.days_hours", { days = days, hours = hours }) end
  if hours > 0 then return tr("time.hours_minutes", { hours = hours, minutes = minutes % 60 }) end
  return tr("time.minutes", { minutes = minutes % 60 })
end
function M.formatResetsIn(window, now, tr)
  tr = tr or english
  if not window.resetsAt then return nil end
  if window.resetsAt <= now then return tr("limits.resets_now") end
  if window.resetsAt - now < MINUTE then return tr("limits.resets_momentarily") end
  return tr("limits.resets_in", { time = M.formatDuration(window.resetsAt - now, tr) })
end

return M
