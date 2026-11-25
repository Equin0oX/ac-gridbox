-- GridBox: CSP online script (the server pushes it to every client through a [SCRIPT_...] block in the CSP extra options).
-- Each client works out the grid slot of ITS OWN car at the start of a race session (the track's start node AC_START_<n>, n = the
-- session's forcedPosition, or the node nearest to the standing car if the server assigns none; if the slot cannot be determined,
-- the spot where the car stands) and shows it (a front line
-- with side lines and the grid position, or just the position text) until the lights of tetematete's startLights.lua go out, i.e.
-- through the formation lap. The lines stay white; the HUD line turns red while the car is outside. If the car is outside when those lights go out, its
-- client sends a report to everybody (a hidden event, nothing appears in the chat) and the clients of signed-in admins append it to
-- a file (ac.storage: Documents\Assetto Corsa\cfg\extension\state\lua\..., see the README). Outside means: any part of any tyre's
-- contact patch is beyond the outer edge of the front line or of a side line (so a car standing too sideways is outside too). A
-- patch that is on the line is still inside.
-- With the lines hidden (STYLE=TEXT or the toggle button) nothing is checked: no HUD warning, no report.
-- An admin can bring the boxes back at the remembered spots (another formation lap) with "Grid: show boxes", hide them with
-- "Grid: hide boxes", switch between lines+text and text only with "Grid: toggle lines" (or STYLE=TEXT in the settings), record the
-- spots again with "Grid: re-record boxes", and see the boxes of ALL drivers with "Grid: show all boxes": every client sends where
-- its box is when it records it (a hidden event), and the client of a signed-in admin keeps them.
-- Settings: a [GRIDBOX] section in the same extra options (all optional, see `cfg` below for the defaults).
-- Trust: every driver's PC decides about itself and any client can send the admin commands; nothing is enforced on a stock server.
-- shortcut: own car only and kept in memory, so a driver who reconnects mid-session has to wait for the next record. The
-- start lights are learned from the event of startLights.lua (same key and layout), so a new layout there breaks the link: the
-- show/hide buttons still work.
local sim = ac.getSim()
local car = ac.getCar(0)

