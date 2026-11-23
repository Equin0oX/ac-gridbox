# Headless test for the GridBox online script: the real Lua under LuaJIT with stubbed CSP APIs (vec3 methods return self/out like CSP).
# usage: python tests/run_tests.py     (needs: pip install lupa)
# Geometry used below: the car heads +x, wheelbase 2.7 m, track 1.6 m, tyre 0.25 m wide. Default settings: contact patch 0.1 m, line
# 0.08 m wide, box 2.4 m between the side lines. The front line sits at the front edge of the spawn patches, so a front tyre is outside
# when it has moved more than half a line width (0.04 m) forward, a tyre is outside sideways when it has moved 0.315 m off centre.
import os
from lupa import luajit21

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "..", "gridbox.lua")
STUBS = r'''
local V = {}
V.__index = V
function vec3(x, y, z) return setmetatable({x = x or 0, y = y or 0, z = z or 0}, V) end
function V:clone() return vec3(self.x, self.y, self.z) end
function V:add(o, out) out = out or self; out.x, out.y, out.z = self.x + o.x, self.y + o.y, self.z + o.z return out end
function V:sub(o, out) out = out or self; out.x, out.y, out.z = self.x - o.x, self.y - o.y, self.z - o.z return out end
function V:scale(m, out) out = out or self; out.x, out.y, out.z = self.x * m, self.y * m, self.z * m return out end
function V:addScaled(o, s, out) out = out or self; out.x, out.y, out.z = self.x + o.x * s, self.y + o.y * s, self.z + o.z * s return out end
function V:lengthSquared() return self.x ^ 2 + self.y ^ 2 + self.z ^ 2 end
function V:length() return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end
function V:distance(o) return math.sqrt((self.x - o.x) ^ 2 + (self.y - o.y) ^ 2 + (self.z - o.z) ^ 2) end
function V:dot(o) return self.x * o.x + self.y * o.y + self.z * o.z end
function V:normalize(out) out = out or self; local l = self:length() out.x, out.y, out.z = self.x / l, self.y / l, self.z / l return out end
function vec2(x, y) return {x = x or 0, y = y or 0} end
function rgbm(r, g, b, m) return {r = r, g = g, b = b, mult = m} end

SIM = {raceSessionType = 3, currentSessionTime = 0, windowWidth = 1920, currentSessionIndex = 1, carsCount = 1, isAdmin = true}
CAR = {speedKmh = 0, position = vec3(0, 0, 0), racePosition = 3, wheels = {}, isInPitlane = false}
OTHERS = {}
function CAR:driverName() return 'Test Driver' end
-- car centre (cx, cz) heading +x, wheelbase 2.7 m, wheel centres 0.3 m above ground
function place(cx, cz)
  CAR.position = vec3(cx, 0, cz)
  CAR.transform = {position = CAR.position} -- physics origin = model origin unless a test moves it
  local function wheel(x, z) return {position = vec3(x, 0.3, z), contactPoint = vec3(x, 0, z), tyreRadius = 0.3, tyreWidth = 0.25} end
  CAR.wheels = {[0] = wheel(cx + 1.35, cz - 0.8), [1] = wheel(cx + 1.35, cz + 0.8), [2] = wheel(cx - 1.35, cz - 0.8), [3] = wheel(cx - 1.35, cz + 0.8)}
end
-- same, turned by `deg` degrees around the car centre (positive turns towards +z)
function place_yaw(cx, cz, deg)
  local a = math.rad(deg)
  local cs, sn = math.cos(a), math.sin(a)
  CAR.position = vec3(cx, 0, cz)
  CAR.transform = {position = CAR.position}
  local function wheel(lx, lz) local x, z = cx + lx * cs - lz * sn, cz + lx * sn + lz * cs return {position = vec3(x, 0.3, z), contactPoint = vec3(x, 0, z), tyreRadius = 0.3, tyreWidth = 0.25} end
  CAR.wheels = {[0] = wheel(1.35, -0.8), [1] = wheel(1.35, 0.8), [2] = wheel(-1.35, -0.8), [3] = wheel(-1.35, 0.8)}
end
place(100, 50)

CHAT, HUD, QUADS, LABELS, DEBUG, BUTTONS, MSG, HUDOFF, EVENTS, QV = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
ac = {SessionType = {Race = 3, Practice = 1}, SharedNamespace = {ServerScript = 'server_script'}, StructItem = {}}
function ac.getSim() return SIM end
function ac.getCar(i) if i == 0 then return CAR end return OTHERS[i] end
function ac.getUI() return {uiScale = 1} end
function ac.sendChatMessage(t) CHAT[#CHAT + 1] = t end
-- ac.storage: a callable table whose string keys land in a file; STORE is that file
STORE = {}
ac.storage = setmetatable({}, {__index = function(_, k) return STORE[k] end, __newindex = function(_, k, v) STORE[k] = v end})
function ac.storageSetPath(p) STORE_PATH = p end
function nreports() local c = 0 for k in pairs(STORE) do if tostring(k):find('^report_') then c = c + 1 end end return c end
function lastreport() local n = tonumber(STORE.reports) return n and STORE[string.format('report_%03d', n % 1000)] end
-- the track's start nodes AC_START_0, AC_START_1 (two grid rows 6 m apart, 3 m to the side) and the session
-- the track's start nodes AC_START_0, AC_START_1 (two grid rows 6 m apart, 3 m to the side) and what the session says is this car's
-- slot (forcedPosition, -1: not assigned)
SLOT = -1
NODES = {[0] = {pos = vec3(100, 0, 50), look = vec3(1, 0, 0)}, [1] = {pos = vec3(94, 0, 53), look = vec3(1, 0, 0)}}
function ac.getSession(i) return {forcedPosition = SLOT} end
ROOT = {findNodes = function(self, q)
  if q == 'AC_START_?' then return {size = function() return 2 end} end
  local i = tonumber(q:match('^AC_START_(%d+)$'))
  local n = i and NODES[i]
  return {name = function() return n and q or '' end, size = function() return n and 1 or 0 end, getPosition = function() return n and n.pos end, getLook = function() return n and n.look end}
end}
function ac.findNodes(q) return ROOT end
OTHER = {index = 1, sessionID = 4} -- another driver's car as an event sender
function OTHER:driverName() return 'Other Driver' end
SENT, SEND_OK = {}, true -- every event sent, and whether the server accepts sends right now (a stock server refuses faster than 5 per s)
SENDER = {index = 0}
function SENDER:driverName() return 'Test Driver' end
function ac.debug(k, v) DEBUG[k] = v end
function ac.setMessage(t, d) MSG[#MSG + 1] = t .. ':' .. d end
function ac.disableExtraHUDElements(id, d) HUDOFF[#HUDOFF + 1] = id end
function ac.StructItem.key(k) return k end
function ac.StructItem.int16() return 'int16' end
function ac.StructItem.float() return 'float' end
function ac.onSessionStart(cb) SESSION_CB = cb end
function ac.onOnlineWelcome(cb) WELCOME_CB = cb end
-- events are kept by key; the returned function delivers to the sender's own callback like CSP does
function ac.OnlineEvent(layout, cb, ns)
  EVENTS[layout.key] = cb
  return function(msg) SENT[#SENT + 1] = {key = layout.key, msg = msg} if not SEND_OK then return false end cb(SENDER, msg) return true end
end
ui = {Icons = {Pitlane = 'pitlane'}, OnlineExtraFlags = {None = 0, Admin = 1}}
function ui.registerOnlineExtra(icon, title, avail, uiCb, closeCb, flags) BUTTONS[#BUTTONS + 1] = {title = title, flags = flags, click = closeCb} end
function ui.transparentWindow(id, pos, size, noPad, inputs, content) assert(pos.x and size.y and type(content) == 'function') content() end
function ui.textColored(text, col) assert(type(text) == 'string' and col.r) HUD[#HUD + 1] = {text, col} end
render = {BlendMode = {AlphaBlend = 1}, DepthMode = {ReadOnly = 1}}
-- the visible road: a function of (x, z) the ray stub hits; the ray reports the distance down to it like CSP's ray:track()
function GROUND(x, z) return 0 end
function render.createRay(pos, dir, len)
  return {track = function(self) local d = pos.y - GROUND(pos.x, pos.z) if d < 0 or d > len then return -1 end return d end}
end
function render.on(name, cb) RENDER_CB = cb end
function render.setBlendMode() end
function render.setDepthMode() end
function render.quad(a, b, c, d, col) assert(a.x and d.z and col.r) QUADS[#QUADS + 1] = col QUADY = a.y QV[#QV + 1] = {{a.x, a.z, a.y}, {b.x, b.z, b.y}, {c.x, c.z, c.y}, {d.x, d.z, d.y}} end
function render.debugText(p, text, col, scale) assert(p.x and type(text) == 'string') LABELS[#LABELS + 1] = text end
script = {}
function reset() CHAT, HUD, QUADS, LABELS, QV = {}, {}, {}, {}, {} end
function run(seconds) for i = 1, math.floor(seconds / 0.05 + 0.5) do SIM.currentSessionTime = SIM.currentSessionTime + 50 script.update(0.05) end end
function frame() reset() RENDER_CB() script.drawUI() end
function button(title) for _, b in ipairs(BUTTONS) do if b.title == title then b.click() return end end error('no button ' .. title) end
-- what startLights.lua sends when an admin starts its lights: lights out at startTime + delayTime on the session clock
function lights(inMs, delayMs) EVENTS['Start Lights']({index = 0}, {startTime = SIM.currentSessionTime + inMs, delayTime = delayMs}) end
'''
fails = []
def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond: fails.append(msg)

