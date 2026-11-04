--!nonstrict
local L = require("./limits.luau")
local threads = noctalia.state.get("threads") or { loading = true, data = {} }
local limits = noctalia.state.get("limits") or { loading = true, accounts = {}, updatedAt = 0 }
local activeTab, opened, hovered = "threads", false, nil
local render
local AMBER, CLAUDE = "#F2C14E", "#D97757"
local BADGES = { "#E5534B", "#4C8DFF", "#3FB950", "#B083F0", "#E3A008", "#2BB5A8", "#EC6CB9" }
local PROVIDERS = {
  codex = { key = "codex", glyph = "brand-openai" },
  claudeAgent = { key = "claude", image = "assets/claude.svg" },
  claude = { key = "claude", image = "assets/claude.svg" },
  opencode = { key = "opencode", glyph = "terminal-2" },
}
local function tr(key, values) return noctalia.tr(key, values) end
local function label(text, extra)
  local props = { text = text, fontSize = 12, color = "on_surface_variant", maxLines = 1 }
  for key, value in pairs(extra or {}) do props[key] = value end
  return ui.label(props)
end
local function requestLimits(force)
  noctalia.state.set("limits_request", { force = force, at = noctalia.nowMs() })
end
local function hover(key)
  return function(state)
    local next = hovered
    if state == true or state == "true" then next = key elseif hovered == key then next = nil end
    if next ~= hovered then hovered = next render() end
  end
end
-- "8s", "13m", "1h 39m" (precise) or "11h", "3d".
local function elapsed(stamp, precise)
  local seconds = math.floor(math.max(0, noctalia.nowMs() - (tonumber(stamp) or noctalia.nowMs())) / 1000)
  local minutes, hours = math.floor(seconds / 60), math.floor(seconds / 3600)
  if seconds < 60 then return tr("time.seconds", { seconds = seconds }) end
  if minutes < 60 then return tr("time.minutes", { minutes = minutes }) end
  if hours < 24 then
    return precise and tr("time.hours_minutes", { hours = hours, minutes = minutes % 60 }) or tr("time.hours", { hours = hours })
  end
  return tr("time.days", { days = math.floor(hours / 24) })
