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
  style = 'BOX',     -- BOX: lines + position text, TEXT: only the position text (the track's own painted boxes stay the reference)
  settle = 1.5,      -- s after a session starts before the box is recorded (cars must be standing still by then)
  still = 3,         -- km/h under which the car counts as standing still
  near = 20,         -- m from its box within which a standing car is checked
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
}
local grid, settle, lightsOut, lastError = nil, -1, nil, nil
local retries = 0 -- recording attempts made after the first one, see tick()
local showAll, others = false, {} -- admin only: draw every driver's box, the boxes received from the other clients by session ID
local outbox = {} -- events waiting to be sent: a stock server accepts one per 200 ms and the send function answers false when it refuses
local reportEvent, shareEvent -- defined with the other events below
local COL_OK, COL_OVER, COL_TXT = rgbm(0.2, 1, 0.4, 1), rgbm(1, 0.15, 0.1, 1), rgbm(1, 1, 1, 1) -- HUD colours; the lines are COL_TXT, always white

local function send(event, data)
  if #outbox < 20 then outbox[#outbox + 1] = { event = event, data = data } end
end

local function flush()
  local item = outbox[1]
  if item and item.event(item.data) then table.remove(outbox, 1) end
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
  send(shareEvent, { pos = g.pos, x = g.line.x, y = g.y, z = g.line.z, fx = g.fwd.x, fz = g.fwd.z, length = g.length })
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

local function slotNode()
  local session = ac.getSession(sim.currentSessionIndex)
  local index = session and session.forcedPosition
  local assigned = true
  if not index or index < 0 then
    assigned = false
    -- no slot assigned (measured: a pickup server leaves forcedPosition at -1): a standing car takes the start node it stands nearest to
    local why = 'forcedPosition=' .. tostring(index)
    if cfg.slotRadius <= 0 then slotWhy = why return end
    if car.speedKmh >= cfg.still then slotWhy = why .. ', car moving' return end
    if car.isInPitlane then slotWhy = why .. ', car in the pit lane' return end
    local best, dist = nearestStart(ac.findNodes('sceneRoot:yes'))
    if not best or dist > cfg.slotRadius then
      slotWhy = string.format('%s, nearest start node %s m away', why, dist and string.format('%.1f', dist) or '-')
      return
    end
    index = best
  end
  local name = string.format('AC_START_%d', index)
  local node = ac.findNodes('sceneRoot:yes'):findNodes(name)
  if node:name(1) ~= name then slotWhy = string.format('no node %s (%d found)', name, node:size()) return end
  local pos, look = node:getPosition(), node:getLook()
  if pos and look then slotWhy = '-' return index, pos, look, assigned end
  slotWhy = 'node without position'
end

-- The box from the track's start slot (the main way). The game spawns a car with its physics origin on the node, so the front line is
-- the front axle's offset from that origin (measured on this car, wherever it is now) ahead of the node: it works for a car that
-- spun, joined late or reconnected too. Returns nil if the slot cannot be determined.
local function slotBox()
  local ok, index, pos, look, assigned = pcall(slotNode)
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
  local g = newGrid(pos:clone():addScaled(fwd, frontOff + cfg.lineOffset + cfg.patch / 2), pos:clone():addScaled(fwd, midOff), fwd,
    c.wheelbase + 1.8, pos.y, assigned and index + 1 or gridPosition()) -- an assigned slot names the position, a nearest node does not (empty entries count)
  g.slot = index
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

-- Records this car's box: from the track's start slot, or where the car stands if the slot cannot be determined (forcedPosition -1,
-- no such node, no node API). Returns true if a box was recorded.
local function record(anySession)
  if not anySession and sim.raceSessionType ~= ac.SessionType.Race then return false end -- grid boxes are for the race start only
  local g = cfg.source ~= 'CAR' and slotBox()
  if g then
    grid = g
  elseif not carBox() then
    return false
  end
  lightsOut = nil
  shareBox()
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
  -- the event fields are 16 bit numbers: clamp, or a distance above 32.7 m (NEAR_M set high) would wrap to a negative value
  send(reportEvent, { pos = grid.pos, kind = kind, over = math.min(32000, math.floor(over * 1000 + 0.5)),
    side = math.min(32000, math.floor(side * 1000 + 0.5)), ms = math.min(32000, math.floor(ms or 0)) })
end

local function stamp()
  local ok, text = pcall(os.date, '%H:%M:%S')
  return ok and text or string.format('%.0f s', sim.currentSessionTime / 1000)
end

local reportCount
-- Appends a line to the admin's report file: ac.storage keeps string keys in an INI under Documents\Assetto Corsa\cfg\extension\
-- state\lua\ (scripts have no other way to write files). Keys report_000 .. report_999 are reused in a ring, `reports` is the total.
local function logLine(text)
  if not reportCount then
    ac.storageSetPath('gridbox')
    reportCount = tonumber(ac.storage.reports) or 0
  end
  reportCount = reportCount + 1
  ac.storage[string.format('report_%03d', reportCount % 1000)] = text
  ac.storage.reports = tostring(reportCount)
end

-- With the lines hidden (STYLE=TEXT) the drivers go by the track's own painted boxes, so nothing is checked, shown or reported.
local function checking() return cfg.style ~= 'TEXT' end
local function outside() return checking() and (grid.over > cfg.tolerance or grid.side > cfg.tolerance) end