def make(config=None):
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(STUBS)
    lua.execute(open(APP, encoding="utf-8").read())
    lua.execute("CFG = {}")
    for k, v in (config or {}).items(): lua.execute("CFG['%s'] = %s" % (k, repr(v) if isinstance(v, str) else v))
    lua.execute("WELCOME_CB('welcome', {get = function(self, s, k, d) if CFG[k] ~= nil then return CFG[k] end return d end})")
    return lua

def start_race(lua):
    lua.execute("SESSION_CB(1, false)")
    lua.execute("run(2)")

def n(lua, expr): return lua.eval(expr)

# 1 practice session: nothing recorded
lua = make(); lua.execute("SIM.raceSessionType = 1; SESSION_CB(1, false); run(2); frame()")
check(n(lua, "#QUADS") == 0 and n(lua, "#HUD") == 0, "practice session: no box, no HUD")

# 2 race session, car standing: box recorded and drawn as front line + two side lines, no rear line, green
lua = make(); start_race(lua); lua.execute("frame()")
check(n(lua, "#QUADS") == 3 and all(n(lua, "QUADS[%d].%s" % (i, c)) == 1 for i in (1, 2, 3) for c in "rgb"), "race start: front line and two side lines drawn (no rear line), white")
check(n(lua, "LABELS[1]") == "P1  YOUR BOX", "a lone car is grid P1 (not the game's race position 3)")
check(n(lua, "HUD[1][1]") == "Grid P1  -  0.04 m to the line" and n(lua, "HUD[1][2].g") == 1, "standing on the spawn spot: valid with 0.04 m to spare, green HUD text")