end
-- Two-letter project badge: first char plus first digit, next word, camel hump or next char ("in2" -> I2, "TruenasServer" -> TS).
local function monogram(name)
  local start = name:find("%w")
  if not start then return "?", BADGES[1] end
  local rest = name:sub(start + 1)
  local second = rest:match("%d") or rest:match("[^%w]+(%w)") or name:match("%l(%u)") or rest:match("%w") or ""
  local hash = 0
  for index = 1, #name do hash = (hash * 31 + name:byte(index)) % 9973 end
  return (name:sub(start, start) .. second):upper(), BADGES[hash % #BADGES + 1]
end
local function badge(name)
  local text, color = monogram(name)
  return ui.column({ width = 22, height = 18, radius = 5, fill = color .. "33", align = "center", justify = "center" }, {
    label(text, { fontSize = 9, fontWeight = "bold", color = color, fontFamily = "monospace" }),
  })
end
local function providerIcon(provider, size)
  local known = PROVIDERS[provider]
  if not known then return label(provider, { fontSize = 11 }) end
  if known.image then return ui.image({ path = known.image, width = size, height = size, fit = "contain" }) end
  return ui.glyph({ name = known.glyph, size = size, color = "on_surface_variant" })
end
local function statusParts(thread, online)
  local status = thread.status
  local live = status == "working" or status == "connecting" or status == "goal"
  if status == "approval" or status == "input" then return tr("status." .. status), nil, AMBER end
  if status == "failed" then return tr("status.failed"), nil, "error" end
  if status == "planReady" or status == "done" then return tr("status." .. status), nil, "tertiary" end
  if live and online then return tr("status." .. status), elapsed(thread.since, true), "primary" end
  return nil, elapsed(thread.since, false), "on_surface_variant"
end
local function threadRow(thread, online)
  local word, time, color = statusParts(thread, online)
  local project = type(thread.projectName) == "string" and thread.projectName or ""
  local heading = { badge(project) }
  if thread.pinned then table.insert(heading, ui.glyph({ name = "pinned", size = 13, color = "on_surface_variant" })) end
  table.insert(heading, label(project, { fontSize = 13, flexGrow = 1 }))
  if word then table.insert(heading, label(word, { fontWeight = "bold", color = color })) end
  if time then table.insert(heading, label(time, { fontFamily = "monospace", color = color, opacity = word and 0.75 or 1 })) end
  local title = { label(thread.title, { fontSize = 15, fontWeight = "semibold", color = "on_surface", flexGrow = 1 }) }
  local rows = { ui.row({ gap = 7, align = "center" }, heading), ui.row({ gap = 8, align = "center" }, title) }
  local icon = type(thread.provider) == "string" and thread.provider ~= "" and providerIcon(thread.provider, 15) or nil
  if type(thread.branch) == "string" and thread.branch ~= "" then
    local details = { label(thread.branch, { flexGrow = 1 }) }
    if icon then table.insert(details, icon) end
    table.insert(rows, ui.row({ gap = 8, align = "center" }, details))
  elseif icon then table.insert(title, icon) end
  local key = "thread:" .. thread.id
  return ui.column({ key = key, gap = 4, paddingH = 12, paddingV = 9, radius = 12,
    fill = hovered == key and "on_surface/0.08" or "on_surface/0", onHover = hover(key), onClick = function()
      local url = thread.openUrl
      if type(url) == "string" and url:match("^t3code://threads/[^/%s]+/[^/%s]+$") and not url:find("[%c]") then
        noctalia.runAsync({ "xdg-open", url })
        panel.close()
      end
    end }, rows)
end
local function notice(text, glyph, color)
  return ui.row({ gap = 8, align = "center", paddingH = 12, paddingV = 10 }, {
    ui.glyph({ name = glyph, size = 15, color = color or "on_surface_variant" }),
    label(text, { color = color or "on_surface_variant", maxLines = 4, flexGrow = 1 }),
  })
end
local function threadsView()
  local data = threads.data or {}
  local rows = {}
  if threads.loading then table.insert(rows, notice(tr("threads.loading"), "loader-2")) end
  if threads.error then table.insert(rows, notice(tr("thread_errors." .. threads.error), "alert-circle", "error")) end
  if not threads.loading and data.online == false then table.insert(rows, notice(tr("threads.offline"), "plug-connected-x")) end
  for _, thread in ipairs(data.threads or {}) do table.insert(rows, threadRow(thread, data.online == true and not threads.error)) end
  if not threads.loading and #(data.threads or {}) == 0 and not threads.error then
    table.insert(rows, notice(tr("threads.empty"), "messages"))
  end
  return ui.scroll({ key = "threads-list", flexGrow = 1, gap = 2 }, rows)
end
local function windowCard(window, color)
  local title = tr("windows." .. window.kind)
  if window.model then title = tr("windows.scoped", { model = window.model }) end
  local head = { label(title, { fontSize = 13, color = "on_surface", fontWeight = "semibold", flexGrow = 1 }) }
  if window.pace then table.insert(head, label(tr("pace." .. window.pace), {
    fontSize = 11, color = window.pace == "ahead" and "error" or "on_surface_variant" })) end
  local rows = {
    ui.row({ gap = 8, align = "center" }, head),
    ui.row({ gap = 6, align = "end" }, {
      label(tostring(window.remainingPercent) .. "%", { fontSize = 24, fontWeight = "bold", color = "on_surface" }),
      label(tr("limits.left"), { fontSize = 12 }),
    }),
  }
  local segments = {}
  for _, member in ipairs(window.columns) do
    local remaining = member.window and L.remainingPercent(member.window) or 0
    table.insert(segments, ui.column({ flexGrow = 1, gap = 4 }, {
      ui.progress({ progress = remaining / 100, height = 6, fill = color, track = "on_surface/0.1", radius = 3 }),
      label(tr(member.window and "limits.segment" or "limits.segment_missing", {
        account = member.account.initials, percent = remaining }), { fontSize = 11, fontFamily = "monospace" }),
    }))
  end
  table.insert(rows, ui.row({ gap = 6 }, segments))
  local foot = {}
  local reset = window.resets[1]
  if reset then table.insert(foot, label(L.formatResetsIn({ resetsAt = reset.at }, noctalia.nowMs(), tr), { fontSize = 11, flexGrow = 1 })) end
  if #window.columns > 1 then
    for _, refill in ipairs(window.resets) do
      if refill.restoresPercent > 0 then
        table.insert(foot, label(tr("limits.next_refill", {
          percent = refill.restoresPercent, time = noctalia.formatTime("%H:%M", refill.at / 1000) }), { fontSize = 11 }))
        break
      end
    end
  end
  if #foot > 0 then table.insert(rows, ui.row({ gap = 8, align = "center" }, foot)) end
  return ui.column({ key = window.key, gap = 8, paddingH = 14, paddingV = 12, radius = 12, fill = "on_surface/0.05" }, rows)
end
local function usageView()
  local rows = {}
  if limits.loading then table.insert(rows, notice(tr("limits.loading"), "loader-2")) end
  if limits.error then
    table.insert(rows, notice(tr(limits.error.key, { status = limits.error.status or 0 }), "alert-circle", "error"))
    if limits.error.key == "errors.configure" then
      table.insert(rows, ui.button({ text = tr("actions.settings"), glyph = "settings", onClick = function() noctalia.openSettings() end }))
    end
  end
  local pools = L.collectLimitPools(limits.accounts or {}, noctalia.nowMs())
  for _, pool in ipairs(pools) do
    local isClaude = pool.driver == "claude"
    table.insert(rows, ui.row({ gap = 8, align = "center", paddingH = 4, paddingV = 2 }, {
      providerIcon(isClaude and "claude" or pool.driver, 16),
      label(tr("providers." .. pool.driver), { fontWeight = "bold", color = "on_surface", fontSize = 14 }),
    }))
    for _, window in ipairs(pool.windows) do table.insert(rows, windowCard(window, isClaude and CLAUDE or "primary")) end
    if #pool.windows == 0 then table.insert(rows, notice(tr("limits.empty"), "gauge")) end
  end
  if #pools == 0 and not limits.loading and not limits.error then table.insert(rows, notice(tr("limits.empty"), "gauge")) end
  return ui.column({ flexGrow = 1, gap = 8 }, {
    ui.scroll({ key = "usage-list", flexGrow = 1, gap = 8 }, rows),
    ui.row({ gap = 8, align = "center", paddingH = 4 }, {
      label((limits.updatedAt or 0) > 0 and tr("limits.updated", {
        minutes = math.floor(math.max(0, noctalia.nowMs() - limits.updatedAt) / 60000) }) or tr("limits.never_updated"),
        { flexGrow = 1, fontSize = 11 }),
      ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = tr("actions.refresh"),
        enabled = not limits.refreshing, onClick = function() requestLimits(true) end }),
    }),
  })
