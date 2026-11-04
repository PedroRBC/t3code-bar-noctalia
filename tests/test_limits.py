"""Synthetic T3 limit fixtures and native API stubs; no desktop or network access."""
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "t3code-bar"


def lua(value):
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "{" + ",".join(map(lua, value)) + "}"
    return "{" + ",".join(f"[{lua(k)}]={lua(v)}" for k, v in value.items()) + "}"


FIXTURE = r'''
local now = L.timestamp("2026-11-04T14:20:00Z")
local HOUR, DAY = 3600000, 86400000
local function codex(id, email, session, weekly, reset)
  return assert(L.normalize({id=id, auth_index=id, email=email, provider="codex"}, {
    rate_limit={primary_window={used_percent=session, reset_at=(now+reset)/1000, limit_window_seconds=18000},
      secondary_window={used_percent=weekly, reset_at=(now+2*DAY)/1000, limit_window_seconds=604800}}}, now))
end
local a = codex("a", "alex.alpha@example.test", 5, 60, 3*HOUR+41*60000)
local b = codex("b", "blair.beta@example.test", 15, 100, HOUR)
local c = assert(L.normalize({id="c", email="casey.charlie@example.test", provider="claude"}, {
  five_hour={utilization=17, resets_at="2026-11-04T18:01:00Z"},
  seven_day={utilization=65, resets_at="2026-11-06T14:20:00Z"}}, now))
'''

SERVICE = r'''
local clock = now
local config = {hub_url="https://hub.example.test/", management_key="fake-management-key",
  latest_count=10, limits_refresh_minutes=5}
local states, watches, httpCalls, runCalls = {}, {}, {}, {}
local decoded = {}
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for k,v in pairs(value) do result[k]=copy(v) end
  return result
end
local function noKey(value)
  if type(value) == "string" then assert(not value:find(config.management_key,1,true))
  elseif type(value) == "table" then for _,v in pairs(value) do noKey(v) end end
end
noctalia = {
  getConfig=function(key) return config[key] end,
  pluginDir=function() return "/plugin" end,
  nowMs=function() return clock end,
  setUpdateInterval=function(ms) assert(ms==2000) end,
  state={get=function(key) return states[key] end,
    set=function(key,value) noKey(value) states[key]=copy(value) end,
    watch=function(key,cb) watches[key]=cb end},
  json={decode=function(body) return decoded[body] end,
    encode=function(value) noKey(value) return "encoded" end},
  http=function(request,cb) table.insert(httpCalls,{request=request,cb=cb}) return true end,
  runAsync=function(argv,cb,timeout) noKey(argv) table.insert(runCalls,{argv=argv,cb=cb}) return true end,
}
local require=function() return L end
local function respond(index, body, value, status)
  decoded[body]=value
  httpCalls[index].cb({ok=true,status=status or 200,body=body})
end
'''


