--!nonstrict
local L = require("./limits.luau")
local threads = noctalia.state.get("threads") or { loading = true, data = {} }
local limits = noctalia.state.get("limits") or { loading = true, accounts = {}, updatedAt = 0 }
local activeTab, opened, hovered = "threads", false, nil
local render
-- Amber means "needs you" everywhere (bar pill and rows); dark text keeps it readable on light themes too.
local AMBER, ON_AMBER, CLAUDE = "#F2C14E", "#1F1600", "#D97757"
local PROVIDERS = {
  codex = { glyph = "brand-openai" },
  claudeAgent = { image = "assets/claude.svg" },
  claude = { image = "assets/claude.svg" },
  opencode = { glyph = "terminal-2" },
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
local function providerIcon(provider, size, color)
  local known = PROVIDERS[provider]
  if not known then return nil end
  if known.image then return ui.image({ path = known.image, width = size, height = size, fit = "contain" }) end
  return ui.glyph({ name = known.glyph, size = size, color = color or "on_surface_variant" })
end
local function pill(text)
  return ui.row({ paddingH = 7, paddingV = 0, radius = 9, fill = AMBER, align = "center" }, {
    label(text, { fontSize = 11, fontWeight = "bold", color = ON_AMBER }),
  })
end
-- Waiting: amber pill. Live run: primary. Failed: error. Plan ready/Done: plain text. Idle: time only.
local function statusBadge(status, online)
  local word = tr("status." .. status)
  if status == "approval" or status == "input" then return pill(word) end
  if status == "failed" then return label(word, { fontWeight = "semibold", color = "error" }) end
  if status == "planReady" or status == "done" then return label(word, { fontWeight = "medium", color = "on_surface" }) end
  if online and (status == "working" or status == "connecting" or status == "goal") then
    return label(word, { fontWeight = "semibold", color = "primary" })
  end
  return nil
end
local function threadRow(thread, online)
  local status = thread.status
  local live = online and (status == "working" or status == "connecting" or status == "goal")
  -- Line 1 is the title alone; line 2 is where it runs (left) and its state (right).
  local top = { label(thread.title, { fontSize = 14, fontWeight = "semibold", color = "on_surface", flexGrow = 1 }) }
  if thread.pinned then table.insert(top, ui.glyph({ name = "pinned", size = 13, color = "on_surface_variant" })) end
  local meta = {}
  -- An empty slot keeps project names aligned when the provider is unknown.
  table.insert(meta, type(thread.provider) == "string" and providerIcon(thread.provider, 13, thread.provider == "codex" and "primary" or nil)
    or ui.box({ width = 13, height = 13, fill = "on_surface/0" }))
  local place = {}
  if type(thread.projectName) == "string" and thread.projectName ~= "" then table.insert(place, thread.projectName) end
  if type(thread.branch) == "string" and thread.branch ~= "" then table.insert(place, thread.branch) end
  table.insert(meta, label(table.concat(place, " · "), { flexGrow = 1 }))
  local badge = statusBadge(status, online)
  if badge then table.insert(meta, badge) end
  table.insert(meta, label(elapsed(thread.since, live), { fontFamily = "monospace", fontSize = 11,
    color = live and "primary" or "on_surface_variant" }))
  local key = "thread:" .. thread.id
  return ui.column({ key = key, gap = 3, paddingH = 12, paddingV = 8, radius = 10,
    fill = hovered == key and "on_surface/0.07" or "on_surface/0", onHover = hover(key), onClick = function()
      local url = thread.openUrl
      if type(url) == "string" and url:match("^t3code://threads/[^/%s]+/[^/%s]+$") and not url:find("[%c]") then
        noctalia.runAsync({ "xdg-open", url })
        panel.close()
      end
    end }, {
    ui.row({ gap = 8, align = "center" }, top),
    ui.row({ gap = 6, align = "center" }, meta),
  })
end
local function notice(text, glyph, color)
  return ui.row({ gap = 8, align = "center", paddingH = 12, paddingV = 8, radius = 10, fill = "on_surface/0.05" }, {
    ui.glyph({ name = glyph, size = 14, color = color or "on_surface_variant" }),
    label(text, { color = color or "on_surface_variant", maxLines = 4, flexGrow = 1 }),
  })
end
-- Centered state for an empty or unconfigured tab: glyph, title, hint, optional action.
local function emptyState(glyph, title, hint, action)
  local children = {
    ui.glyph({ name = glyph, size = 26, color = "on_surface_variant" }),
    ui.box({ height = 8, fill = "on_surface/0" }),
    label(title, { fontSize = 14, fontWeight = "semibold", color = "on_surface", textAlign = "center" }),
    label(hint, { textAlign = "center", maxLines = 3 }),
  }
  if action then table.insert(children, ui.box({ height = 12, fill = "on_surface/0" })) table.insert(children, action) end
  return ui.column({ flexGrow = 1, gap = 4, align = "center", justify = "center", paddingH = 28 }, children)
end
local function threadsView()
  local data = threads.data or {}
  local online = data.online == true and not threads.error
  local rows = {}
  if threads.loading then table.insert(rows, notice(tr("threads.loading"), "loader-2")) end
  if threads.error then table.insert(rows, notice(tr("thread_errors." .. threads.error), "alert-circle", "error")) end
  if not threads.loading and data.online == false then table.insert(rows, notice(tr("threads.offline"), "plug-connected-x")) end
  if not threads.loading and not threads.error and #(data.threads or {}) == 0 then
    table.insert(rows, emptyState("messages", tr("threads.empty"), tr("threads.empty_hint")))
    return ui.column({ key = "threads-list", flexGrow = 1, gap = 2 }, rows)
  end
  for _, thread in ipairs(data.threads or {}) do table.insert(rows, threadRow(thread, online)) end
  return ui.scroll({ key = "threads-list", flexGrow = 1, gap = 2 }, rows)
end
-- When usage comes back: the soonest reset and, for pools, the next refill; one line when they coincide.
local function resetLines(window, now)
  local first, refill, lines = window.resets[1], nil, {}
  if not first then return lines end
  if #window.columns > 1 then
    for _, reset in ipairs(window.resets) do
      if reset.restoresPercent > 0 then refill = reset break end
    end
  end
  if not refill or refill.at ~= first.at then table.insert(lines, L.formatResetsIn({ resetsAt = first.at }, now, tr)) end
  if refill then
    table.insert(lines, refill.at - now < 60000 and tr("limits.refill_now", { percent = refill.restoresPercent })
      or tr("limits.refill_in", { percent = refill.restoresPercent, time = L.formatDuration(refill.at - now, tr) }))
  end
  return lines
end
local function windowCard(window, color)
  local now = noctalia.nowMs()
  local title = window.model and tr("windows.scoped", { model = window.model }) or tr("windows." .. window.kind)
  local head = { label(title, { fontWeight = "semibold", color = "on_surface", flexGrow = 1 }) }
  if window.pace then table.insert(head, label(tr("pace." .. window.pace), {
    fontSize = 11, color = window.pace == "ahead" and "error" or "on_surface_variant" })) end
  -- No baseline alignment in the toolkit: lift the small labels off the big figure's descent.
  local function onBaseline(node, grow) return ui.column({ flexGrow = grow }, { node, ui.box({ height = 3, fill = "on_surface/0" }) }) end
  local figure = {
    label(tostring(window.remainingPercent) .. "%", { fontSize = 22, fontWeight = "bold", color = "on_surface" }),
    onBaseline(label(tr("limits.left")), 1),
  }
  local resets = {}
  for _, line in ipairs(resetLines(window, now)) do table.insert(resets, label(line, { fontSize = 11 })) end
  if #resets > 0 then table.insert(figure, onBaseline(ui.column({ gap = 2, align = "end" }, resets))) end
  local bars, names = {}, {}
  for _, member in ipairs(window.columns) do
    local remaining = member.window and L.remainingPercent(member.window) or 0
    table.insert(bars, ui.progress({ flexGrow = 1, progress = remaining / 100, height = 6, fill = color,
      track = "on_surface/0.1", radius = 3 }))
    table.insert(names, label(tr(member.window and "limits.segment" or "limits.segment_missing", {
      account = member.account.initials, percent = remaining }), { flexGrow = 1, fontSize = 11 }))
  end
  local rows = {
    ui.row({ gap = 8, align = "center" }, head),
    ui.row({ gap = 6, align = "end" }, figure),
    ui.row({ gap = 6 }, bars),
  }
  -- Account labels only help tell segments apart; one account's number is the big figure.
  if #window.columns > 1 then table.insert(rows, ui.row({ gap = 6 }, names)) end
  return ui.column({ key = window.key, gap = 6, paddingH = 12, paddingV = 11, radius = 12, fill = "on_surface/0.05" }, rows)
end
local function usageView()
  local configure = limits.error and limits.error.key == "errors.configure"
  if configure then
    return emptyState("plug-connected", tr("errors.configure"), tr("limits.configure_hint"),
      ui.button({ text = tr("actions.settings"), glyph = "settings", controlSize = "sm", onClick = function() noctalia.openSettings() end }))
  end
  local rows = {}
  if limits.loading then table.insert(rows, notice(tr("limits.loading"), "loader-2")) end
  if limits.error then
    table.insert(rows, notice(tr(limits.error.key, { status = limits.error.status or 0 }), "alert-circle", "error"))
  end
  local pools = L.collectLimitPools(limits.accounts or {}, noctalia.nowMs())
  for index, pool in ipairs(pools) do
    local isClaude = pool.driver == "claude"
    -- Extra room above later sections so each heading groups with the cards below it.
    if index > 1 then table.insert(rows, ui.box({ height = 8, fill = "on_surface/0" })) end
    local header = {
      providerIcon(isClaude and "claude" or pool.driver, 15),
      label(tr("providers." .. pool.driver), { fontWeight = "bold", color = "on_surface", fontSize = 14, flexGrow = 1 }),
    }
    local count = pool.windows[1] and #pool.windows[1].columns or 0
    if count > 1 then table.insert(header, label(tr("limits.accounts", { count = count }), { fontSize = 11 })) end
    table.insert(rows, ui.row({ gap = 8, align = "center", paddingH = 12, paddingV = 2 }, header))
    for _, window in ipairs(pool.windows) do table.insert(rows, windowCard(window, isClaude and CLAUDE or "primary")) end
    if #pool.windows == 0 then table.insert(rows, notice(tr("limits.empty"), "gauge")) end
  end
  if #pools == 0 and not limits.loading and not limits.error then table.insert(rows, notice(tr("limits.empty"), "gauge")) end
  local minutes = math.floor(math.max(0, noctalia.nowMs() - (limits.updatedAt or 0)) / 60000)
  local updated = (limits.updatedAt or 0) <= 0 and tr("limits.never_updated")
    or (minutes < 1 and tr("limits.updated_now") or tr("limits.updated", { minutes = minutes }))
  return ui.column({ flexGrow = 1, gap = 6 }, {
    ui.scroll({ key = "usage-list", flexGrow = 1, gap = 8 }, rows),
    -- 15 = the 12px content inset plus the scroll view's own ~3px inset (measured).
    ui.row({ gap = 8, align = "center", paddingH = 15 }, {
      label(updated, { flexGrow = 1, fontSize = 11 }),
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
      label(tr("tabs." .. tab.id), { fontWeight = selected and "semibold" or "medium", color = color }),
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
