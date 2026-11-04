--!nonstrict
local L = require("./limits.luau")
local threads = noctalia.state.get("threads") or { loading = true, data = {} }
local limits = noctalia.state.get("limits") or { accounts = {} }
local AMBER = "#F2C14E"

local function render()
  local data = threads.data or {}
  local counts = data.counts or {}
  local waiting, working = counts.waiting or 0, counts.working or 0
  local online = data.online == true and not threads.error
  local vertical = barWidget.isVertical()
  local children = { ui.image({ path = "assets/t3code.png", width = 18, height = 18, opacity = online and 1 or 0.4 }) }
  if waiting > 0 and not vertical then
    local word = noctalia.tr("widget.waiting", { count = waiting })
    if waiting == 1 then
      for _, thread in ipairs(data.threads or {}) do
        if thread.status == "approval" or thread.status == "input" then word = noctalia.tr("status." .. thread.status) break end
      end
    end
    table.insert(children, ui.row({ paddingH = 8, paddingV = 1, radius = 9, fill = AMBER, align = "center" }, {
      ui.label({ text = word, fontSize = 11, fontWeight = "bold", color = "#1F1600" }),
    }))
  elseif waiting > 0 or working > 0 then
    local color = waiting > 0 and AMBER or "primary"
    table.insert(children, ui.box({ width = 6, height = 6, radius = 3, fill = color }))
    table.insert(children, ui.label({ text = tostring(waiting > 0 and waiting or working), color = "on_surface", fontWeight = "bold" }))
  end
  local container = vertical and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))
  local summary = {}
  for _, pool in ipairs(L.collectLimitPools(limits.accounts or {}, noctalia.nowMs())) do
    for _, window in ipairs(pool.windows) do
      if window.kind == "session" then
        table.insert(summary, noctalia.tr("widget.provider_left", {
          provider = noctalia.tr("providers." .. pool.driver), percent = window.remainingPercent }))
        break
      end
    end
  end
  local tooltip = noctalia.tr("widget.counts", { waiting = waiting, working = working })
  if not online then tooltip = tooltip .. "\n" .. noctalia.tr(threads.loading and "threads.loading" or "threads.offline") end
  if #summary > 0 then tooltip = tooltip .. "\n" .. noctalia.tr("widget.limits", { summary = table.concat(summary, " · ") }) end
  if limits.error then tooltip = tooltip .. "\n" .. noctalia.tr(limits.error.key, { status = limits.error.status or 0 }) end
  barWidget.setTooltip(tooltip)
end

noctalia.state.watch("threads", function(value) threads = value render() end)
noctalia.state.watch("limits", function(value) limits = value render() end)
render()
function onClick() noctalia.togglePanel("PedroRBC/t3code-bar:panel") end
