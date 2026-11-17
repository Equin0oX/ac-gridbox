-- GridBox: CSP online script (the server pushes it to every client through a [SCRIPT_...] block in the CSP extra options).
-- Each client remembers where ITS OWN car stood at the start of a race session and shows that spot (a front line with side lines and
-- the grid position, or just the position text) until the lights of tetematete's startLights.lua go out, i.e. through the formation
-- lap. The lines stay white; the HUD line turns red while the car is outside, and the script writes to chat only if the car is
-- outside when those lights go out. Outside means: any part of any tyre's contact patch is beyond the outer edge of the front line
-- or of a side line (so a car standing too sideways is outside too). A patch that is on the line is still inside.
-- With the lines hidden (STYLE=TEXT or the toggle button) nothing is checked: no HUD warning, no chat report.
-- An admin can bring the boxes back at the remembered spots (another formation lap) with "Grid: show boxes", hide them with
-- "Grid: hide boxes", switch between lines+text and text only with "Grid: toggle lines" (or STYLE=TEXT in the settings), or
-- record the spots again with "Grid: re-record boxes".
-- Settings: a [GRIDBOX] section in the same extra options (all optional, see `cfg` below for the defaults).
-- shortcut: own car only and kept in memory, so a driver who reconnects mid-session loses the box until an admin re-records. The
-- start lights are learned from the event of startLights.lua (same key and layout), so a new layout there breaks the link: the
-- show/hide buttons still work. Add syncing of other cars' boxes when stewards ask for it.
local sim = ac.getSim()
local car = ac.getCar(0)

local cfg = {
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
  liveChat = false,  -- also write to chat while a car sits outside before the lights (off: only the report at lights out)
  finalChat = true,  -- write to chat if the car is outside when the start lights go out
  hold = 1.5,        -- s a car must sit outside before the live message
  hideAcLights = false, -- experimental: hide the game's own start lights (the CSP docs say sandboxed scripts may not be allowed to)
  debug = false,     -- always show a status line (and a "loaded" message) so a silent script can be told from an idle one
}
local grid, settle, lightsOut, lastError = nil, -1, nil, nil
local COL_OK, COL_OVER, COL_TXT = rgbm(0.2, 1, 0.4, 1), rgbm(1, 0.15, 0.1, 1), rgbm(1, 1, 1, 1) -- HUD colours; the lines are COL_TXT, always white

-- Grid position among the cars that are connected: the game's race position also counts empty entry slots ahead of the car.
local function gridPosition()
  local rank = 1
  for i = 1, sim.carsCount - 1 do
    local other = ac.getCar(i)
    if other and other.isConnected and other.racePosition < car.racePosition then rank = rank + 1 end
  end
  return rank
end

-- returns true if a box was recorded
local function snapshot(anySession)
  if car.speedKmh >= cfg.still then return false end
  if not anySession and sim.raceSessionType ~= ac.SessionType.Race then return false end
  local w = car.wheels
  local front = w[0].position:clone():add(w[1].position):scale(0.5)
  local rear = w[2].position:clone():add(w[3].position):scale(0.5)
  local wheelbase = front:distance(rear)
  local fwd = front:clone():sub(rear)
  fwd.y = 0
  fwd:normalize()
  -- ground level under the car: the tyres' contact points (the car origin is not at ground level in every car model, and wheel
  -- centre minus tyre radius ignores how far the tyre is squashed); wheel centre minus radius if a contact point is missing
  local ground = 0
  for k = 0, 3 do
    local cp = w[k].contactPoint
    ground = ground + ((cp and cp:lengthSquared() > 0) and cp.y or (w[k].position.y - (w[k].tyreRadius or 0.3)))
  end
  local right = vec3(fwd.z, 0, -fwd.x)
  -- the front line starts at the front edge of the front tyres' contact patches, so the spawn spot itself is on the line
  local line = front:clone():addScaled(fwd, cfg.lineOffset + cfg.patch / 2)
  local length = wheelbase + 1.8
  -- Height of the VISIBLE road under each corner of the box (a ray down onto the track meshes): the physics contact points can sit
  -- a little above the road model, which made the lines float. Falls back to the average contact height.
  local base = ground / 4 + 1.5
  local function road(along, across)
    local p = line:clone():addScaled(fwd, along):addScaled(right, across)
    local ok, d = pcall(function() return render.createRay(vec3(p.x, base, p.z), vec3(0, -1, 0), 3):track() end)
    return ((ok and d and d > 0) and base - d or ground / 4) + 0.01
  end
  local half = cfg.boxWidth / 2
  local yfl, yfr, yrl, yrr = road(0, half), road(0, -half), road(-length, half), road(-length, -half)
  grid = {
    fwd = fwd,
    right = right,
    line = line,
    center = front:clone():add(rear):scale(0.5),
    length = length,
    y = (yfl + yfr + yrl + yrr) / 4,
    yfl = yfl, yfr = yfr, yrl = yrl, yrr = yrr,
    pos = gridPosition(),
    shown = true,
    over = 0, side = 0, restOver = 0, restSide = 0, hold = 0, reported = false,
  }
  lightsOut = nil
  return true