end
local function tabs()
  local items = {}
  for _, tab in ipairs({ { id = "threads", glyph = "list-details" }, { id = "usage", glyph = "gauge" } }) do
    local selected, key = activeTab == tab.id, "tab:" .. tab.id
    local color = selected and "on_surface" or "on_surface_variant"
    table.insert(items, ui.row({ key = key, flexGrow = 1, gap = 6, align = "center", justify = "center", paddingV = 6, radius = 8,
      fill = selected and "on_surface/0.12" or (hovered == key and "on_surface/0.06" or "on_surface/0"),
      onHover = hover(key), onClick = function() activeTab, hovered = tab.id, nil render() end }, {
      ui.glyph({ name = tab.glyph, size = 14, color = color }),
      label(tr("tabs." .. tab.id), { fontSize = 12, fontWeight = selected and "semibold" or "medium", color = color }),
    }))
  end
  return ui.row({ gap = 3, padding = 3, radius = 11, fill = "on_surface/0.05" }, items)
end
render = function()
  if not opened then return end
  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 8 }, {
    tabs(), activeTab == "threads" and threadsView() or usageView(),
  }))
end
noctalia.state.watch("threads", function(value) threads = value render() end)
noctalia.state.watch("limits", function(value) limits = value render() end)
function onOpen()
  opened, activeTab, hovered = true, "threads", nil
  threads = noctalia.state.get("threads") or threads
  limits = noctalia.state.get("limits") or limits
  panel.setWantsSecondTicks(true)
  requestLimits(false)
  render()
end
function onClose() opened = false end
function update() render() end