local cfg = {
  source = 'AUTO',   -- AUTO: the box comes from the track's start slot of this car, from where the car stands if the slot is unknown;
                     -- CAR: always from where the car stands
  slotRadius = 2,    -- m: with no assigned slot (forcedPosition -1, as on pickup servers) a standing car takes the start slot whose node
                     -- is nearest, if within this distance; 0 = never, then the box comes from where the car stands
  recordIn = 'RACE', -- sessions in which the box is recorded by itself at the session start: PRACTICE, QUALIFY, RACE (any of them, upper case,
                     -- separated by commas). An admin can always record with the button, in any session
  style = 'BOX',     -- BOX: lines + position text, TEXT: only the position text (the track's own painted boxes stay the reference)
  settle = 1.5,      -- s after a session starts before the box is recorded (cars must be standing still by then)
  still = 3,         -- km/h under which the car counts as standing still
  near = 20,         -- m from its box within which a standing car is checked
  lineFromNode = 0,  -- m, > 0: the front line lies this far ahead of the start node whatever the car (fits a track's paint for every car model;
                     -- only with a start slot, the car fallback ignores it); 0: measured from the front tyres of the car, see lineOffset
  lineOffset = 0,    -- m, moves the front line ahead (+) or behind (-) of where the front tyres' contact patches ended at the start
  lineWidth = 0.08,  -- m, drawn width of the lines; a patch may reach their outer edge
  patch = 0.1,       -- m, length of a tyre's contact patch. Too long a value puts the drawn front line too far ahead of the real patch:
                     -- a car then looks "on the centre of the line" when the check already says outside. Tune with the DEBUG status.
  tolerance = 0,     -- m of extra slack beyond the outer edge of the lines
  boxWidth = 2.4,    -- m between the side lines
  finalReport = true, -- report if the car is outside when the start lights go out
  jumpReport = true, -- report a car that moves before the start lights go out (it must have stood in its box after they were started)
  jump = 2,          -- km/h from which a car counts as moving for the jump start
  debug = false,     -- always show a status line (and a "loaded" message) so a silent script can be told from an idle one
  showNodes = false, -- with debug: also draw the track's start nodes (yellow crosses + names) in the world; off, DEBUG draws nothing but the lines
  extraTools = false, -- the admin menu has four buttons (re-record, show, hide, show all); true adds 'toggle lines' and, with debug, the test buttons
}
local grid, settle, lightsOut, lastError = nil, -1, nil, nil
local retries = 0 -- recording attempts made after the first one, see tick()
local showAll, others = false, {} -- admin only: draw every driver's box, the boxes received from the other clients by session ID
local outbox = {} -- events waiting to be sent: a stock server accepts one per 200 ms and the send function answers false when it refuses
local reportEvent, shareEvent -- defined with the other events below
local startNodes -- DEBUG: the track's start nodes, read once per session (drawStartNodes)
local debugEvent -- DEBUG: every client's status snapshots, defined with the other events below
local sessionInfoDue, rec = false, nil -- DEBUG: log the session once its settings are known; the flight recorder (see recorderStart)
local lastLoggedError
local COL_OK, COL_OVER, COL_TXT = rgbm(0.2, 1, 0.4, 1), rgbm(1, 0.15, 0.1, 1), rgbm(1, 1, 1, 1) -- HUD colours; the lines are COL_TXT, always white

local VERSION = 'v1.8'
do -- always, once per load: which script version runs on which CSP build (the first thing to look for in a driver's log)
  local ok, build = pcall(ac.getPatchVersionCode)
  pcall(ac.log, string.format('GridBox %s loaded, CSP build %s', VERSION, ok and tostring(build) or '?'))
end

-- the random delays of the events only spread the clients out if every client draws different numbers (Lua starts with the same seed)
pcall(function() math.randomseed(os.time() + (car.sessionID or 0) * 7919) math.random() math.random() end)

-- DEBUG=1: a line in the CSP log (Documents\Assetto Corsa\logs\custom_shaders_patch.log, wiped whenever the game starts) for every
-- important step, with the session clock in ms so that the logs of several drivers can be merged. A logging mistake (a nil in a
-- format) must never reach the start logic, hence the pcall.
local function dlog(...)
  if not cfg.debug then return end
  local ok, text = pcall(string.format, ...)
  pcall(ac.log, string.format('GridBox: t=%.0f %s', sim.currentSessionTime, ok and text or ('log format error: ' .. tostring(text))))
end

-- the text of f(...) or '?' if it fails: for values that only go into a log line
local function try(f, ...)
  local ok, v = pcall(f, ...)
  return ok and tostring(v) or '?'
end

local clock, dropped, refused = 0, 0, false -- seconds the script has run; events dropped; is the server refusing sends right now
local delayed = {} -- events waiting for their random delay (so that 20 clients do not send at the same instant)

-- jitter: seconds of random delay; optional: debug events, dropped first when the outbox fills up (reports must get through)
local function send(event, data, jitter, optional)
  delayed[#delayed + 1] = { event = event, data = data, due = clock + (jitter and math.random() * jitter or 0), optional = optional }
end

local function flush()
  local k = 1
  while k <= #delayed do
    local item = delayed[k]
    if item.due <= clock then
      table.remove(delayed, k)
      if #outbox >= (item.optional and 10 or 20) then
        dropped = dropped + 1
        dlog('event dropped, %d waiting in the outbox, %d dropped so far', #outbox, dropped)
      else
        outbox[#outbox + 1] = item
      end
    else
      k = k + 1
    end
  end
  local item = outbox[1]
  if not item then return end
  if item.event(item.data) then
    table.remove(outbox, 1)
    refused = false
  elseif not refused then
    refused = true
    dlog('send refused by the server (%d waiting)', #outbox)
  end
end

-- Grid position among the cars that are connected: the game's race position also counts empty entry slots ahead of the car.
local function gridPosition()
  local rank = 1
  for i = 1, sim.carsCount - 1 do
    local other = ac.getCar(i)
    if other and other.isConnected and other.racePosition < car.racePosition then rank = rank + 1 end
  end
  return rank
end

-- the four corners of a line of width t from a to b, ready for render.quad
local function bar(a, b, t)
  local d = b:clone():sub(a)
  d.y = 0
  d:normalize()
  local n = vec3(d.z * t / 2, 0, -d.x * t / 2)
  return { a:clone():add(n), b:clone():add(n), b:clone():sub(n), a:clone():sub(n) }
end

-- Builds the three lines of a box (the front line centred on `line`, facing `fwd`, `length` long, standing on ground about `groundY`
-- high). The lines never move afterwards, so this runs once per box, not per frame. Each corner is put on the VISIBLE road with a ray
-- down onto the track meshes: the physics contact points can sit a little above the road model, which made the lines float.
-- The front line reaches half a line width past the side lines' centres and the side lines half a line width past the front
-- line's centre, so the outer corners are complete squares instead of notched.
local function buildBox(line, fwd, length, groundY)
  local right = vec3(fwd.z, 0, -fwd.x)
  local base = groundY + 1.5
  local function road(p)
    local ok, d = pcall(function() return render.createRay(vec3(p.x, base, p.z), vec3(0, -1, 0), 3):track() end)
    return ((ok and d and d > 0) and base - d or groundY) + 0.01
  end
  local side = right:clone():scale(cfg.boxWidth / 2)
  local rear = line:clone():addScaled(fwd, -length)
  local fl, fr = line:clone():add(side), line:clone():sub(side)
  local rl, rr = rear:clone():add(side), rear:clone():sub(side)
  fl.y, fr.y, rl.y, rr.y = road(fl), road(fr), road(rl), road(rr)
  local ext = cfg.lineWidth / 2
  local alongExt, acrossExt = fwd:clone():scale(ext), right:clone():scale(ext)
  return {
    y = (fl.y + fr.y + rl.y + rr.y) / 4,
    bars = {
      bar(fl:clone():add(acrossExt), fr:clone():sub(acrossExt), cfg.lineWidth),
      bar(fl:clone():add(alongExt), rl, cfg.lineWidth),
      bar(fr:clone():add(alongExt), rr, cfg.lineWidth),
    },
  }
end

-- tells the admins' clients where this car's box is
local function shareBox()
  local g = grid
  send(shareEvent, { pos = g.pos, x = g.line.x, y = g.y, z = g.line.z, fx = g.fwd.x, fz = g.fwd.z, length = g.length }, 2)
end

-- Where the car's axles are: front and rear axle centres, the car's heading, the wheelbase and the ground height under it (the
-- tyres' contact points; wheel centre minus tyre radius if one is missing; the car origin is not at ground level in every car).
local function carGeometry()
  local w = car.wheels
  local front = w[0].position:clone():add(w[1].position):scale(0.5)
  local rear = w[2].position:clone():add(w[3].position):scale(0.5)
  local fwd = front:clone():sub(rear)
  fwd.y = 0
  fwd:normalize()
  local ground = 0
  for k = 0, 3 do
    local cp = w[k].contactPoint
    ground = ground + ((cp and cp:lengthSquared() > 0) and cp.y or (w[k].position.y - (w[k].tyreRadius or 0.3)))
  end
  return { front = front, rear = rear, fwd = fwd, wheelbase = front:distance(rear), ground = ground / 4 }
end

-- The state of a box: the front line's centre, the box centre (what the tyres are measured from) and which way the box faces.
local function newGrid(line, center, fwd, length, groundY, pos)
  local box = buildBox(line, fwd, length, groundY)
  return {
    fwd = fwd, right = vec3(fwd.z, 0, -fwd.x), line = line, center = center,
    lineAhead = line:clone():sub(center):dot(fwd), -- how far the front line is ahead of the box centre
    length = length, y = box.y, bars = box.bars, pos = pos, shown = true,
    over = 0, side = 0, restOver = 0, restSide = 0,
  }
end

-- The track's start slot of this car: the node AC_START_<n> of the track, n = the session's forcedPosition (-1: not assigned).
-- Returns the slot number, the node's position and facing, or nothing if the slot cannot be determined.
local slotWhy = '-' -- DEBUG status: why the last slot lookup found nothing

-- The game puts a start node on a car's PHYSICS origin when it spawns the car (measured with the Tatuus: its model origin, car.position,
-- sits 0.42 m ahead of the node, which is exactly the GRAPHICS_OFFSET z of its car.ini; the front and rear axle then lie 1.70 m ahead of
-- and 1.23 m behind the node, which is (1 - CG_LOCATION) and CG_LOCATION of the wheelbase). car.transform is the physics transform.
local function physicsOrigin() return car.transform and car.transform.position end

-- The start node closest to the car (flat distance): its number, the distance, and how many start nodes the track has.
local function nearestStart(root)
  local count = root:findNodes('AC_START_?'):size()
  local best, bestD
  local o = physicsOrigin() or car.position
  for i = 0, count - 1 do
    local p = root:findNodes('AC_START_' .. i):getPosition()
    local d = p and math.sqrt((p.x - o.x) ^ 2 + (p.z - o.z) ^ 2)
    if d and (not bestD or d < bestD) then best, bestD = i, d end
  end
  return best, bestD, count
end

-- Returns the slot number, the node's position and facing, whether the number was assigned by the server, a note saying how it was
-- found, and the forcedPosition the session reported. atSpawn: this is the automatic recording at the session start, where a car stands
-- on its own slot.
local function slotNode(atSpawn)
  local root = ac.findNodes('sceneRoot:yes')
  local session = ac.getSession(sim.currentSessionIndex)
  local forced = session and session.forcedPosition
  local assigned = forced and forced >= 0
  local why = 'forcedPosition=' .. tostring(forced)
  -- the start node a standing car outside the pit lane stands nearest to (measured: a pickup server leaves forcedPosition at -1)
  local near, nearD, nearWhy
  if cfg.slotRadius <= 0 then nearWhy = 'SLOT_RADIUS_M=0'
  elseif car.speedKmh >= cfg.still then nearWhy = 'car moving'
  elseif car.isInPitlane then nearWhy = 'car in the pit lane'
  else
    near, nearD = nearestStart(root)
    if not near or nearD > cfg.slotRadius then
      nearWhy = string.format('nearest start node %s m away', nearD and string.format('%.1f', nearD) or '-')
      near = nil
    end
  end
  local index, how
  if assigned and near and near ~= forced and atSpawn then
    -- at the session start the car stands on its own slot, so a different number means that forcedPosition does not mean what this
    -- script assumes (never seen in the game): trust the node, and say so in the log
    dlog('forcedPosition %d disagrees with the start node the car stands on, %d (%.2f m away): using the node', forced, near, nearD)
    index, how, assigned = near, string.format('nearest node (forcedPosition %d disagrees)', forced), false
  elseif assigned then
    index, how = forced, 'assigned by the session'
  elseif near then
    index, how = near, 'nearest node'
  else
    slotWhy = why .. ', ' .. nearWhy
    return
  end
  local name = string.format('AC_START_%d', index)
  local node = root:findNodes(name)
  if node:name(1) ~= name then slotWhy = string.format('no node %s (%d found)', name, node:size()) return end
  local pos, look = node:getPosition(), node:getLook()
  if pos and look then slotWhy = '-' return index, pos, look, assigned, how, forced end
  slotWhy = 'node without position'
end

-- The box from the track's start slot (the main way). The game spawns a car with its physics origin on the node, so the front line is
-- the front axle's offset from that origin (measured on this car, wherever it is now) ahead of the node: it works for a car that
-- spun, joined late or reconnected too. Returns nil if the slot cannot be determined.
local function slotBox(atSpawn)
  local ok, index, pos, look, assigned, how, forced = pcall(slotNode, atSpawn)
  if not ok then slotWhy = 'error: ' .. tostring(index) end
  if not ok or not index then return nil end
  local origin = physicsOrigin()
  if not origin then slotWhy = 'no physics transform' return nil end
  local c = carGeometry()
  local fwd = look:clone()
  fwd.y = 0
  fwd:normalize()
  local mid = c.front:clone():add(c.rear):scale(0.5)
  local frontOff = c.front:clone():sub(origin):dot(c.fwd)
  local midOff = mid:clone():sub(origin):dot(c.fwd)
  -- the front line is LINE_FROM_NODE_M ahead of the node (the same for every car model, as the paint is where it is) or, without that
  -- setting, at the front edge of this car's front tyres; LINE_OFFSET_M moves it either way
  local ahead = (cfg.lineFromNode > 0 and cfg.lineFromNode or frontOff + cfg.patch / 2) + cfg.lineOffset
  local g = newGrid(pos:clone():addScaled(fwd, ahead), pos:clone():addScaled(fwd, midOff), fwd,
    c.wheelbase + 1.8, pos.y, index + 1) -- the box is named after its start slot (P1 = AC_START_0): the race position of the cars at the
  -- session start is not the order they stand in (official server 2026-11-24: both cars got P2, the cars stood on slots 0 and 1)
  g.slot, g.ahead, g.how, g.forced = index, ahead, how, forced
  -- how far the box centre from the slot is from where the car really is: about 0 for a car standing on its spawn spot (DEBUG status)
  if car.speedKmh < cfg.still then g.slotErr = math.sqrt((g.center.x - mid.x) ^ 2 + (g.center.z - mid.z) ^ 2) end
  return g
end

-- The fallback: the box from where the car stands. Returns true if it was recorded.
local function carBox()
  if car.speedKmh >= cfg.still then return false end
  if car.isInPitlane then return false end -- a late joiner standing in the pits has no grid slot (and must not get a jump start report)
  local c = carGeometry()
  -- the front line starts at the front edge of the front tyres' contact patches, so the spawn spot itself is on the line
  local line = c.front:clone():addScaled(c.fwd, cfg.lineOffset + cfg.patch / 2)
  grid = newGrid(line, c.front:clone():add(c.rear):scale(0.5), c.fwd, c.wheelbase + 1.8, c.ground, gridPosition())
  return true
end

-- Is the current session one of those RECORD_IN names (PRACTICE, QUALIFY, RACE)?
local function recordsHere()
  local t = sim.raceSessionType
  local name = t == ac.SessionType.Race and 'RACE' or t == ac.SessionType.Practice and 'PRACTICE' or t == ac.SessionType.Qualify and 'QUALIFY'
  return name and cfg.recordIn:find(name, 1, true) ~= nil
end

-- Records this car's box: from the track's start slot, or where the car stands if the slot cannot be determined (forcedPosition -1,
-- no such node, no node API). Returns true if a box was recorded.
local mm = function(v) return math.max(-32000, math.min(32000, math.floor((v or 0) * 1000 + 0.5))) end

-- DEBUG: sends this client's state to everybody; every client with DEBUG=1 logs what arrives (see debugEvent). what: 1 recorded,
-- 2 not recorded, 3 start lights received, 4 jump start, 5 lights out, 6 status on request. Dropped first when the outbox is full.
local function sendDebug(what)
  if not cfg.debug then return end
  pcall(function()
    local g = grid
    local flags = (g and 1 or 0) + (g and g.shown and 2 or 0) + (car.isInPitlane and 4 or 0) + (g and g.armed and 8 or 0)
      + (g and g.jumped and 16 or 0) + (lightsOut and 32 or 0)
    send(debugEvent, { what = what, pos = g and g.pos or 0, slot = g and g.slot or -1, flags = flags, errMm = mm(g and g.slotErr),
      aheadMm = mm(g and g.ahead), overMm = mm(g and g.over), sideMm = mm(g and g.side), restOverMm = mm(g and g.restOver),
      restSideMm = mm(g and g.restSide), speed = math.floor(car.speedKmh * 10), session = sim.raceSessionType,
      toLights = lightsOut and (lightsOut - sim.currentSessionTime) or -1 }, 1.5, true)
  end)
end

local function record(anySession)
  if not anySession and not recordsHere() then return false end -- grid boxes are for the sessions named in RECORD_IN (default: the race)
  local g = cfg.source ~= 'CAR' and slotBox(not anySession)
  if g then
    grid = g
  elseif not carBox() then
    dlog('no box recorded (session type %d, speed %.1f, pit lane %s, manual %s): %s', sim.raceSessionType, car.speedKmh,
      tostring(car.isInPitlane), tostring(anySession == true), slotWhy)
    sendDebug(2)
    return false
  end
  lightsOut = nil
  shareBox()
  dlog('recorded P%d from=%s (%s) forcedPosition=%s car=%s session type %d manual=%s slotErr=%s line-offset=%+.2f m line-from-node=%s, front line at x=%.2f z=%.2f, facing x=%.3f z=%.3f',
    grid.pos, grid.slot and ('slot ' .. grid.slot) or 'car', tostring(grid.how or 'from where the car stands'), tostring(grid.forced),
    try(ac.getCarID, 0), sim.raceSessionType, tostring(anySession == true), grid.slotErr and string.format('%.2f', grid.slotErr) or '-',
    cfg.lineOffset, grid.ahead and string.format('%.2f m', grid.ahead) or '-', grid.line.x, grid.line.z, grid.fwd.x, grid.fwd.z)
  sendDebug(1)
  return true
end

-- How far the car is outside its box, in metres (> 0: outside): `over` is how far the front edge of the most forward front tyre's
-- contact patch is past the outer edge of the front line, `side` how far the outermost edge of any of the four patches is past the
-- outer edge of a side line. The patch is a rectangle turned with the car, so a car standing sideways sticks out further.
-- Plain numbers only (everything is horizontal): this runs every frame.
local function measure()
  local w, g = car.wheels, grid
  local half = cfg.lineWidth / 2
  local hx = w[0].position.x + w[1].position.x - w[2].position.x - w[3].position.x
  local hz = w[0].position.z + w[1].position.z - w[2].position.z - w[3].position.z
  local len = math.sqrt(hx * hx + hz * hz)
  hx, hz = hx / len, hz / len
  local c = math.abs(hx * g.fwd.x + hz * g.fwd.z)
  local s = math.abs(hx * g.right.x + hz * g.right.z)
  local over, side = -1e9, -1e9
  for k = 0, 3 do
    local p = w[k].position
    local dx, dz = p.x - g.center.x, p.z - g.center.z
    local tw = (w[k].tyreWidth or 0.25) / 2
    if k < 2 then over = math.max(over, dx * g.fwd.x + dz * g.fwd.z - g.lineAhead + cfg.patch / 2 * c + tw * s) end
    side = math.max(side, math.abs(dx * g.right.x + dz * g.right.z) + tw * c + cfg.patch / 2 * s - cfg.boxWidth / 2)
  end
  return over - half, side - half
end

-- Reports travel as a hidden event (not chat text) from the driver's client to all clients; an admin's client writes them to a file.
-- kind: 0 outside at lights out, 2 jump start (ms = how early the car moved)
local function report(kind, ms)
  local over, side = math.max(0, grid.restOver), math.max(0, grid.restSide)
  dlog('report kind %d: P%d over=%.3f side=%.3f ms=%.0f', kind, grid.pos, over, side, ms or 0)
  -- the event fields are 16 bit numbers: clamp, or a distance above 32.7 m (NEAR_M set high) would wrap to a negative value
  send(reportEvent, { pos = grid.pos, kind = kind, over = math.min(32000, math.floor(over * 1000 + 0.5)),
    side = math.min(32000, math.floor(side * 1000 + 0.5)), ms = math.min(32000, math.floor(ms or 0)) })
end

local function stamp()
  local ok, text = pcall(os.date, '%H:%M:%S')
  return ok and text or string.format('%.0f s', sim.currentSessionTime / 1000)
end

local counts = {}
-- Appends a line to the admin's report file: ac.storage keeps string keys in an INI under Documents\Assetto Corsa\cfg\extension\
-- state\lua\ (scripts have no other way to write files). Keys report_000 .. report_999 are reused in a ring, `reports` is the total.
-- DEBUG lines go to their own ring (debug_000 .. debug_999, total `debugs`), so that the report count stays the number of reports.
local function logLine(text, name)
  name = name or 'report'
  local total = name .. 's'
  if not counts[name] then
    ac.storageSetPath('gridbox')
    counts[name] = tonumber(ac.storage[total]) or 0
  end
  counts[name] = counts[name] + 1
  ac.storage[string.format('%s_%03d', name, counts[name] % 1000)] = text
  ac.storage[total] = tostring(counts[name])
end

-- DEBUG recorder ---------------------------------------------------------------------------------------------------------
-- What a test needs to be understood from the log of the admin's PC alone: who was in the session, which box each car had, how
-- every car moved around the lights-out, and where every tyre was at the lights-out. Nothing here runs without DEBUG=1, and it
-- is all wrapped in pcall so that it can not break the start logic.
local function carName(i, c)
  local ok, name = pcall(function() return c:driverName() end)
  if not (ok and name) then ok, name = pcall(ac.getDriverName, i) end
  return ok and tostring(name) or '?'
end

local function loadStartNodes()
  if startNodes then return startNodes end
  startNodes = {}
  pcall(function()
    local root = ac.findNodes('sceneRoot:yes')
    for i = 0, root:findNodes('AC_START_?'):size() - 1 do
      local node = root:findNodes('AC_START_' .. i)
      startNodes[#startNodes + 1] = { name = 'AC_START_' .. i, pos = node:getPosition():clone(), look = node:getLook():clone() }
    end
  end)
  return startNodes
end

-- every connected car: index, session ID, driver, model, race position
local function logCars(label)
  for i = 0, sim.carsCount - 1 do
    local c = ac.getCar(i)
    if c and c.isConnected then
      dlog('%s: car [%d] sid=%s %s model=%s race position %s, pit lane %s', label, i, tostring(c.sessionID), carName(i, c),
        try(ac.getCarID, i), tostring(c.racePosition), tostring(c.isInPitlane))
    end
  end
end

local nodesLogged = false
local function logSessionInfo()
  local s = ac.getSession(sim.currentSessionIndex)
  dlog('session: index %d type %d forcedPosition %s, %d cars, track %s, own car %s; settings source=%s record_in=%s style=%s line-from-node=%.2f line-offset=%.2f slot-radius=%.1f',
    sim.currentSessionIndex, sim.raceSessionType, tostring(s and s.forcedPosition), sim.carsCount, try(ac.getTrackID), try(ac.getCarID, 0),
    cfg.source, cfg.recordIn, cfg.style, cfg.lineFromNode, cfg.lineOffset, cfg.slotRadius)
  logCars('car list')
  if not nodesLogged then
    nodesLogged = true
    for _, n in ipairs(loadStartNodes()) do
      dlog('start node %s at x=%.3f y=%.3f z=%.3f facing x=%.3f z=%.3f', n.name, n.pos.x, n.pos.y, n.pos.z, n.look.x, n.look.z)
    end
  end
end

-- how many of the other connected cars have shared their box with this (admin) client
local function logBoxesKnown()
  local known, connected = 0, 0
  for i = 1, sim.carsCount - 1 do
    local c = ac.getCar(i)
    if c and c.isConnected then
      connected = connected + 1
      if others[c.sessionID] then known = known + 1 end
    end
  end
  dlog('boxes known: own box %s, %d of %d other connected cars shared theirs (admin %s)', grid and 'yes' or 'no', known, connected, tostring(sim.isAdmin))
end

-- every connected car at the lights-out: its tyres' positions (front left, front right, rear left, rear right) and its box, enough to
-- work out later who was outside and who was moving, without trusting any driver's own report. Remote cars move at network rate.
local function snapshotCars()
  logBoxesKnown()
  for i = 0, sim.carsCount - 1 do
    local c = ac.getCar(i)
    if c and c.isConnected then
      local wheels = ''
      pcall(function()
        for k = 0, 3 do wheels = wheels .. string.format(' (%.2f,%.2f)', c.wheels[k].position.x, c.wheels[k].position.z) end
      end)
      local b = (i == 0) and grid or others[c.sessionID]
      local box = b and string.format('box P%d line=(%.2f,%.2f) face=(%.3f,%.3f) len=%.2f', b.pos, b.line.x, b.line.z, b.fwd.x, b.fwd.z, b.length)
        or 'box unknown'
      dlog('lights-out snapshot: car [%d] sid=%s %s model=%s v=%.1f km/h ping=%s pit=%s origin=(%.2f,%.2f) look=(%.3f,%.3f) wheels%s %s', i,
        tostring(c.sessionID), carName(i, c), try(ac.getCarID, i), c.speedKmh, tostring(c.ping), tostring(c.isInPitlane), c.position.x, c.position.z,
        c.look.x, c.look.z, wheels, box)
    end
  end
end

-- The flight recorder: from the Start Lights message to 3 s after the lights go out (at most 30 s of waiting are recorded, an F1-style
-- first message has a delay of hours), four times a second: every connected car's speed, plus the moment each car first moves.
local function recorderStart()
  local now = sim.currentSessionTime
  rec = { lightsAt = lightsOut, untilT = math.min(lightsOut, now + 30000) + 3000, nextT = now, moved = {}, snap = false }
end

local function recorderTick()
  if not rec then return end
  local now = sim.currentSessionTime
  if now > rec.untilT then rec = nil return end
  if now >= rec.lightsAt and not rec.snap then
    rec.snap = true
    snapshotCars()
  end
  if now < rec.nextT then return end
  rec.nextT = now + 250
  local speeds = {}
  for i = 0, sim.carsCount - 1 do
    local c = ac.getCar(i)
    if c and c.isConnected then
      speeds[#speeds + 1] = string.format('%d:%.1f', i, c.speedKmh)
      if not rec.moved[i] and c.speedKmh >= cfg.jump then
        rec.moved[i] = true
        dlog('car [%d] %s moved first at %+.0f ms from the lights-out (speed %.1f km/h)', i, carName(i, c), now - rec.lightsAt, c.speedKmh)
      end
    end
  end
  dlog('flight recorder %+.2f s from the lights-out; speeds km/h by car index %s; own box over=%.3f side=%.3f', (now - rec.lightsAt) / 1000,
    table.concat(speeds, ' '), grid and grid.over or 0, grid and grid.side or 0)
end

-- With the lines hidden (STYLE=TEXT) the drivers go by the track's own painted boxes, so nothing is checked, shown or reported.
local function checking() return cfg.style ~= 'TEXT' end
local function outside() return checking() and (grid.over > cfg.tolerance or grid.side > cfg.tolerance) end

local function tick(dt)
  clock = clock + dt
  flush()
  if settle > 0 then
    settle = settle - dt
    if settle <= 0 then
      if sessionInfoDue then -- the session start callback still sees the previous session, so the session is logged now
        sessionInfoDue = false
        if cfg.debug then pcall(logSessionInfo) end
      end
      if not record(false) and car.speedKmh >= cfg.still and retries < 6 then
        -- the car was still moving (for example creeping): try again every 0.5 s for a few seconds instead of giving up for the session
        retries, settle = retries + 1, 0.5
      end
    end
  end
  if cfg.debug then pcall(recorderTick) end
  if not grid then return end
  grid.over, grid.side = measure()
  local still = car.speedKmh < cfg.still
  local near = grid.center:distance(car.position) < cfg.near
  if not near then
    grid.restOver, grid.restSide = 0, 0
  elseif still then
    grid.restOver, grid.restSide = grid.over, grid.side
  end

  -- jump start: a car that stood in its box after the lights were started and is MOVING at the moment they go out. Moving in
  -- between and stopping again (repositioning) is legal, so nothing is judged until the lights-out; moveFrom is when it began to move.
  if lightsOut and cfg.jumpReport then
    if car.speedKmh < cfg.jump then
      grid.moveFrom = nil
      if near then grid.armed = true end
    elseif not grid.moveFrom then
      grid.moveFrom = sim.currentSessionTime
    end
  end

  if lightsOut and sim.currentSessionTime >= lightsOut then
    local out = lightsOut
    lightsOut = nil
    dlog('lights out: box shown=%s speed=%.1f, measured at rest over=%.3f side=%.3f, now over=%.3f side=%.3f', tostring(grid.shown),
      car.speedKmh, grid.restOver, grid.restSide, grid.over, grid.side)
    if cfg.jumpReport and grid.armed and not grid.jumped and car.speedKmh >= cfg.jump then
      grid.jumped = true
      report(2, out - (grid.moveFrom or out))
      sendDebug(4)
    end
    if grid.shown then
      if cfg.finalReport and checking() and (grid.restOver > cfg.tolerance or grid.restSide > cfg.tolerance) then report(0) end
      grid.shown = false
    end
    sendDebug(5)
  end
end

local function status()
  return string.format('GridBox debug: session=%d speed=%.0f settle=%.1f box=%s from=%s slotErr=%s shown=%s over=%s side=%s lights-out in %s s err=%s',
    sim.raceSessionType, car.speedKmh, settle, grid and 'yes' or 'no', grid and (grid.slot and ('slot ' .. grid.slot) or 'car') or '-',
    grid and grid.slotErr and string.format('%.2f', grid.slotErr) or '-', tostring(grid and grid.shown),
    grid and string.format('%.3f', grid.over) or '-', grid and string.format('%.3f', grid.side) or '-',
    lightsOut and string.format('%.1f', (lightsOut - sim.currentSessionTime) / 1000) or '-', tostring(lastError))
end

-- second debug line (the first one is already as wide as the window): why the slot was not used, how many start nodes the track
-- has and which one is nearest to the car right now
local function slotStatus()
  local ok, text = pcall(function()
    -- from the nodes read once per session: a scene search per start node, twice per frame, made the game run badly with DEBUG=1
    local nodes, o, best, dist = loadStartNodes(), physicsOrigin() or car.position, nil, nil
    for i, nd in ipairs(nodes) do
      local d = math.sqrt((nd.pos.x - o.x) ^ 2 + (nd.pos.z - o.z) ^ 2)
      if not dist or d < dist then best, dist = i - 1, d end
    end
    return string.format('start nodes=%d nearest=%s (%.2f m)', #nodes, tostring(best), dist or -1)
  end)
  return string.format('why-not-slot=%s  %s  line-offset=%+.2f m  line-from-node=%s', slotWhy,
    ok and text or ('start nodes: error ' .. tostring(text)), cfg.lineOffset, grid and grid.ahead and string.format('%.2f m', grid.ahead) or '-')
end

function script.update(dt)
  local ok, err = pcall(tick, dt)
  if not ok then lastError = tostring(err) end
  if lastError ~= lastLoggedError then -- always, not only with DEBUG: a script that fails silently is the worst case
    lastLoggedError = lastError
    pcall(ac.log, string.format('GridBox: t=%.0f error: %s', sim.currentSessionTime, tostring(lastError)))
    ac.debug('gridbox error', lastError)
  end
end

-- 3D boxes ---------------------------------------------------------------------------------------------------------
-- one box: its lines (not with STYLE=TEXT) and a label. `own` boxes say YOUR BOX, with STYLE=TEXT only the position text is drawn.
local function drawBox(bars, labelAt, text)
  if cfg.style ~= 'TEXT' then
    for _, q in ipairs(bars) do render.quad(q[1], q[2], q[3], q[4], COL_TXT) end
  end
  render.debugText(labelAt, text, COL_TXT, cfg.style == 'TEXT' and 3 or 1.6)
end

-- DEBUG + SHOW_START_NODES=1: every start node of the track within 40 m of the car (a yellow cross, its facing and its name), to
-- compare them with the painted boxes of the track. Read once per session.
local COL_NODE = rgbm(1, 0.8, 0, 1)
local function drawStartNodes()
  for _, n in ipairs(loadStartNodes()) do
    if math.abs(n.pos.x - car.position.x) < 40 and math.abs(n.pos.z - car.position.z) < 40 then
      local at = vec3(n.pos.x, n.pos.y + 0.05, n.pos.z)
      render.debugCross(at, 0.4, COL_NODE)
      render.debugArrow(at, at:clone():addScaled(n.look, 2), 0.1, COL_NODE)
      render.debugText(vec3(n.pos.x, n.pos.y + 0.6, n.pos.z), n.name, COL_NODE, 1)
    end
  end
end

local function drawWorld()
  if cfg.debug and cfg.showNodes then drawStartNodes() end
  local g = grid
  local own = g and (g.shown or showAll) -- the admin's "show all" includes the admin's own box even after the lights went out
  if not own and not (showAll and next(others)) then return end
  render.setBlendMode(render.BlendMode.AlphaBlend)
  render.setDepthMode(render.DepthMode.ReadOnly)
  if own then
    if cfg.style == 'TEXT' then
      drawBox(g.bars, vec3(g.line.x, g.y + 1.4, g.line.z), string.format('P%d', g.pos))
    else
      drawBox(g.bars, vec3(g.center.x, g.y + 1.6, g.center.z), string.format('P%d  YOUR BOX', g.pos))
    end
  end
  if showAll then
    for _, o in pairs(others) do
      local at = cfg.style == 'TEXT' and o.line or o.mid
      drawBox(o.bars, vec3(at.x, o.y + (cfg.style == 'TEXT' and 1.4 or 1.6), at.z), string.format('P%d  %s', o.pos, o.name))
    end
  end
end
render.on('main.track.transparent', drawWorld)

-- HUD line -------------------------------------------------------------------------------------------------------
function script.drawUI()
  if cfg.debug then
    ui.transparentWindow('GridBoxDebug', vec2(20, 60), vec2(760, 50), true, false, function()
      ui.textColored(status(), COL_TXT)
      ui.textColored(slotStatus(), COL_TXT)
    end)
  end
  if not grid or not grid.shown then return end
  local dist = grid.center:distance(car.position)
  local text, col
  if dist > 30 then
    text, col = string.format('Grid P%d  -  %d m to your box', grid.pos, math.floor(dist)), COL_TXT
  elseif not checking() then
    return
  elseif grid.over > cfg.tolerance then
    text, col = string.format('OVER THE LINE  +%.2f m', grid.over), COL_OVER
  elseif grid.side > cfg.tolerance then
    text, col = string.format('OUTSIDE THE BOX  +%.2f m', grid.side), COL_OVER
  else
    text, col = string.format('Grid P%d  -  %.2f m to the line', grid.pos, math.max(0, -grid.over)), COL_OK
  end
  local width = sim.windowWidth / ac.getUI().uiScale
  ui.transparentWindow('GridBoxHud', vec2(width / 2 - 160, 90), vec2(320, 40), true, false, function()
    ui.textColored(text, col)
  end)
end

-- events, session hooks, admin buttons ---------------------------------------------------------------------------
-- admin commands, sent to every client: 1 record the boxes again, 2 show the remembered boxes again, 3 hide them,
-- 4 switch between lines + text and text only, 5 send your box to the admins again, 6 (DEBUG) send your status to everybody's log
local commandEvent = ac.OnlineEvent({
  key = ac.StructItem.key('GridBoxRecord'),
  cmd = ac.StructItem.int16(),
}, function(sender, message)
  dlog('admin command %d from car %s', message.cmd, tostring(sender and sender.index))
  if message.cmd == 1 then
    record(true)
  elseif message.cmd == 4 then
    cfg.style = cfg.style == 'TEXT' and 'BOX' or 'TEXT'
  elseif message.cmd == 6 then
    sendDebug(6)
  elseif grid and message.cmd == 2 then
    grid.shown, lightsOut = true, nil
  elseif grid and message.cmd == 3 then
    grid.shown = false
  elseif grid and message.cmd == 5 then
    shareBox()
  end
end, ac.SharedNamespace.ServerScript)

-- Listens to the event startLights.lua sends when its lights are started (same key and layout, so both scripts receive it).
-- The lights go out at startTime + delayTime on the session clock; the latest message wins (F1-style starts send a second one).
ac.OnlineEvent({
  key = ac.StructItem.key('Start Lights'),
  startTime = ac.StructItem.float(),
  delayTime = ac.StructItem.float(),
}, function(sender, message)
  local pending = lightsOut ~= nil
  lightsOut = message.startTime + message.delayTime
  dlog('start lights event from car %s: startTime=%.0f delayTime=%.0f, lights out in %.0f ms', tostring(sender and sender.index),
    message.startTime, message.delayTime, lightsOut - sim.currentSessionTime)
  -- a new start begins afresh; a second message while the lights are pending (the release of an F1-style hold) keeps what the car did
  if grid and not pending then grid.armed, grid.jumped, grid.moveFrom = false, false, nil end
  if cfg.debug then
    pcall(function()
      recorderStart()
      logCars('at start lights')
      logBoxesKnown()
    end)
    sendDebug(3)
  end
end, ac.SharedNamespace.ServerScript)

-- The reports: only the clients of signed-in admins write them down (to the file via ac.storage); everybody else ignores them.
reportEvent = ac.OnlineEvent({
  key = ac.StructItem.key('GridBoxReport'),
  pos = ac.StructItem.int16(),
  kind = ac.StructItem.int16(),
  over = ac.StructItem.int16(),
  side = ac.StructItem.int16(),
  ms = ac.StructItem.int16(),
}, function(sender, m)
  dlog('report received from car %s sid %s %s: P%d kind %d over=%d side=%d ms=%d mm (%s)', tostring(sender and sender.index),
    tostring(sender and sender.sessionID), sender and carName(sender.index, sender) or '?', m.pos, m.kind, m.over, m.side, m.ms,
    (sim.isAdmin and sender) and 'written to the report file' or 'ignored: not an admin')
  if not sim.isAdmin or not sender then return end
  local what
  if m.kind == 2 then
    -- 32000 is the clamp: with F1_STYLE starts the lights-out time is unknown until an admin presses "Start Lights Out" (the first
    -- message carries a delay of about 27 hours), so there is no meaningful number of milliseconds
    what = m.ms >= 32000 and 'JUMP START, moved before the lights went out' or
      string.format('JUMP START, moved %d ms before the lights went out', m.ms)
  else
    local parts = {}
    if m.over > 0 then parts[#parts + 1] = string.format('%.2f m over the line', m.over / 1000) end
    if m.side > 0 then parts[#parts + 1] = string.format('%.2f m outside the box', m.side / 1000) end
    what = table.concat(parts, ' and ') .. ' at lights out'
  end
  logLine(string.format('%s  %s  grid P%d  %s', stamp(), sender:driverName(), m.pos, what))
end, ac.SharedNamespace.ServerScript)

-- The boxes of the other drivers: where each front line is, which way it faces and how long the box is. Kept by the clients of
-- signed-in admins only, drawn when "Grid: show all boxes" is on. The own car's message arrives here too and is skipped.
shareEvent = ac.OnlineEvent({
  key = ac.StructItem.key('GridBoxShare'),
  pos = ac.StructItem.int16(),
  x = ac.StructItem.float(), y = ac.StructItem.float(), z = ac.StructItem.float(),
  fx = ac.StructItem.float(), fz = ac.StructItem.float(),
  length = ac.StructItem.float(),
}, function(sender, m)
  dlog('box shared by car %s sid %s %s: P%d line=(%.2f,%.2f) facing=(%.3f,%.3f) length=%.2f (%s)', tostring(sender and sender.index),
    tostring(sender and sender.sessionID), sender and carName(sender.index, sender) or '?', m.pos, m.x, m.z, m.fx, m.fz, m.length,
    (sim.isAdmin and sender and sender.index ~= 0) and 'kept' or 'ignored: not an admin, or the own box')
  if not sim.isAdmin or not sender or sender.index == 0 then return end
  local fwd, line = vec3(m.fx, 0, m.fz), vec3(m.x, m.y, m.z)
  local box = buildBox(line, fwd, m.length, m.y)
  others[sender.sessionID] = { bars = box.bars, y = box.y, line = line, mid = line:clone():addScaled(fwd, -m.length / 2),
    pos = m.pos, name = sender:driverName(), fwd = fwd, length = m.length }
end, ac.SharedNamespace.ServerScript)

-- DEBUG: the status snapshots of every client (sent by sendDebug), logged by every client with DEBUG=1 and kept by admins in the
-- report file too, so a start can be reconstructed from the admin's PC even when the drivers' own logs are not at hand.
local WHAT = { 'recorded', 'not recorded', 'start lights received', 'jump start', 'lights out', 'status on request' }
debugEvent = ac.OnlineEvent({
  key = ac.StructItem.key('GridBoxDebug'),
  what = ac.StructItem.int16(), pos = ac.StructItem.int16(), slot = ac.StructItem.int16(), flags = ac.StructItem.int16(),
  errMm = ac.StructItem.int16(), aheadMm = ac.StructItem.int16(), overMm = ac.StructItem.int16(), sideMm = ac.StructItem.int16(),
  restOverMm = ac.StructItem.int16(), restSideMm = ac.StructItem.int16(), speed = ac.StructItem.int16(), session = ac.StructItem.int16(),
  toLights = ac.StructItem.float(),
}, function(sender, m)
  if not cfg.debug then return end
  pcall(function()
    local text = string.format('driver %s (car %s, sid %s, %s) %s: P%d slot %d box=%s shown=%s pit=%s armed=%s jumped=%s lights-out-pending=%s slotErr=%d mm line-from-node=%d mm over=%d side=%d mm, at rest over=%d side=%d mm, speed %.1f km/h, session type %d, %.0f ms to lights out',
      sender and carName(sender.index, sender) or '?', tostring(sender and sender.index), tostring(sender and sender.sessionID),
      sender and try(ac.getCarID, sender.index) or '?', WHAT[m.what] or tostring(m.what), m.pos, m.slot, tostring(m.flags % 2 == 1),
      tostring(math.floor(m.flags / 2) % 2 == 1), tostring(math.floor(m.flags / 4) % 2 == 1), tostring(math.floor(m.flags / 8) % 2 == 1),
      tostring(math.floor(m.flags / 16) % 2 == 1), tostring(math.floor(m.flags / 32) % 2 == 1), m.errMm, m.aheadMm, m.overMm, m.sideMm,
      m.restOverMm, m.restSideMm, m.speed / 10, m.session, m.toLights)
    dlog('%s', text)
    if sim.isAdmin then logLine(string.format('%s  t=%.0f  %s', stamp(), sim.currentSessionTime, text), 'debug') end
  end)
end, ac.SharedNamespace.ServerScript)

ac.onSessionStart(function()
  grid, others, startNodes, rec = nil, {}, nil, nil
  settle, retries, sessionInfoDue = cfg.settle, 0, true
  dlog('session start callback (it still shows the previous session): index %d, type %d, forcedPosition %s', sim.currentSessionIndex,
    sim.raceSessionType, tostring((ac.getSession(sim.currentSessionIndex) or {}).forcedPosition))
end)

ac.onOnlineWelcome(function(message, config)
  cfg.source = config:get('GRIDBOX', 'SOURCE', cfg.source):upper()
  -- RECORD_IN=PRACTICE,RACE is a list for CSP: get() returns the first item only, the others come with the offset argument (measured
  -- in the game: v1.5 read just "PRACTICE" from this line)
  local sessions = {}
  for i = 1, 5 do
    local item = config:get('GRIDBOX', 'RECORD_IN', '', i)
    if item ~= '' then sessions[#sessions + 1] = item end
  end
  if #sessions > 0 then cfg.recordIn = table.concat(sessions, ','):upper() end
  cfg.slotRadius = config:get('GRIDBOX', 'SLOT_RADIUS_M', cfg.slotRadius)
  cfg.style = config:get('GRIDBOX', 'STYLE', cfg.style):upper()
  cfg.settle = config:get('GRIDBOX', 'SETTLE_SECONDS', cfg.settle)
  cfg.still = config:get('GRIDBOX', 'STILL_KMH', cfg.still)
  cfg.near = config:get('GRIDBOX', 'NEAR_M', cfg.near)
  cfg.lineFromNode = config:get('GRIDBOX', 'LINE_FROM_NODE_M', cfg.lineFromNode)
  cfg.lineOffset = config:get('GRIDBOX', 'LINE_OFFSET_M', cfg.lineOffset)
  cfg.lineWidth = config:get('GRIDBOX', 'LINE_WIDTH_M', cfg.lineWidth)
  cfg.patch = config:get('GRIDBOX', 'PATCH_M', cfg.patch)
  cfg.tolerance = config:get('GRIDBOX', 'TOLERANCE_M', cfg.tolerance)
  cfg.boxWidth = config:get('GRIDBOX', 'BOX_WIDTH_M', cfg.boxWidth)
  cfg.finalReport = config:get('GRIDBOX', 'FINAL_REPORT', 1) == 1
  cfg.jumpReport = config:get('GRIDBOX', 'JUMP_REPORT', 1) == 1
  cfg.jump = config:get('GRIDBOX', 'JUMP_KMH', cfg.jump)
  cfg.debug = config:get('GRIDBOX', 'DEBUG', 0) == 1
  cfg.showNodes = config:get('GRIDBOX', 'SHOW_START_NODES', 0) == 1
  cfg.extraTools = config:get('GRIDBOX', 'EXTRA_TOOLS', 0) == 1
  -- always: proves that this client received the server's settings (without this line in a driver's log the welcome message did
  -- not arrive, for example because of the CSP new-menu bug) and which ones
  pcall(ac.log, string.format('GridBox %s: welcome received, DEBUG=%s source=%s record_in=%s style=%s line-from-node=%.2f line-offset=%.2f slot-radius=%.1f final-report=%s jump-report=%s',
    VERSION, tostring(cfg.debug), cfg.source, cfg.recordIn, cfg.style, cfg.lineFromNode, cfg.lineOffset, cfg.slotRadius,
    tostring(cfg.finalReport), tostring(cfg.jumpReport)))
  if cfg.debug then ac.setMessage('GridBox', 'script loaded') end
  if not grid then settle, retries = cfg.settle, 0 end
  local function admin(title, action)
    ui.registerOnlineExtra(ui.Icons.Pitlane, title, function() return true end, nil, action, ui.OnlineExtraFlags.Admin)
  end
  admin('Grid: re-record boxes', function() commandEvent({ cmd = 1 }) end)
  admin('Grid: show boxes', function() commandEvent({ cmd = 2 }) end)
  admin('Grid: hide boxes', function() commandEvent({ cmd = 3 }) end)
  -- only for this admin: show every driver's box; switching it on asks everybody to send their box again
  admin('Grid: show all boxes', function()
    showAll = not showAll
    if showAll then
      others = {}
      commandEvent({ cmd = 5 })
    end
  end)
  if cfg.extraTools then admin('Grid: toggle lines', function() commandEvent({ cmd = 4 }) end) end
  if cfg.debug and cfg.extraTools then
    -- tuning against painted lines: move the front line by 5 cm and record the own box again (this client only); the offset to put
    -- in LINE_OFFSET_M is shown as line-offset in the debug status
    local function nudge(d) cfg.lineOffset = cfg.lineOffset + d record(true) end
    admin('Grid debug: front line 5 cm forward', function() nudge(0.05) end)
    admin('Grid debug: front line 5 cm back', function() nudge(-0.05) end)
    admin('Grid debug: ask everyone for a status', function() commandEvent({ cmd = 6 }) end)
    -- test aid when a test driver cannot drive to the grid: put the own car on a start slot. The game's START spawn set puts every car
    -- on the same slot in a practice session (official server 2026-11-24), so each car gets the node of its own session ID instead.
    admin('Grid debug: teleport my car to the start grid', function()
      local nodes = loadStartNodes()
      local node = nodes[(car.sessionID % math.max(1, #nodes)) + 1]
      if node then physics.setCarPosition(0, node.pos, node.look) else physics.teleportCarTo(0, ac.SpawnSet.Start) end
      dlog('teleported the own car to the start grid: %s', node and node.name or 'the START spawn set (no start nodes)')
    end)
  end
end)
