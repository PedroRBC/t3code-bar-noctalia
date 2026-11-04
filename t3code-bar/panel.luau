--!nonstrict
local L = require("./limits.luau")
local threads = noctalia.state.get("threads") or { loading = true, data = {} }
local limits = noctalia.state.get("limits") or { loading = true, accounts = {}, updatedAt = 0 }
local activeTab, opened = "threads", false
local render
local function tr(key, values) return noctalia.tr(key, values) end
local function label(text, extra)
  local props = { text = text, fontSize = 12, color = "on_surface_variant" }
  for key, value in pairs(extra or {}) do props[key] = value end
  return ui.label(props)
end
local function requestLimits(force)
  noctalia.state.set("limits_request", { force = force, at = noctalia.nowMs() })
end
local function relative(stamp)
  local minutes = math.floor(math.max(0, noctalia.nowMs() - (tonumber(stamp) or noctalia.nowMs())) / 60000)
  if minutes >= 1440 then return tr("time.days", { days = math.floor(minutes / 1440) }) end
  if minutes >= 60 then return tr("time.hours", { hours = math.floor(minutes / 60) }) end
  return tr("time.minutes", { minutes = minutes })
end
local function threadRow(thread, online)
  local status = thread.status
  local live = status == "working" or status == "connecting" or status == "goal"
  local attention = status == "approval" or status == "input" or status == "failed"
  local word = tr("status." .. status)
  local text = live and not online and relative(thread.since) or word
  if status == "idle" then text = relative(thread.since)
  elseif live and online then text = tr("threads.status_time", { status = word, time = relative(thread.since) }) end
  local heading = {}
  if thread.pinned then table.insert(heading, ui.glyph({ name = "pin", size = 12, color = "on_surface_variant" })) end
  table.insert(heading, label(type(thread.projectName) == "string" and thread.projectName or "", { flexGrow = 1, maxLines = 1 }))
  table.insert(heading, label(text, { color = attention and "error" or (live and online and "primary" or "on_surface_variant") }))
  local rows = {
    ui.row({ gap = 5, align = "center" }, heading),
    label(thread.title, { fontSize = 14, fontWeight = "medium", color = "on_surface", maxLines = 1 }),
  }
  local details = {}
  if type(thread.branch) == "string" and thread.branch ~= "" then table.insert(details, thread.branch) end
  if type(thread.provider) == "string" and thread.provider ~= "" then
    local provider = thread.provider
    local known = { codex = "codex", claudeAgent = "claude", opencode = "opencode" }
    table.insert(details, known[provider] and tr("providers." .. known[provider]) or provider)
  end
  if #details > 0 then table.insert(rows, label(table.concat(details, " · "), { maxLines = 1, fontSize = 11 })) end
  return ui.column({ key = thread.id, gap = 4, padding = 10, radius = 8, onClick = function()
    local url = thread.openUrl
    if type(url) == "string" and url:match("^t3code://threads/[^/%s]+/[^/%s]+$") and not url:find("[%c]") then
      noctalia.runAsync({ "xdg-open", url })
      panel.close()
    end
  end }, rows)
end
local function threadsView()
  local data = threads.data or {}
  local rows = {}
  if threads.loading then table.insert(rows, label(tr("threads.loading"), { maxLines = 2 })) end
  if threads.error then table.insert(rows, label(tr("thread_errors." .. threads.error), { color = "error", maxLines = 3 })) end
  if not threads.loading and data.online == false then table.insert(rows, label(tr("threads.offline"), { maxLines = 2 })) end
  for _, thread in ipairs(data.threads or {}) do table.insert(rows, threadRow(thread, data.online == true and not threads.error)) end
  if not threads.loading and #(data.threads or {}) == 0 and not threads.error then table.insert(rows, label(tr("threads.empty"))) end
  return ui.scroll({ key = "threads-list", flexGrow = 1, gap = 3 }, rows)