class LimitsTests(unittest.TestCase):
    def run_case(self, case, harness=""):
        source = f"local L = dofile({lua(str(PLUGIN / 'limits.luau'))})\n" + FIXTURE + harness + case
        result = subprocess.run(["/usr/bin/lua", "-"], input=source, cwd=ROOT,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_reference_codex_48_20_and_claude_83_35(self):
        self.run_case('''
local pools=L.collectLimitPools({c,b,a},now)
assert(pools[1].driver=="codex" and pools[2].driver=="claude")
assert(pools[1].windows[1].remainingPercent==48)
assert(pools[1].windows[2].remainingPercent==20)
assert(pools[2].windows[1].remainingPercent==83)
assert(pools[2].windows[2].remainingPercent==35)
assert(pools[1].windows[1].columns[1].account.initials=="AA")
assert(pools[1].windows[1].columns[2].window.usedPercent==100)
assert(b.windows[1].usedPercent==15) -- Pooling must not mutate reported data.
''')

    def test_pace_thresholds_and_unclocked_blocked_account(self):
        self.run_case('''
assert(L.paceOfShares(56,0.5)=="ahead")
assert(L.paceOfShares(55,0.5)=="on")
assert(L.paceOfShares(45,0.5)=="on")
assert(L.paceOfShares(44,0.5)=="under")
assert(L.elapsedShare({resetsAt=now+HOUR,windowDurationMins=120},now)==0.5)
assert(L.elapsedShare({resetsAt=now-1,windowDurationMins=120},now)==1)
assert(L.elapsedShare({resetsAt=now+3*HOUR,windowDurationMins=120},now)==0)
assert(L.elapsedShare({resetsAt=now},now)==nil)
local pool=L.collectLimitPools({a,b},now)[1].windows[1]
assert(pool.pace=="under") -- Suppressed B has no session pace clock.
''')

    def test_duration_and_resets_in_text(self):
        self.run_case('''
assert(L.formatDuration(3*HOUR+41*60000)=="3h 41m")
assert(L.formatDuration(DAY+2*HOUR+60000)=="1d 2h")
assert(L.formatDuration(-1)=="0m")
assert(L.formatResetsIn({resetsAt=now},now)=="resets now")
assert(L.formatResetsIn({resetsAt=now+59999},now)=="Resets momentarily")
assert(L.formatResetsIn({resetsAt=now+3*HOUR+41*60000},now)=="resets in 3h 41m")
assert(L.formatResetsIn({},now)==nil)
''')

    def test_next_refill_two_accounts_and_account_order(self):
        self.run_case('''
local window=L.collectLimitPools({b,a},now)[1].windows[1]
assert(#window.columns==2 and #window.resets==2)
assert(window.resets[1].at==now+3*HOUR+41*60000)
assert(window.resets[1].restoresPercent==3) -- Math.round(5 / 2).
assert(window.resets[2].at==now+2*DAY and window.resets[2].restoresPercent==50)
''')

    def test_weekly_blocking_reset_branches_and_stale_clocks(self):
        self.run_case('''
b.windows[1].resetsAt=now+3*DAY
local member=L.poolMember(b,b.windows[1],now)
assert(member.window.resetsAt==now+2*DAY and member.refillPercent==85)
b.windows[1].usedPercent=100
member=L.poolMember(b,b.windows[1],now)
assert(member.window.resetsAt==now+3*DAY and member.refillPercent==100)
b.windows[1].resetsAt=now
member=L.poolMember(b,b.windows[1],now)
assert(member.window.usedPercent==100 and member.window.resetsAt==nil and member.refillPercent==0)
c.windows[2].usedPercent=100
assert(L.poolMember(c,c.windows[1],now).window.usedPercent==100)
c.windows[2].id="seven_day_opus"
assert(L.poolMember(c,c.windows[1],now).window.usedPercent==17)
''')

    def test_codex_duration_fallback_pool_keys_and_clamping(self):
        self.run_case('''
local free=assert(L.normalize({id="free",provider="codex",id_token={plan_type="free"}},
  {rate_limit={primary_window={used_percent=-5}}},now))
assert(free.windows[1].kind=="monthly" and free.windows[1].windowDurationMins==43200)
assert(L.remainingPercent(free.windows[1])==100)
local reversed=assert(L.normalize({id="reverse",provider="codex"}, {rate_limit={
  primary_window={used_percent=200,limit_window_seconds=604800},
  secondary_window={used_percent=10,limit_window_seconds=18000}}},now))
assert(reversed.windows[1].id=="secondary" and reversed.windows[2].usedPercent==100)
local pools=L.collectLimitPools({a,reversed},now)
assert(#pools[1].windows==2 and #pools[1].windows[1].members==2)
local duplicate=assert(L.normalize({id="duplicate",provider="codex"},{rate_limit={
  primary_window={used_percent=20,limit_window_seconds=18000},
  secondary_window={used_percent=30,limit_window_seconds=18000}}},now))
assert(#L.collectLimitPools({duplicate},now)[1].windows==2)
''')

    def test_claude_scoped_and_monthly_spend(self):
        self.run_case('''
local account=assert(L.normalize({id="claude",provider="claude"}, {
  limits={{kind="weekly_scoped",percent=33,scope={model={display_name="Opus 4.5"}},resets_at="2026-11-06T14:20:00Z"}},
  spend={enabled=true,used={currency="USD",exponent=2,amount_minor=250},
    limit={currency="USD",exponent=2,amount_minor=1000}},
  extra_usage={is_enabled=true,utilization=99}},now))
assert(account.windows[1].id=="seven_day_opus_4_5" and account.windows[1].usedPercent==33)
assert(account.windows[2].id=="monthly_spend" and account.windows[2].usedPercent==25)
local extra=assert(L.normalize({id="extra",provider="claude"}, {
  extra_usage={is_enabled=true,used_credits=40,monthly_limit=100,utilization=99}},now))
assert(extra.windows[1].usedPercent==40)
''')

    def test_http_401_empty_config_and_malformed_data(self):
        self.run_case('''
local json={decode=function() error("must not decode error body containing fake-secret") end}
for _,status in ipairs({401,403}) do
  local value,err=L.decodeResponse({ok=true,status=status,body="fake-secret"},json)
  assert(value==nil and err.key=="errors.management_key" and err.body==nil)
end
assert(L.configError("","fake-key").key=="errors.configure")
assert(L.configError("https://hub.example.test","").key=="errors.configure")
assert(L.configError("https://user:pass@hub.example.test","fake-key").key=="errors.hub_url")
assert(L.configError("https://hub.example.test","fake-key\\r\\n").key=="errors.hub_url")
assert(#L.collectLimitPools({},now)==0)
local value,err=L.normalize({id="bad",provider="codex"},{rate_limit={primary_window={used_percent="5"}}},now)
assert(value==nil and err.key=="errors.invalid_data")
assert(L.authAccounts({})==nil)
assert(L.authAccounts({files={unexpected=true}})==nil)
assert(L.authAccounts({files={[2]={id="a",auth_index="1",provider="codex"}}})==nil)
assert(L.authAccounts({files={{id="a",provider="codex"}}})==nil)
local accounts=assert(L.authAccounts({files={{id="a",auth_index="1",provider="codex"},
 {id="b",auth_index="2",provider="claude",disabled=true},{provider="other"}}}))
assert(#accounts==1)
''')

    def test_hub_api_call_contract(self):
        self.run_case('''
local request=L.apiCall({provider="codex",auth_index="a",id_token={chatgpt_account_id="workspace"}})
assert(request.auth_index=="a" and request.method=="GET")
assert(request.url=="https://chatgpt.com/backend-api/wham/usage")
assert(request.header.Authorization=="Bearer $TOKEN$")
assert(request.header["Chatgpt-Account-Id"]=="workspace")
assert(request.header["Content-Type"]=="application/json" and request.header["OpenAI-Beta"]=="codex-1")
assert(request.header.Originator=="Codex Desktop")
request=L.apiCall({provider="claude",auth_index="b"})
assert(request.url=="https://api.anthropic.com/api/oauth/usage")
assert(request.header["anthropic-beta"]=="oauth-2025-04-20")
assert(request.header["User-Agent"]=="claude-code/2.1.273")
''')

    def test_iso_dates_are_timezone_independent(self):
        self.run_case('''
assert(L.timestamp("1970-01-01T00:00:00Z")==0)
assert(L.timestamp("2026-11-04T11:20:00-03:00")==now)
assert(L.timestamp("2026-11-04T16:20:00+02:00")==now)
assert(L.timestamp("2026-11-04T14:20:00.123Z")==now+123)
assert(L.timestamp("2024-02-29T00:00:00Z")~=nil)
assert(L.timestamp("2026-02-29T00:00:00Z")==nil)
assert(L.timestamp("invalid")==nil)
''')

    def service_case(self, case, before=""):
        source = (PLUGIN / "service.luau").read_text()
        self.run_case(before + "\n" + source + "\n" + case, SERVICE)

    def test_service_skip_overlap_keep_data_and_key_only_in_header(self):
        self.service_case('''
assert(#httpCalls==1 and #runCalls==1)
assert(httpCalls[1].request.url=="https://hub.example.test/v0/management/auth-files")
assert(httpCalls[1].request.headers[1]=="Authorization: Bearer fake-management-key")
assert(httpCalls[1].request.follow_redirects==false)
assert(runCalls[1].argv[2]=="/plugin/scripts/t3bar.py" and runCalls[1].argv[5]=="10")
update() watches.limits_request({force=true})
assert(#httpCalls==1 and #runCalls==1)
decoded.good={ok=true,online=true,counts={waiting=1,working=2},threads={}}
runCalls[1].cb({exitCode=0,stdout="good"})
respond(1,"accounts",{files={{id="a",auth_index="1",provider="codex"}}})
assert(#httpCalls==2 and httpCalls[2].request.method=="POST")
decoded.usage={rate_limit={primary_window={used_percent=5}}}
respond(2,"envelope",{status_code=200,body="usage"})
assert(states.limits.updatedAt==clock and #states.limits.accounts==1)
clock=clock+59000
watches.limits_request({force=false}) assert(#httpCalls==2)
clock=clock+2000
watches.limits_request({force=false}) assert(#httpCalls==3)
respond(3,"secret-bearing-error",{},401)
assert(states.limits.error.key=="errors.management_key" and #states.limits.accounts==1)
update()
runCalls[2].cb({exitCode=1,stdout="bad"})
assert(states.threads.data.counts.waiting==1 and states.threads.error=="unavailable")
''')

    def test_service_show_settled_threads_preserves_latest_count(self):
        self.service_case('''
assert(runCalls[1].argv[5]=="7" and #runCalls[1].argv==5) -- Missing setting keeps existing behavior.
runCalls[1].cb({exitCode=1})
config.show_settled_threads=false
onConfigChanged()
update()
assert(runCalls[2].argv[5]=="7" and runCalls[2].argv[6]=="--hide-settled" and config.latest_count==7)
runCalls[2].cb({exitCode=1})
config.show_settled_threads=true
onConfigChanged()
update()
assert(runCalls[3].argv[5]=="7" and #runCalls[3].argv==5)
''', 'config.latest_count=7')

    def test_service_failed_account_drops_out_but_others_stay(self):
        self.service_case('''
respond(1,"accounts",{files={{id="a",auth_index="1",provider="codex"},{id="b",auth_index="2",provider="claude"}}})
decoded.usage={rate_limit={primary_window={used_percent=5}}}
respond(2,"envelope",{status_code=200,body="usage"})
respond(3,"envelope",{status_code=429,body="busy"})
assert(#states.limits.accounts==1 and states.limits.accounts[1].key=="a")
assert(states.limits.error.key=="errors.http" and states.limits.updatedAt==clock)
''')

    def test_service_empty_config_never_requests_hub(self):
        self.service_case('''
assert(#httpCalls==0 and states.limits.error.key=="errors.configure")
''', 'config.hub_url=""')

    def test_service_config_change_discards_old_response_and_refreshes(self):
        self.service_case('''
config.hub_url="https://new-hub.example.test"
onConfigChanged()
respond(1,"old",{files={}})
assert(states.limits.updatedAt==0)
update()
assert(#httpCalls==2 and httpCalls[2].request.url:find("new%-hub"))
respond(2,"new",{files={}})
assert(states.limits.updatedAt==clock and not states.limits.refreshing)
clock=clock+5*60000
update()
assert(#httpCalls==3)
''')

    def ui_case(self, filename, case, before=""):
        translations = lua(json.loads((PLUGIN / "translations/en.json").read_text()))
        harness = "local translations=" + translations + r'''
local tree, tooltip, closed, request, launched, settings
local watches = {}
local threadData={loading=false,data={online=true,counts={waiting=1,working=2},threads={
  {id="pin",title="Pinned fixture",projectName="Project A",status="idle",pinned=true,lastActivityAt=now-2*HOUR,
    openUrl="t3code://threads/environment/pin"},
  {id="work",title="Working fixture",projectName="Project B",status="working",since=now-3*60000,
    branch="feature/test",provider="codex",openUrl="t3code://threads/environment/work"},
  {id="wait",title="Waiting fixture",projectName="Project C",status="approval",openUrl="t3code://threads/environment/wait"}
}}}
local limitData={loading=false,updatedAt=now-2*60000,accounts={a,b,c}}
local function tr(key,values)
  local value=translations
  for part in key:gmatch("[^.]+") do value=type(value)=="table" and value[part] end
  assert(type(value)=="string","missing translation "..key)
  return (value:gsub("{([^}]+)}",function(name) return tostring((values or {})[name]) end))
end
noctalia={tr=tr, nowMs=function() return now end,
  state={get=function(key) return key=="threads" and threadData or limitData end,
    watch=function(key,cb) watches[key]=cb end,
    set=function(key,value) assert(key=="limits_request") request=value end},
  runAsync=function(argv) launched=argv return true end,
  formatTime=function(pattern,seconds) return os.date("!"..pattern,seconds) end,
  openSettings=function() settings=true end,
  togglePanel=function(id) assert(id=="PedroRBC/t3code-bar:panel") end,
}
ui=setmetatable({},{__index=function(_,kind)
  return function(props,children) return {kind=kind,props=props,children=children or {}} end
end})
panel={render=function(value) tree=value end,close=function() closed=true end,
  setWantsSecondTicks=function(value) assert(value) end}
barWidget={render=function(value) tree=value end,setTooltip=function(value) tooltip=value end,
  isVertical=function() return false end}
local function texts(node,result)
  result=result or {}
  if node.props.text then table.insert(result,node.props.text) end
  for _,child in ipairs(node.children) do texts(child,result) end
  return table.concat(result,"\n")
end
local require=function() return L end
'''
        source = (PLUGIN / filename).read_text()
        self.run_case(before + "\n" + source + "\n" + case, harness)

    def test_panel_default_order_offline_words_usage_and_refresh(self):
        self.ui_case("panel.luau", '''
onOpen()
assert(request.force==false)
local list=tree.children[2]
assert(list.kind=="scroll" and #list.children==3)
assert(list.children[1].props.key=="thread:pin" and list.children[2].props.key=="thread:work" and list.children[3].props.key=="thread:wait")
for _,row in ipairs(list.children) do assert(row.kind=="column") end
assert(texts(list):find("Working\\n3m",1,true))
local pill=list.children[3].children[2].children[3]
assert(pill.props.fill=="#F2C14E" and pill.children[1].props.text=="Needs approval")
list.children[2].props.onHover("true")
assert(tree.children[2].children[2].props.fill=="on_surface/0.07")
list.children[2].props.onHover("false")
assert(tree.children[2].children[2].props.fill=="on_surface/0")
list.children[2].props.onClick()
assert(launched[1]=="xdg-open" and launched[2]=="t3code://threads/environment/work" and closed)
threadData.data.online=false watches.threads(threadData)
assert(not texts(tree):find("Working\\n",1,true) and texts(tree):find("Project B · feature/test\\n3m",1,true))
assert(texts(tree):find("T3 Code offline",1,true) and texts(tree):find("Needs approval",1,true))
tree.children[1].children[2].props.onClick()
local content=texts(tree)
assert(content:find("48%\\nleft",1,true) and content:find("20%\\nleft",1,true))
assert(content:find("83%\\nleft",1,true) and content:find("35%\\nleft",1,true))
assert(content:find("Refill +3% in 3h 41m",1,true) and not content:find("Resets in 3h 41m\\nRefill",1,true))
assert(content:find("2 accounts",1,true) and content:find("Usage below pace",1,true) and not content:find("@",1,true))
assert(content:find("Resets in 3h 41m",1,true) and content:find("AA 95%",1,true) and not content:find("CC 83%",1,true))
assert(content:find("Updated 2 min ago",1,true))
limitData.accounts={a,codex("d","dana.delta@example.test",0,10,20*60000)} watches.limits(limitData)
assert(texts(tree):find("Resets in 20m\\nRefill +3% in 3h 41m",1,true)) -- unused account resets first, refills nothing
limitData.accounts={a,b,c} watches.limits(limitData)
tree.children[2].children[2].children[2].props.onClick()
assert(request.force==true)
limitData.error={key="errors.configure"} watches.limits(limitData)
assert(texts(tree):find("Connect a CLIProxyAPI hub",1,true) and not texts(tree):find("No successful reading",1,true))
tree.children[2].children[6].props.onClick()
assert(settings)
onClose() onOpen()
assert(tree.children[1].children[1].props.fill=="on_surface/0.12")
threadData.data.threads={} watches.threads(threadData)
assert(texts(tree):find("No threads yet",1,true))
''')

    def test_thread_provider_icon_colors(self):
        self.ui_case("panel.luau", '''
threadData.data.threads[1].provider="claudeAgent"
threadData.data.threads[3].provider="opencode"
onOpen()
local rows=tree.children[2].children
local claude=rows[1].children[2].children[1]
local codex=rows[2].children[2].children[1]
local opencode=rows[3].children[2].children[1]
assert(claude.kind=="image" and claude.props.path=="assets/claude.svg")
assert(codex.kind=="glyph" and codex.props.name=="brand-openai" and codex.props.color=="primary")
assert(opencode.props.color=="on_surface_variant")
''')

    def test_widget_urgency_tooltip_and_zero_count(self):
        self.ui_case("widget.luau", '''
assert(tree.children[1].props.path=="assets/t3code.png" and tree.children[1].props.opacity==1)
assert(tree.children[2].props.fill=="#F2C14E" and tree.children[2].children[1].props.text=="Approval")
assert(tooltip:find("Codex 48% · Claude 83% left (5-hour)",1,true))
threadData.data.counts={waiting=0,working=2} watches.threads(threadData)
assert(tree.children[2].props.fill=="primary" and tree.children[3].props.text=="2")
threadData.data.counts={waiting=0,working=0} threadData.data.online=false watches.threads(threadData)
assert(#tree.children==1 and tree.children[1].props.opacity==0.4)
onClick()
''')


if __name__ == "__main__":
    unittest.main()