# 2a complete corners: the front line reaches half a line width past the side lines' centres, the side lines half a line width past
# the front line's centre (car at (100, 50) heading +x: front line centre x = 101.35 + 0.05, side lines at z = 50 +- 1.2, width 0.08)
zs = lambda q: [p[2] for p in lua.eval("QV[%d]" % q).values()]
xs = lambda q: [p[1] for p in lua.eval("QV[%d]" % q).values()]
check(abs(max(zs(1)) - 51.24) < 1e-6 and abs(min(zs(1)) - 48.76) < 1e-6, "front line reaches the outer edges of both side lines (z 48.76 .. 51.24)")
check(abs(max(xs(2)) - 101.44) < 1e-6 and abs(max(xs(3)) - 101.44) < 1e-6, "side lines reach the front edge of the front line (x 101.44): square outer corners")

# 2b grid position counts only connected cars ahead: here one disconnected slot ahead, one connected ahead, one behind
lua = make(); lua.execute("SIM.carsCount = 4; OTHERS = {[1] = {isConnected = false, racePosition = 1}, [2] = {isConnected = true, racePosition = 2}, [3] = {isConnected = true, racePosition = 5}}")
start_race(lua); lua.execute("frame()")
check(n(lua, "LABELS[1]") == "P2  YOUR BOX", "grid position = 1 + connected cars ahead (the empty slot ahead is ignored)")

# 2c the box lies on the visible road (a ray down onto the track meshes), not on the physics contact points or the car origin
lua = make(); lua.execute("CAR.position.y = -0.2; for k = 0, 3 do CAR.wheels[k].contactPoint.y = -0.05 end; GROUND = function(x, z) return 0.02 end; SESSION_CB(1, false); run(2); frame()")
check(abs(n(lua, "QUADY") - 0.03) < 1e-6, "box height = visible road (0.02) + 1 cm, even though the contact points say -0.05")
lua = make(); lua.execute("GROUND = function(x, z) return 0.02 * (x - 100) end; SESSION_CB(1, false); run(2); frame()")
ys = [p[3] for q in (2,) for p in lua.eval("QV[%d]" % q).values()]
check(abs(ys[0] - (0.02 * 1.4 + 0.01)) < 1e-6 and abs(ys[1] - (0.02 * (101.4 - 4.5 - 100) + 0.01)) < 1e-6,
      "on a slope each corner follows the road: front end 0.038, rear end -0.052")
lua = make({"SOURCE": "car"}); lua.execute("render.createRay = nil; CAR.position.y = -0.2; for k = 0, 3 do CAR.wheels[k].contactPoint.y = -0.05 end; SESSION_CB(1, false); run(2); frame()")
check(abs(n(lua, "QUADY") + 0.04) < 1e-6, "no ray available: falls back to the average contact point height (-0.05) + 1 cm")
lua = make({"SOURCE": "car"}); lua.execute("render.createRay = nil; for k = 0, 3 do CAR.wheels[k].contactPoint = nil end; SESSION_CB(1, false); run(2); frame()")
check(abs(n(lua, "QUADY") - 0.01) < 1e-6, "no ray and no contact points: falls back to wheel centre minus tyre radius (0.3 - 0.3) + 1 cm")
lua = make(); start_race(lua)

# 3 the game's own green does not hide the box: it stays for the formation lap
lua = make(); start_race(lua)
lua.execute("place(400, 50); CAR.speedKmh = 80; run(30); frame()")
check(n(lua, "#QUADS") == 3 and "m to your box" in n(lua, "HUD[1][1]"), "formation lap: box stays and the HUD shows the distance")
check(n(lua, "nreports()") == 0, "no report while nobody started the lights")