end

-- How far the car is outside its box, in metres (> 0: outside): `over` is how far the front edge of the most forward front tyre's
-- contact patch is past the outer edge of the front line, `side` how far the outermost edge of any of the four patches is past the
-- outer edge of a side line. The patch is a rectangle turned with the car, so a car standing sideways sticks out further.
local function measure()
  local w, g = car.wheels, grid
  local half = cfg.lineWidth / 2
  local cf = w[0].position:clone():add(w[1].position):scale(0.5):sub(w[2].position:clone():add(w[3].position):scale(0.5))
  cf.y = 0
  cf:normalize()
  local c, s = math.abs(cf:dot(g.fwd)), math.abs(cf:dot(g.right))
  local lineAhead = g.line:clone():sub(g.center):dot(g.fwd)
  local over, side = -1e9, -1e9
  for k = 0, 3 do
    local d = w[k].position:clone():sub(g.center)
    local tw = (w[k].tyreWidth or 0.25) / 2
    if k < 2 then over = math.max(over, d:dot(g.fwd) - lineAhead + cfg.patch / 2 * c + tw * s) end
    side = math.max(side, math.abs(d:dot(g.right)) + tw * c + cfg.patch / 2 * s - cfg.boxWidth / 2)
  end
  return over - half, side - half
end