local function tick(dt)
  flush()
  if settle > 0 then
    settle = settle - dt
    if settle <= 0 and not record(false) and car.speedKmh >= cfg.still and retries < 6 then
      -- the car was still moving (for example creeping): try again every 0.5 s for a few seconds instead of giving up for the session
      retries, settle = retries + 1, 0.5
    end
  end
  if not grid then return end
  grid.over, grid.side = measure()
  local still = car.speedKmh < cfg.still
  local near = grid.center:distance(car.position) < cfg.near
  if not near then
    grid.restOver, grid.restSide = 0, 0
  elseif still then
    grid.restOver, grid.restSide = grid.over, grid.side
  end

  -- jump start: after the lights were started, a car that stood in its box and then moves before they go out
  if lightsOut and cfg.jumpReport and not grid.jumped then
    if near and car.speedKmh < cfg.jump then
      grid.armed = true
    elseif grid.armed and car.speedKmh >= cfg.jump then
      grid.jumped = true
      report(2, lightsOut - sim.currentSessionTime)
    end
  end

  if lightsOut and sim.currentSessionTime >= lightsOut then
    lightsOut = nil
    if grid.shown then
      if cfg.finalReport and checking() and (grid.restOver > cfg.tolerance or grid.restSide > cfg.tolerance) then report(0) end
      grid.shown = false
    end
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
    local best, dist, count = nearestStart(ac.findNodes('sceneRoot:yes'))
    return string.format('start nodes=%d nearest=%s (%.2f m)', count, tostring(best), dist or -1)
  end)
  return string.format('why-not-slot=%s  %s', slotWhy, ok and text or ('start nodes: error ' .. tostring(text)))
end

function script.update(dt)
  local ok, err = pcall(tick, dt)
  if not ok then lastError = tostring(err) end
  ac.debug('gridbox error', lastError)
  if cfg.debug then ac.debug('gridbox status', status()) ac.debug('gridbox slot', slotStatus()) end
end

-- 3D boxes ---------------------------------------------------------------------------------------------------------
-- one box: its lines (not with STYLE=TEXT) and a label. `own` boxes say YOUR BOX, with STYLE=TEXT only the position text is drawn.
local function drawBox(bars, labelAt, text)
  if cfg.style ~= 'TEXT' then
    for _, q in ipairs(bars) do render.quad(q[1], q[2], q[3], q[4], COL_TXT) end
  end
  render.debugText(labelAt, text, COL_TXT, cfg.style == 'TEXT' and 3 or 1.6)
end

local function drawWorld()
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
-- 4 switch between lines + text and text only, 5 send your box to the admins again
local commandEvent = ac.OnlineEvent({
  key = ac.StructItem.key('GridBoxRecord'),
  cmd = ac.StructItem.int16(),
}, function(sender, message)
  if message.cmd == 1 then
    record(true)
  elseif message.cmd == 4 then
    cfg.style = cfg.style == 'TEXT' and 'BOX' or 'TEXT'
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
  lightsOut = message.startTime + message.delayTime
  if grid then grid.armed, grid.jumped = false, false end
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
  if not sim.isAdmin or not sender or sender.index == 0 then return end
  local fwd, line = vec3(m.fx, 0, m.fz), vec3(m.x, m.y, m.z)
  local box = buildBox(line, fwd, m.length, m.y)
  others[sender.sessionID] = { bars = box.bars, y = box.y, line = line, mid = line:clone():addScaled(fwd, -m.length / 2),
    pos = m.pos, name = sender:driverName() }
end, ac.SharedNamespace.ServerScript)

ac.onSessionStart(function()
  grid, others = nil, {}
  settle, retries = cfg.settle, 0
end)

ac.onOnlineWelcome(function(message, config)
  cfg.source = config:get('GRIDBOX', 'SOURCE', cfg.source):upper()
  cfg.slotRadius = config:get('GRIDBOX', 'SLOT_RADIUS_M', cfg.slotRadius)
  cfg.style = config:get('GRIDBOX', 'STYLE', cfg.style):upper()
  cfg.settle = config:get('GRIDBOX', 'SETTLE_SECONDS', cfg.settle)
  cfg.still = config:get('GRIDBOX', 'STILL_KMH', cfg.still)
  cfg.near = config:get('GRIDBOX', 'NEAR_M', cfg.near)
  cfg.lineOffset = config:get('GRIDBOX', 'LINE_OFFSET_M', cfg.lineOffset)
  cfg.lineWidth = config:get('GRIDBOX', 'LINE_WIDTH_M', cfg.lineWidth)
  cfg.patch = config:get('GRIDBOX', 'PATCH_M', cfg.patch)
  cfg.tolerance = config:get('GRIDBOX', 'TOLERANCE_M', cfg.tolerance)
  cfg.boxWidth = config:get('GRIDBOX', 'BOX_WIDTH_M', cfg.boxWidth)
  cfg.finalReport = config:get('GRIDBOX', 'FINAL_REPORT', 1) == 1
  cfg.jumpReport = config:get('GRIDBOX', 'JUMP_REPORT', 1) == 1
  cfg.jump = config:get('GRIDBOX', 'JUMP_KMH', cfg.jump)
  cfg.debug = config:get('GRIDBOX', 'DEBUG', 0) == 1
  if cfg.debug then ac.setMessage('GridBox', 'script loaded') end
  if not grid then settle, retries = cfg.settle, 0 end
  local function admin(title, action)
    ui.registerOnlineExtra(ui.Icons.Pitlane, title, function() return true end, nil, action, ui.OnlineExtraFlags.Admin)
  end
  admin('Grid: re-record boxes', function() commandEvent({ cmd = 1 }) end)
  admin('Grid: show boxes', function() commandEvent({ cmd = 2 }) end)
  admin('Grid: hide boxes', function() commandEvent({ cmd = 3 }) end)
  admin('Grid: toggle lines', function() commandEvent({ cmd = 4 }) end)
  -- only for this admin: show every driver's box; switching it on asks everybody to send their box again
  admin('Grid: show all boxes', function()
    showAll = not showAll
    if showAll then
      others = {}
      commandEvent({ cmd = 5 })
    end
  end)
end)