# 4 back in the box clearly over the line (0.30 m), then the start lights go out: red until then, one report at lights out, then hidden
lua.execute("place(100.30, 50); CAR.speedKmh = 0; run(1); frame()")
check(n(lua, "HUD[1][1]") == "OVER THE LINE  +0.26 m" and n(lua, "HUD[1][2].g") < 0.5, "0.30 m forward: red HUD warning, +0.26 m beyond the line")
check(all(n(lua, "QUADS[%d].%s" % (i, c)) == 1 for i in (1, 2, 3) for c in "rgb"), "the lines stay white while the car is outside")
lua.execute("lights(2000, 1500); run(3); frame()")
check(n(lua, "#QUADS") == 3 and n(lua, "nreports()") == 0, "lights started but not out yet: box still shown, no report yet (no live report by default)")
lua.execute("run(1)")
check(n(lua, "nreports()") == 1 and "grid P1  0.26 m over the line at lights out" in n(lua, "lastreport()"), "lights out: one report line with the grid position and the distance")
lua.execute("frame()")
check(n(lua, "#QUADS") == 0 and n(lua, "#HUD") == 0, "after the lights are out the box and HUD are hidden")

# 5 a patch on the line is inside, a patch sticking out past the outer edge of the line is outside
lua = make(); start_race(lua); lua.execute("place(100.03, 50); run(1); frame()")
check(n(lua, "HUD[1][2].g") == 1 and "m to the line" in n(lua, "HUD[1][1]"), "0.03 m forward (patch on the line, inside its outer edge): valid")
lua.execute("lights(100, 100); run(1)")
check(n(lua, "nreports()") == 0, "valid at lights out: no report")
lua = make(); start_race(lua); lua.execute("place(100.10, 50); run(1); frame()")
check(n(lua, "HUD[1][1]") == "OVER THE LINE  +0.06 m" and n(lua, "HUD[1][2].g") < 0.5, "0.10 m forward (patch sticks out past the line): outside by 0.06 m")

# 5b the side lines: a patch inside or on the line is fine, one reaching past its outer edge is outside
lua = make(); start_race(lua); lua.execute("place(100, 50.3); run(1); frame()")
check(n(lua, "HUD[1][2].g") == 1, "car 0.3 m off centre (tyres on or inside the side lines): valid")
lua.execute("place(100, 50.523); run(1); frame()")
check(n(lua, "HUD[1][1]") == "OUTSIDE THE BOX  +0.21 m" and n(lua, "HUD[1][2].g") < 0.5, "car 0.52 m off centre (tyre past the side line): outside the box")
lua.execute("lights(100, 100); run(1)")
check(n(lua, "nreports()") == 1 and "grid P1  0.21 m outside the box at lights out" in n(lua, "lastreport()"), "lights out while outside the side line: reported as outside the box")
lua = make(); start_race(lua); lua.execute("place(100.30, 50.523); run(1); lights(100, 100); run(1)")
check("0.26 m over the line and 0.21 m outside the box" in n(lua, "lastreport()"), "over the line and outside the side line: one line with both")

# 5c a car standing too sideways: the turned patches stick out
lua = make(); start_race(lua); lua.execute("place_yaw(100, 50, 2); run(1); frame()")
check(n(lua, "HUD[1][2].g") == 1, "car turned 2 degrees in its box: valid")
lua.execute("place_yaw(100, 50, 15); run(1); frame()")
check(n(lua, "HUD[1][1]") == "OVER THE LINE  +0.15 m", "car turned 15 degrees: a front corner swings past the front line")
lua.execute("place_yaw(98.5, 50, 15); run(1); frame()")
check(n(lua, "HUD[1][1]") == "OUTSIDE THE BOX  +0.02 m", "car turned 15 degrees and set back: a tyre sticks out of the side line")

# 6 car already rolling at lights out is judged by where it last stood
lua = make({"JUMP_REPORT": 0}); start_race(lua); lua.execute("place(100.30, 50); run(1); lights(500, 100); place(101.0, 50); CAR.speedKmh = 30; run(1)")
check(n(lua, "nreports()") == 1 and "0.26 m" in n(lua, "lastreport()"), "launching car: report uses the last standing value (0.26 m)")

# 7 a car still out on the formation lap, or parked far away, is not blamed
lua = make(); start_race(lua); lua.execute("place(400, 50); CAR.speedKmh = 0; run(3); lights(500, 100); run(1)")
check(n(lua, "nreports()") == 0, "parked 300 m from its box: no report at lights out")

# 9 F1-style: a first message with a huge delay keeps the box, the manual second message ends it
lua = make(); start_race(lua); lua.execute("place(100.30, 50); run(1); lights(0, 999999999); run(10); frame()")
check(n(lua, "#QUADS") == 3 and n(lua, "nreports()") == 0, "F1-style start armed: box stays")
lua.execute("lights(0, 50); run(0.3)")
check(n(lua, "nreports()") == 1, "manual lights out: report and box gone")