local function report(what)
  local parts = {}
  if grid.restOver > cfg.tolerance then parts[#parts + 1] = string.format('%.2f m over the line', grid.restOver) end
  if grid.restSide > cfg.tolerance then parts[#parts + 1] = string.format('%.2f m outside the box', grid.restSide) end
  ac.sendChatMessage(string.format('%s %s %s (grid P%d)', car:driverName(), what, table.concat(parts, ' and '), grid.pos))
end

-- With the lines hidden (STYLE=TEXT) the drivers go by the track's own painted boxes, so nothing is checked, shown or reported.
local function checking() return cfg.style ~= 'TEXT' end
local function outside() return checking() and (grid.over > cfg.tolerance or grid.side > cfg.tolerance) end

local function tick(dt)
  if settle > 0 then
    settle = settle - dt
    if settle <= 0 then snapshot(false) end
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

  if grid.shown and still and near and outside() then
    grid.hold = grid.hold + dt
    if cfg.liveChat and grid.hold >= cfg.hold and not grid.reported then
      grid.reported = true
      report('is')
    end
  elseif not outside() then
    grid.hold, grid.reported = 0, false
  end

  if lightsOut and sim.currentSessionTime >= lightsOut then
    lightsOut = nil
    if grid.shown then
      if cfg.finalChat and checking() and (grid.restOver > cfg.tolerance or grid.restSide > cfg.tolerance) then report('started') end
      grid.shown = false
    end
  end
end

local function status()
  return string.format('GridBox debug: session=%d speed=%.0f settle=%.1f box=%s shown=%s over=%s side=%s lights-out in %s s err=%s',
    sim.raceSessionType, car.speedKmh, settle, grid and 'yes' or 'no', tostring(grid and grid.shown),
    grid and string.format('%.3f', grid.over) or '-', grid and string.format('%.3f', grid.side) or '-',
    lightsOut and string.format('%.1f', (lightsOut - sim.currentSessionTime) / 1000) or '-', tostring(lastError))
end

function script.update(dt)
  local ok, err = pcall(tick, dt)
  if not ok then lastError = tostring(err) end
  ac.debug('gridbox error', lastError)
  if cfg.debug then ac.debug('gridbox status', status()) end
end

-- 3D box / position text -----------------------------------------------------------------------------------------
local function bar(a, b, t, col)
  local d = b:clone():sub(a)
  d.y = 0
  d:normalize()
  local n = vec3(d.z * t / 2, 0, -d.x * t / 2)
  render.quad(a:clone():add(n), b:clone():add(n), b:clone():sub(n), a:clone():sub(n), col)
end

local function drawWorld()
  if not grid or not grid.shown then return end
  local g = grid
  local col = COL_TXT -- always white
  render.setBlendMode(render.BlendMode.AlphaBlend)
  render.setDepthMode(render.DepthMode.ReadOnly)
  if cfg.style == 'TEXT' then
    render.debugText(vec3(g.line.x, g.y + 1.4, g.line.z), string.format('P%d', g.pos), col, 3)
    return
  end
  -- the front line and the two side lines, no rear line
  local side = g.right:clone():scale(cfg.boxWidth / 2)
  local rear = g.line:clone():addScaled(g.fwd, -g.length)
  local fl, fr = g.line:clone():add(side), g.line:clone():sub(side)
  local rl, rr = rear:clone():add(side), rear:clone():sub(side)
  fl.y, fr.y, rl.y, rr.y = g.yfl, g.yfr, g.yrl, g.yrr
  -- the front line reaches half a line width past the side lines' centres and the side lines half a line width past the front line's
  -- centre, so the outer corners are complete squares instead of notched
  local ext = cfg.lineWidth / 2
  local alongExt, acrossExt = g.fwd:clone():scale(ext), g.right:clone():scale(ext)
  bar(fl:clone():add(acrossExt), fr:clone():sub(acrossExt), cfg.lineWidth, col)
  bar(fl:clone():add(alongExt), rl, cfg.lineWidth, col)
  bar(fr:clone():add(alongExt), rr, cfg.lineWidth, col)
  render.debugText(vec3(g.center.x, g.y + 1.6, g.center.z), string.format('P%d  YOUR BOX', g.pos), col, 1.6)
end
render.on('main.track.transparent', drawWorld)

-- HUD line -------------------------------------------------------------------------------------------------------
function script.drawUI()
  if cfg.debug then
    ui.transparentWindow('GridBoxDebug', vec2(20, 60), vec2(760, 30), true, false, function() ui.textColored(status(), COL_TXT) end)
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
-- 4 switch between lines + text and text only
local commandEvent = ac.OnlineEvent({
  key = ac.StructItem.key('GridBoxRecord'),
  cmd = ac.StructItem.int16(),
}, function(sender, message)
  if message.cmd == 1 then
    snapshot(true)
  elseif message.cmd == 4 then
    cfg.style = cfg.style == 'TEXT' and 'BOX' or 'TEXT'
  elseif grid and message.cmd == 2 then
    grid.shown, grid.hold, grid.reported, lightsOut = true, 0, false, nil
  elseif grid and message.cmd == 3 then
    grid.shown = false
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
end, ac.SharedNamespace.ServerScript)

local function hideAcLights()
  if cfg.hideAcLights then pcall(ac.disableExtraHUDElements, 'startingLights', true) end
end

ac.onSessionStart(function()
  grid = nil
  settle = cfg.settle
  hideAcLights()
end)

ac.onOnlineWelcome(function(message, config)
  cfg.style = config:get('GRIDBOX', 'STYLE', cfg.style):upper()
  cfg.settle = config:get('GRIDBOX', 'SETTLE_SECONDS', cfg.settle)
  cfg.still = config:get('GRIDBOX', 'STILL_KMH', cfg.still)
  cfg.near = config:get('GRIDBOX', 'NEAR_M', cfg.near)
  cfg.lineOffset = config:get('GRIDBOX', 'LINE_OFFSET_M', cfg.lineOffset)
  cfg.lineWidth = config:get('GRIDBOX', 'LINE_WIDTH_M', cfg.lineWidth)
  cfg.patch = config:get('GRIDBOX', 'PATCH_M', cfg.patch)
  cfg.tolerance = config:get('GRIDBOX', 'TOLERANCE_M', cfg.tolerance)
  cfg.boxWidth = config:get('GRIDBOX', 'BOX_WIDTH_M', cfg.boxWidth)
  cfg.hold = config:get('GRIDBOX', 'LIVE_HOLD_SECONDS', cfg.hold)
  cfg.liveChat = config:get('GRIDBOX', 'LIVE_CHAT', 0) == 1
  cfg.finalChat = config:get('GRIDBOX', 'FINAL_CHAT', 1) == 1
  cfg.hideAcLights = config:get('GRIDBOX', 'HIDE_AC_LIGHTS', 0) == 1
  cfg.debug = config:get('GRIDBOX', 'DEBUG', 0) == 1
  if cfg.debug then ac.setMessage('GridBox', 'script loaded') end
  if not grid then settle = cfg.settle end
  hideAcLights()
  local function admin(title, cmd)
    ui.registerOnlineExtra(ui.Icons.Pitlane, title, function() return true end, nil,
      function() commandEvent({ cmd = cmd }) end, ui.OnlineExtraFlags.Admin)
  end
  admin('Grid: re-record boxes', 1)
  admin('Grid: show boxes', 2)
  admin('Grid: hide boxes', 3)
  admin('Grid: toggle lines', 4)
end)