end
local function windowCard(window, color)
  local title = tr("windows." .. window.kind)
  if window.model then title = tr("windows.scoped", { model = window.model }) end
  local headline = { label(tr("limits.left", { percent = window.remainingPercent }), {
    fontSize = 26, color = "on_surface", fontWeight = "bold", flexGrow = 1 }) }
  if window.pace then table.insert(headline, label(tr("pace." .. window.pace), {
    color = window.pace == "ahead" and "error" or "on_surface_variant" })) end
  local rows = { label(title, { color = "on_surface", fontWeight = "medium" }), ui.row({ align = "center", gap = 8 }, headline) }
  local segments = {}
  for _, member in ipairs(window.columns) do
    local remaining = member.window and L.remainingPercent(member.window) or 0
    table.insert(segments, ui.column({ flexGrow = 1, gap = 4 }, {
      label(tr(member.window and "limits.segment" or "limits.segment_missing", {
        account = member.account.initials, percent = remaining }), { fontSize = 11, maxLines = 1 }),
      ui.progress({ progress = remaining / 100, height = 7, fill = color, track = "on_surface/0.1", radius = 3 }),
    }))
  end
  table.insert(rows, ui.row({ gap = 5 }, segments))
  local reset = window.resets[1]
  if reset then table.insert(rows, label(L.formatResetsIn({ resetsAt = reset.at }, noctalia.nowMs(), tr))) end
  if #window.columns > 1 then
    for _, refill in ipairs(window.resets) do
      if refill.restoresPercent > 0 then
        table.insert(rows, label(tr("limits.next_refill", {
          percent = refill.restoresPercent, time = noctalia.formatTime("%H:%M", refill.at / 1000) })))
        break
      end
    end
  end
  return ui.column({ key = window.key, gap = 8, padding = 12, radius = 10, fill = "on_surface/0.04" }, rows)
end
local function usageView()
  local rows = {}
  if limits.loading then table.insert(rows, label(tr("limits.loading"))) end
  if limits.error then
    table.insert(rows, label(tr(limits.error.key, { status = limits.error.status or 0 }), { color = "error", maxLines = 4 }))
    if limits.error.key == "errors.configure" then
      table.insert(rows, ui.button({ text = tr("actions.settings"), glyph = "settings", onClick = function() noctalia.openSettings() end }))
    end
  end
  local pools = L.collectLimitPools(limits.accounts or {}, noctalia.nowMs())
  for _, pool in ipairs(pools) do
    table.insert(rows, label(tr("providers." .. pool.driver), { fontWeight = "bold", color = "on_surface", fontSize = 15 }))
    for _, window in ipairs(pool.windows) do table.insert(rows, windowCard(window, pool.driver == "codex" and "primary" or "tertiary")) end
    if #pool.windows == 0 then table.insert(rows, label(tr("limits.empty"), { maxLines = 2 })) end
  end
  if #pools == 0 and not limits.loading and not limits.error then table.insert(rows, label(tr("limits.empty"), { maxLines = 2 })) end
  return ui.column({ flexGrow = 1, gap = 10 }, {
    ui.scroll({ key = "usage-list", flexGrow = 1, gap = 12 }, rows),
    ui.row({ gap = 8, align = "center" }, {
      label((limits.updatedAt or 0) > 0 and tr("limits.updated", {
        minutes = math.floor(math.max(0, noctalia.nowMs() - limits.updatedAt) / 60000) }) or tr("limits.never_updated"),
        { flexGrow = 1, fontSize = 11 }),
      ui.button({ text = tr("actions.refresh"), glyph = "refresh", controlSize = "sm", enabled = not limits.refreshing,
        onClick = function() requestLimits(true) end }),
    }),
  })
end
render = function()
  if not opened then return end
  local tabs = {}
  for _, tab in ipairs({ "threads", "usage" }) do
    table.insert(tabs, ui.button({ key = tab, text = tr("tabs." .. tab), flexGrow = 1,
      variant = activeTab == tab and "primary" or "ghost", selected = activeTab == tab,
      onClick = function() activeTab = tab render() end }))
  end
  panel.render(ui.column({ flexGrow = 1, gap = 12, padding = 12 }, {
    ui.row({ gap = 8 }, tabs), activeTab == "threads" and threadsView() or usageView(),
  }))
end
noctalia.state.watch("threads", function(value) threads = value render() end)
noctalia.state.watch("limits", function(value) limits = value render() end)
function onOpen()
  opened, activeTab = true, "threads"
  threads = noctalia.state.get("threads") or threads
  limits = noctalia.state.get("limits") or limits
  panel.setWantsSecondTicks(true)
  requestLimits(false)
  render()
end
function onClose() opened = false end
function update() render() end