# 10 another formation lap: the admin button brings the box back at the same spot, until the next lights out
lua.execute("frame()")
check(n(lua, "#QUADS") == 0, "box is hidden after the start")
lua.execute("button('Grid: show boxes'); place(100.30, 50); frame()")
check(n(lua, "#QUADS") == 3 and n(lua, "LABELS[1]") == "P1  YOUR BOX", "show button: same box at the same position again")
lua.execute("run(20); frame()")
check(n(lua, "#QUADS") == 3, "shown box stays until the lights go out again")
lua.execute("reset(); lights(500, 100); run(1)")
check(n(lua, "nreports()") == 2 and "0.26 m over the line at lights out" in n(lua, "lastreport()"), "second start: reported again (second line in the file)")
lua.execute("frame()")
check(n(lua, "#QUADS") == 0, "hidden again after the second lights out")

# 11 hide button, and all three buttons are admin only
lua.execute("button('Grid: show boxes'); button('Grid: hide boxes'); frame()")
check(n(lua, "#QUADS") == 0, "hide button hides the box")
check(n(lua, "#BUTTONS") == 5 and all(n(lua, "BUTTONS[%d].flags" % i) == 1 for i in (1, 2, 3, 4, 5)), "five admin-only buttons are registered")

# 12 position text only
lua = make({"STYLE": "text"}); start_race(lua); lua.execute("frame()")
check(n(lua, "#QUADS") == 0 and n(lua, "LABELS[1]") == "P1", "STYLE=TEXT: only the position text, no lines")
check(n(lua, "#HUD") == 0, "STYLE=TEXT: no HUD warning or line distance near the box (nothing is checked)")
lua.execute("place(400, 50); CAR.speedKmh = 80; run(1); frame()")
check("m to your box" in n(lua, "HUD[1][1]"), "STYLE=TEXT: far from the box the HUD still shows the distance to it")
lua = make({"STYLE": "text"}); start_race(lua); lua.execute("place(100.30, 50.523); run(1); frame()")
check(n(lua, "#HUD") == 0, "STYLE=TEXT: a car 0.26 m forward and out sideways gets no HUD warning")
lua.execute("lights(100, 100); run(1)")
check(n(lua, "nreports()") == 0, "STYLE=TEXT: no report at lights out")
lua = make(); start_race(lua); lua.execute("button('Grid: toggle lines'); frame()")
check(n(lua, "#QUADS") == 0 and n(lua, "LABELS[1]") == "P1", "toggle button: lines off, position text stays")
lua.execute("button('Grid: toggle lines'); frame()")
check(n(lua, "#QUADS") == 3, "toggle button again: lines back")
lua = make(); start_race(lua); lua.execute("place(100.30, 50); run(1); button('Grid: toggle lines'); lights(100, 100); run(1)")
check(n(lua, "nreports()") == 0, "lines toggled off before the lights go out: no report")
lua = make(); start_race(lua); lua.execute("place(100.30, 50); run(1); button('Grid: toggle lines'); button('Grid: toggle lines'); lights(100, 100); run(1)")
check(n(lua, "nreports()") == 1, "lines toggled off and on again: the check is back")

# 12b reports go to the admin's file and never to the chat
lua = make(); start_race(lua); lua.execute("place(100.30, 50); run(3); lights(500, 100); run(1)")
check(n(lua, "#CHAT") == 0 and n(lua, "nreports()") == 1, "the report is written to the file, nothing is sent to the chat")
check(n(lua, "STORE_PATH") == "gridbox" and n(lua, "STORE.reports") == "1", "the file is the gridbox storage, with a running total of the reports")
check(" Test Driver  grid P1" in n(lua, "STORE.report_001"), "each line has a time, the driver name and the grid position")
lua = make(); lua.execute("SIM.isAdmin = false"); start_race(lua); lua.execute("place(100.30, 50); run(1); lights(500, 100); run(1)")
check(n(lua, "nreports()") == 0 and n(lua, "#CHAT") == 0, "a client that is not an admin writes nothing (it only sends the event)")

# 12c jump start: a car that stood in its box after the lights were started and moves before they go out
lua = make(); start_race(lua); lua.execute("lights(2000, 1500); run(1); CAR.speedKmh = 20; run(0.5)")
check(n(lua, "nreports()") == 1 and "JUMP START, moved 2450 ms before the lights went out" in n(lua, "lastreport()"), "car moves 2.45 s before lights out: reported as a jump start")
lua.execute("run(5)")
check(n(lua, "nreports()") == 1, "a jump start is reported once per start")
lua = make(); start_race(lua); lua.execute("CAR.speedKmh = 20; lights(2000, 1500); run(1); CAR.speedKmh = 0; run(0.5); CAR.speedKmh = 20; run(0.5)")
check(n(lua, "nreports()") == 1, "a car still rolling when the lights started is only a jump start once it has stood in its box and moves again")
lua = make(); start_race(lua); lua.execute("CAR.speedKmh = 20; lights(2000, 1500); run(5)")
check(n(lua, "nreports()") == 0, "a car that never stood still after the lights started is not called a jump start")
lua = make(); start_race(lua); lua.execute("lights(500, 100); run(1); CAR.speedKmh = 30; run(2)")
check(n(lua, "nreports()") == 0, "moving only after the lights went out: no jump start")
lua = make({"JUMP_REPORT": 0}); start_race(lua); lua.execute("lights(2000, 1500); run(1); CAR.speedKmh = 20; run(0.5)")
check(n(lua, "nreports()") == 0, "JUMP_REPORT=0 turns the jump start report off")

# 13 config: tolerance, patch length and final report
lua = make({"TOLERANCE_M": 0.5}); start_race(lua); lua.execute("place(100.30, 50); run(1); lights(100, 100); run(1)")
check(n(lua, "nreports()") == 0, "TOLERANCE_M=0.5 from the server config lets 0.26 m pass")
lua = make({"PATCH_M": 0, "LINE_WIDTH_M": 0}); start_race(lua); lua.execute("place(100.10, 50); run(1); frame()")
check(n(lua, "HUD[1][2].g") < 0.5, "PATCH_M=0 and LINE_WIDTH_M=0: the wheel centre is the limit (0.10 m forward is outside)")
lua = make({"FINAL_REPORT": 0}); start_race(lua); lua.execute("place(100.30, 50); run(1); lights(100, 100); run(1)")
check(n(lua, "nreports()") == 0, "FINAL_REPORT=0 silences the report")

# 14 moving at settle time: nothing recorded; admin re-record button records once the car stands still
lua = make(); lua.execute("CAR.speedKmh = 60; SESSION_CB(1, false); run(2); frame()")
check(n(lua, "#QUADS") == 0, "car still moving when the settle time ends: no box")
lua.execute("CAR.speedKmh = 0; button('Grid: re-record boxes'); frame()")
check(n(lua, "#QUADS") == 3, "admin re-record command records the standing car")
lua.execute("SIM.raceSessionType = 1; CAR.speedKmh = 60; button('Grid: re-record boxes'); CAR.speedKmh = 0; SIM.raceSessionType = 3; frame()")
check(n(lua, "#QUADS") == 3, "re-record while moving is ignored, the old box stays")

# 15 a new session clears the box
lua = make(); start_race(lua); lua.execute("SESSION_CB(2, false); frame()")
check(n(lua, "#QUADS") == 0, "new session start clears the old box")

# 16 errors inside update never escape, they land in the debug line
lua = make(); start_race(lua); lua.execute("CAR.wheels = nil; run(0.1)")
check("wheels" in str(n(lua, "DEBUG['gridbox error']") or "") or "index" in str(n(lua, "DEBUG['gridbox error']") or ""), "error inside update is caught and shown, not thrown")

# 17 debug mode: proof of life even when no box exists; silent by default
lua = make(); lua.execute("SIM.raceSessionType = 1; SESSION_CB(1, false); run(2); frame()")
check(n(lua, "#MSG") == 0 and n(lua, "#HUD") == 0 and n(lua, "DEBUG['gridbox status']") is None, "DEBUG off: no message, no status line")
lua = make({"DEBUG": 1}); lua.execute("SIM.raceSessionType = 1; SESSION_CB(1, false); run(2); frame()")
check(n(lua, "MSG[1]") == "GridBox:script loaded", "DEBUG=1: 'script loaded' message at join")
check(n(lua, "HUD[1][1]").startswith("GridBox debug: session=1") and "box=no" in n(lua, "HUD[1][1]"), "DEBUG=1: status line shows without a box")
lua.execute("SIM.raceSessionType = 3; SESSION_CB(2, false); run(2); lights(5000, 1000); frame()")
check("box=yes from=slot 0 slotErr=0.00 shown=true over=-0.040 side=" in n(lua, "HUD[1][1]") and "lights-out in 6.0 s" in n(lua, "HUD[1][1]") and n(lua, "#QUADS") == 3,
      "DEBUG=1: status line shows the box state, the over/side margins in metres and the lights countdown")

# 18 slot mode (the main way): the box comes from the track's start slot of this car (forcedPosition), not from where the car stands
lua = make(); lua.execute("SLOT = 1"); start_race(lua); lua.execute("frame()")
check(n(lua, "LABELS[1]") == "P2  YOUR BOX", "forcedPosition 1 is slot AC_START_1 and grid P2")
check(abs(max(xs(2)) - 95.44) < 1e-6 and abs(max(zs(1)) - 54.24) < 1e-6 and abs(min(zs(1)) - 51.76) < 1e-6,
      "the box stands at the start node (94, 53) with the front axle offset ahead of it, not where the car stands (100, 50)")
lua = make({"DEBUG": 1}); lua.execute("SLOT = 0"); start_race(lua); lua.execute("frame()")
check("from=slot 0 slotErr=0.00" in n(lua, "HUD[1][1]"), "DEBUG: a car standing on its spawn spot is 0.00 m from where the slot says (the assumption holds)")
lua = make({"DEBUG": 1}); lua.execute("SLOT = 1"); start_race(lua); lua.execute("frame()")
check("from=slot 1 slotErr=6.71" in n(lua, "HUD[1][1]"), "DEBUG: a car 6.71 m from its slot shows that distance")
lua = make(); lua.execute("SLOT = 0; CAR.speedKmh = 60; SESSION_CB(1, false); run(2); frame()")
check(n(lua, "#QUADS") == 3, "a moving car still gets its slot box: the slot does not need a standing car")
lua = make(); lua.execute("SLOT = 1"); start_race(lua); lua.execute("place(100.5, 50); run(1); lights(100, 100); run(1)")
check(n(lua, "nreports()") == 1 and "over the line" in n(lua, "lastreport()"), "the check measures against the slot box: a car out of its slot at lights out is outside")

# 18b fallback: the box from where the car stands, when the slot cannot be determined
lua = make(); lua.execute("SLOT = -1"); start_race(lua); lua.execute("frame()")
check(abs(max(xs(2)) - 101.44) < 1e-6 and n(lua, "LABELS[1]") == "P1  YOUR BOX", "forcedPosition -1: the box stands where the car stands")
lua = make(); lua.execute("SLOT = 7"); start_race(lua); lua.execute("frame()")
check(abs(max(xs(2)) - 101.44) < 1e-6, "a forcedPosition without a start node: the box stands where the car stands")
for slot, setup, why in ((-1, "place(200, 200)", "why-not-slot=forcedPosition=-1, nearest start node 180.3 m away"),
                         (7, "", "why-not-slot=no node AC_START_7 (0 found)"),
                         (0, "ac.findNodes = nil", "why-not-slot=error:")):
    lua = make({"DEBUG": 1}); lua.execute("SLOT = %d; %s" % (slot, setup)); start_race(lua); lua.execute("frame()")
    check(why in n(lua, "HUD[2][1]"), "DEBUG second line says why the slot was not used: " + why)
lua = make({"DEBUG": 1}); lua.execute("SLOT = -1"); start_race(lua); lua.execute("frame()")
check("start nodes=2 nearest=0 (0.00 m)" in n(lua, "HUD[2][1]"), "DEBUG second line counts the track's start nodes and names the one nearest to the car")
# the game spawns the PHYSICS origin on the node; the model origin can sit ahead of it (Tatuus: 0.42 m, its graphics offset). Measured in game:
# model origin 0.42 m ahead of node 0, front axle 1.28 m ahead of the model origin. The box must then be the one of a car parked at the spawn.
spawn = ("place(100.42, 50); CAR.transform = {position = vec3(100, 0, 50)}; for k = 0, 3 do local w = CAR.wheels[k] "
         "w.position.x = w.position.x - 0.07; w.contactPoint.x = w.contactPoint.x - 0.07 end")  # axles 1.28 ahead / 1.42 behind the model origin
lua = make({"DEBUG": 1}); lua.execute("SLOT = -1; " + spawn); start_race(lua); lua.execute("frame()")
check("from=slot 0 slotErr=0.00" in n(lua, "HUD[1][1]") and "over=-0.040" in n(lua, "HUD[1][1]"),
      "model origin 0.42 m ahead of the node: the box is measured from the physics origin, a car on its spawn spot is inside (over -0.04, slotErr 0)")
lua = make(); lua.execute("SLOT = -1; " + spawn + "; CAR.transform = nil"); start_race(lua); lua.execute("frame()")
check(n(lua, "#QUADS") == 3, "no physics transform: no slot box, the car's own spot is used")
# 18c no slot assigned (forcedPosition -1, a pickup server): a standing car takes the start node it stands nearest to
lua = make({"DEBUG": 1}); lua.execute("SLOT = -1"); start_race(lua); lua.execute("frame()")
check("from=slot 0 slotErr=0.00" in n(lua, "HUD[1][1]") and n(lua, "LABELS[1]") == "P1  YOUR BOX", "forcedPosition -1, car on node 0: the box comes from node 0")
lua = make(); lua.execute("SLOT = -1; place(94.4, 53.3)"); start_race(lua); lua.execute("frame()")
check(abs(max(xs(2)) - 95.44) < 1e-6 and n(lua, "LABELS[1]") == "P1  YOUR BOX",
      "car 0.5 m from node 1: the box stands at node 1, labelled by the grid position among connected cars (P1), not node number + 1")
lua = make({"DEBUG": 1}); lua.execute("SLOT = -1; place(97, 50)"); start_race(lua); lua.execute("frame()")
check("from=car" in n(lua, "HUD[1][1]") and abs(max(xs(2)) - 98.44) < 1e-6, "car 3 m from the nearest node (radius 2 m): the box stands where the car stands")
lua = make({"SLOT_RADIUS_M": 0, "DEBUG": 1}); lua.execute("SLOT = -1"); start_race(lua); lua.execute("frame()")
check("from=car" in n(lua, "HUD[1][1]") and "why-not-slot=forcedPosition=-1" in n(lua, "HUD[2][1]"), "SLOT_RADIUS_M=0 switches the nearest node off")
lua = make({"DEBUG": 1}); lua.execute("SLOT = -1; CAR.isInPitlane = true"); start_race(lua); lua.execute("frame()")
check("car in the pit lane" in n(lua, "HUD[2][1]") and n(lua, "#QUADS") == 0, "a car in the pit lane takes no start node")
lua = make(); lua.execute("SLOT = -1; SIM.raceSessionType = 1; SESSION_CB(1, false); run(2); frame()")
check(n(lua, "#QUADS") == 0, "practice session: no box from a start node either")
lua = make(); lua.execute("SLOT = 0; ac.findNodes = nil"); start_race(lua); lua.execute("frame()")
check(abs(max(xs(2)) - 101.44) < 1e-6, "no node API at all: the box stands where the car stands, nothing breaks")
lua = make({"SOURCE": "car"}); lua.execute("SLOT = 1"); start_race(lua); lua.execute("frame()")
check(abs(max(xs(2)) - 101.44) < 1e-6, "SOURCE=CAR ignores the slot")

# 19 the fallback needs a standing car outside the pit lane, and tries again for a few seconds
lua = make(); lua.execute("CAR.isInPitlane = true"); start_race(lua); lua.execute("frame()")
check(n(lua, "#QUADS") == 0, "a late joiner standing in the pit lane gets no box")
lua.execute("lights(2000, 1500); run(1); CAR.speedKmh = 20; run(0.5)")
check(n(lua, "nreports()") == 0, "...and no jump start report either")
lua = make(); lua.execute("CAR.speedKmh = 20; SESSION_CB(1, false); run(2); frame()")
check(n(lua, "#QUADS") == 0, "a car still moving when the settle timer ends has no box yet")
lua.execute("CAR.speedKmh = 0; run(0.6); frame()")
check(n(lua, "#QUADS") == 3, "...it is tried again and recorded once the car stands still")
lua = make(); lua.execute("CAR.speedKmh = 20; SESSION_CB(1, false); run(6); CAR.speedKmh = 0; run(1); frame()")
check(n(lua, "#QUADS") == 0, "it gives up after a few seconds: a car that stops much later is not recorded where it stopped")

# 20 report numbers are 16 bit: a huge distance is clamped, it must not wrap to a negative number
lua = make({"NEAR_M": 50}); start_race(lua); lua.execute("place(140, 50); run(1); lights(100, 100); run(1)")
check("32.00 m over the line at lights out" in n(lua, "lastreport()"), "a distance above 32.7 m is clamped instead of wrapping around")

# 21 a refused send (a stock server accepts one event per 200 ms) is tried again on a later frame, not lost
lua = make(); start_race(lua); lua.execute("SEND_OK = false; place(100.30, 50); run(1); lights(100, 100); run(1)")
check(n(lua, "nreports()") == 0, "while the server refuses sends nothing arrives")
lua.execute("SEND_OK = true; run(0.5)")
check(n(lua, "nreports()") == 1, "the report goes out on a later frame once sends are accepted")

# 22 the admin sees all boxes: every client shares its box, the admin's client keeps them and draws them on request
lua = make(); lua.execute("SENT = {}"); start_race(lua)
check(n(lua, "SENT[1].key") == "GridBoxShare" and abs(n(lua, "SENT[1].msg.x") - 101.4) < 1e-6 and n(lua, "SENT[1].msg.pos") == 1
      and abs(n(lua, "SENT[1].msg.length") - 4.5) < 1e-6, "recording a box sends its front line, direction and length to the admins")
share = "EVENTS['GridBoxShare'](OTHER, {pos = 2, x = 110.0, y = 0.0, z = 60.0, fx = 1.0, fz = 0.0, length = 4.5})"
lua.execute(share + "; frame()")
check(n(lua, "#QUADS") == 3, "another driver's box is not drawn until the admin switches show all on")
lua.execute("button('Grid: show all boxes'); " + share + "; frame()")
check(n(lua, "#QUADS") == 6 and "P2  Other Driver" in list(lua.eval("LABELS").values()), "show all: the other driver's box is drawn too, with the grid position and name")
lua.execute("EVENTS['GridBoxShare'](SENDER, {pos = 1, x = 50.0, y = 0.0, z = 50.0, fx = 1.0, fz = 0.0, length = 4.5}); frame()")
check(n(lua, "#QUADS") == 6, "the own car's share is skipped, the own box is drawn from the own state")
lua.execute("lights(100, 100); run(1); frame()")
check(n(lua, "#QUADS") == 6, "show all keeps every box, the own one included, after the lights went out")
lua.execute("button('Grid: show all boxes'); frame()")
check(n(lua, "#QUADS") == 0, "show all off: back to the normal behaviour (the own box is gone after the lights)")
lua = make(); start_race(lua); lua.execute("SENT = {}; button('Grid: show all boxes'); run(0.3)")
check(any(n(lua, "SENT[%d].key" % i) == "GridBoxShare" for i in range(1, n(lua, "#SENT") + 1)), "switching show all on asks everybody to send their box again")
lua = make(); lua.execute("SIM.isAdmin = false"); start_race(lua); lua.execute("button('Grid: show all boxes'); " + share + "; frame()")
check(n(lua, "#QUADS") == 3, "a client that is not an admin ignores shared boxes")
lua = make({"STYLE": "text"}); start_race(lua); lua.execute("button('Grid: show all boxes'); " + share + "; frame()")
check(n(lua, "#QUADS") == 0 and "P2  Other Driver" in list(lua.eval("LABELS").values()), "STYLE=TEXT: other boxes are only their position text and name")

print("\n%d failed" % len(fails) if fails else "\nall passed")
raise SystemExit(1 if fails else 0)
