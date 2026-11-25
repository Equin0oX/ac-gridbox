# GridBox

An Assetto Corsa online script (Custom Shaders Patch) that shows every driver their own grid spot after the formation lap.

- At the start of a race session each driver's client works out its grid box: the track's start slot of that car, or, if the slot cannot be determined, the spot where the car stands.
- It draws a thin white box (front line + side lines) with the grid position on the road, or only the position text.
- The box stays through the formation lap and disappears when the start lights go out.
- If a tyre is outside the box when the lights go out, or a car is moving at the moment they go out (jump start), a line is written to a report file on the admin's PC. Moving after the lights were started and standing still again before they go out (repositioning) is legal. Nothing goes to the chat. The over-the-line check is off while the lines are hidden.
- Admins can bring the boxes back for another formation lap, and can show the boxes of all drivers.

It follows the lights of [tetematete's startLights.lua](https://github.com/tetematete/OSRLUASNIPPETS/tree/main/Server%20Scripts#start-lights), so run that script too.

## Install (server admin)

1. Use the raw link of one release of `gridbox.lua`:
   `https://raw.githubusercontent.com/Equin0oX/ac-gridbox/refs/tags/v1.8/gridbox.lua`
   (or download the file from this page, host it somewhere public yourself and use that link).
2. In your server manager (ACSM: the event's CSP extra options box; Content Manager: the server preset's CSP extra options) add:

```ini
[SCRIPT_...]
SCRIPT = "https://raw.githubusercontent.com/Equin0oX/ac-gridbox/refs/tags/v1.8/gridbox.lua"

[GRIDBOX]
FINAL_REPORT=1
```

Keep the section name exactly `[SCRIPT_...]`, as for your other scripts. Players need CSP with online scripts. It was tested on 0.3.0-preview212; tetematete's wiki reports other online scripts working back to build 3465 (0.2.11). CSP builds from 0.2.12-preview1 to 0.3.0-preview139 with the new main menu have a bug that breaks `ac.onOnlineWelcome`: GridBox would then run with its default settings and show no admin buttons. To keep such builds out, use tetematete's Force CSP Version script (`[CSPVERSION] VERSION=...`). All tests ran on a CSP-only server (track name `csp/<build>/../<options>/../<track>`) with the literal `[SCRIPT_...]` section; whether a normal server loads the script too has not been tried.

Do not use a link with `refs/heads/main` on a live server: the script then changes whenever someone pushes to this repository, and it runs on every player's PC. The `v1.8` link never changes. For a newer version, read the changes and switch to its tag. Do not use `v1.0`: its slot box sits 0.42 m behind a car on the Tatuus and would report a correctly parked car as over the line. Anyone who can edit the file behind the link runs code on every player's PC, so keep two-factor login on the account that owns it.

Optional: add `REQUIRED=1` to the `[SCRIPT_...]` block and CSP closes the game of a player whose copy of the script cannot load, so nobody races without boxes.

## Use

Admins sign in with `/admin <password>` in the chat. The buttons are in the admin menu of the chat app (the settings icon; turn on its admin options). That is how tetematete's wiki describes it: I have not checked it in the game.

| Button | What it does |
|---|---|
| Grid: show boxes | shows the remembered boxes again at the same spots (another formation lap), until the next lights out |
| Grid: hide boxes | hides them |
| Grid: show all boxes | shows the boxes of all drivers (with position and name) on your screen, also after the lights; press again to turn off |
| Grid: re-record boxes | records every driver's spot again (cars must stand still) |
| Grid: toggle lines | only with `EXTRA_TOOLS=1`: switches between lines + text and text only |

Procedure: the race starts, the game's lights go out, drivers drive the formation lap and park in their boxes, an admin starts the start lights, the boxes disappear at lights out and anyone outside, or who moved before the lights went out, is written to the report file.

## The report file

Each driver's client sends a hidden report; the client of every admin who is signed in (`/admin <password>`) at that moment writes it down. Scripts cannot write normal files, so it uses CSP's script storage. On the admin's PC the file is

`Documents\Assetto Corsa\cfg\extension\state\lua\shared-gridbox`

and looks like this (open it in any text editor; the numbers in front are CSP's own keys and the lines are not in order, sort them by the time):

```
[STRING]
3294517614687035070='01:07:15  Driver Name  grid P1  0.78 m over the line at lights out'
241454852807763514='01:08:02  Driver Name  grid P1  JUMP START, moved 483 ms before the lights went out'
790407342556207414=4
```

The last entry is the running count of reports; the file keeps the latest 1000. If no admin is signed in when the lights go out, nothing is recorded. The start lights script's own "Jumped the start" chat lines are separate and still appear in the chat.

## Trust

Every driver's PC decides about itself and sends its own report. A stock server cannot tell a real report or admin command from a forged one, so a driver who modifies their game could send fake reports or press the admin buttons for everybody. Treat the report file as a hint for the stewards, not as proof.

## Settings (all optional, in `[GRIDBOX]`)

| Key | Default | Meaning |
|---|---|---|
| SOURCE | AUTO | `AUTO` the box comes from the track's start slot, from where the car stands if the slot is unknown; `CAR` always from where the car stands |
| RECORD_IN | RACE | the sessions in which boxes are recorded by themselves at the session start: any of `PRACTICE`, `QUALIFY`, `RACE`, separated by commas (`PRACTICE,RACE` for practice start drills; needs v1.6, v1.5 read only the first item). Cars standing in the pit lane get no box when no slot is assigned. An admin can always record with the button, in any session. A box is dropped when the next session starts |
| SLOT_RADIUS_M | 2 | if the server assigns no slot (pickup servers), a standing car takes the start slot whose node is nearest, if within this distance; `0` = never |
| STYLE | BOX | `BOX` lines + position text, `TEXT` only the position text: no lines, no HUD warning and no over-the-line report (the track's painted lines are the reference); a jump start is still reported, turn that off with `JUMP_REPORT=0` |
| FINAL_REPORT | 1 | report drivers who are outside at lights out |
| JUMP_REPORT | 1 | report a car that is moving when the lights go out (after it stood in its box once the lights were started); a car that moves in between but stands still at the lights-out is not reported |
| JUMP_KMH | 2 | speed from which a car counts as moving |
| PATCH_M | 0.1 | length of a tyre's contact patch in metres |
| LINE_FROM_NODE_M | 0 | `> 0`: the front line lies this many metres ahead of the track's start node, the same for every car model (use it when the event has more than one car); `0`: the line is measured from the front tyres of each car. Only with a start slot, not in the car fallback |
| LINE_OFFSET_M | 0 | move the front line forward (+) or back (-) from the front edge of the front tyres' contact patch at the start slot; set it per track, see "Fit the line to a track" |
| BOX_WIDTH_M | 2.4 | distance between the side lines |
| LINE_WIDTH_M | 0.08 | width of the lines |
| TOLERANCE_M | 0 | extra slack beyond the outer edge of the lines |
| SETTLE_SECONDS | 1.5 | seconds after a session starts before the box is recorded |
| STILL_KMH | 3 | speed under which a car counts as standing still |
| NEAR_M | 20 | a standing car is checked only within this distance of its box |
| EXTRA_TOOLS | 0 | the admin menu has the four buttons above; 1 adds `Grid: toggle lines` and, with `DEBUG=1`, the test buttons (`Grid debug: ...`: nudge the front line 5 cm, ask everyone for a status, teleport your car to a start slot) |
| SHOW_START_NODES | 0 | with `DEBUG=1`, 1 also draws yellow crosses and names on the track's start nodes near the car (to compare them with the painted boxes); 0 draws nothing but the lines |
| DEBUG | 0 | a status line with the measured margins (`over=`, `side=`) and where the box came from (`from=slot N` or `from=car`), a second line with why a slot was not used, the start-node count and `line-offset`; with `EXTRA_TOOLS=1` also admin buttons to nudge the front line by 5 cm, to ask everyone for a status and to teleport your car to a start slot (for tests); and a line in the CSP log (`Documents\Assetto Corsa\logs\custom_shaders_patch.log`) for the recording, Start Lights event, lights out, reports and admin commands |

A tyre is outside when any part of its contact patch is beyond the outer edge of the front line or a side line. A car standing too sideways counts too.

## Test with several drivers

Set `DEBUG=1` for every driver (it comes with the server's extra options). Each client then writes `GridBox:` lines to its CSP log, `Documents\Assetto Corsa\logs\custom_shaders_patch.log`, **which the game wipes at every start: copy it before restarting the game**. The admin's log alone tells most of the story, because every client sends status snapshots (`GridBoxDebug`) that every client with `DEBUG=1` logs, and the admin's client also logs every shared box, report, admin command and Start Lights message, a flight recorder of every car's speed (4 times a second from the Start Lights message to 3 s after the lights-out), and at the lights-out each car's tyre positions and box.

After a start, run `python tools/analyze_log.py <the admin's log>`: it lists the cars, which of them were outside or moved before the lights-out (recomputed from the tyre positions, not from anyone's own report) and what looks wrong (no box, large slot error, dropped events, errors). `tools/collect_logs.ps1` copies the CSP log and the report file to a folder; `tools/watch_logs.ps1` keeps copies while a test runs, also across a game restart. A driver whose log is needed can copy the CSP log file and send it. In every log, `GridBox v1.6 loaded, CSP build ...` and `welcome received, ...` show which script version runs with which settings; a log with the first line but not the second did not get the server's settings.

## Fit the line to a track

The game spawns each car with its physics origin on the track's start node, but the painted line can be anywhere in front of it, so the front line needs one value per track. With `DEBUG=1` and `EXTRA_TOOLS=1`, stand in your box and press the admin buttons `Grid debug: front line 5 cm forward` or `5 cm back` until the white line lies on the painted one. The second debug line then shows `line-from-node=` (the distance of the front line from the start node); the last `recorded ... line-from-node=` line in the CSP log has the same number. Put it in `LINE_FROM_NODE_M`: it is the same for every car model, because the paint does not depend on the car. (`LINE_OFFSET_M` alone is measured from the front tyres of each car, so it fits one car model only.)

Measured: Autodrom Most (`rt_autodrom_most`) with the Tatuus FT-60K: the line lies 2.40 m ahead of the node, so `LINE_FROM_NODE_M=2.40`. The `chicane` and `no_chicane` layouts load the same start nodes and the same painted lines, so the value should hold for both; it was fitted on `no_chicane` only. The debug buttons move only the front line; `BOX_WIDTH_M` stayed at 2.4 in that test.

## Limits

- A client sends a box, a report or a command at most a few times a second; a stock server drops faster events, so GridBox queues them and retries.
- The box comes from the track's start slot: the `AC_START_n` node of the session's forced position or, when the server assigns none (measured: a stock pickup server leaves it at -1), the start node nearest to the standing car. The game spawns a car with its physics origin on that node (measured with the Tatuus: slot error 0.01 m for a car parked where it spawned), and GridBox measures the car's axles from that origin. It does not know where the painted boxes are: on a track whose paint does not match the start nodes, use `STYLE=TEXT` or tune `LINE_OFFSET_M`. Check your track once with `DEBUG=1`: the status line shows `from=slot N` and `slotErr`, the distance between the slot and where the car stood (about 0 for a car parked where it spawned). If it is large, use `SOURCE=CAR`.
- The paint itself is a texture and cannot be read.
- In the fallback (no start slot), a driver who reconnects after the session start, or who stands in the pit lane or is still moving when the session starts, gets no box until an admin records again.
- It listens to the event of startLights.lua (key `Start Lights`); a changed layout there breaks the link, the show/hide buttons keep working. With `F1_STYLE=1` there, the lights-out time is only known when an admin presses "Start Lights Out": the boxes stay until then, and a car that moves while the lights are held is only judged at the real lights-out.

## Versions

- v1.8: **a jump start is judged at the lights-out**: a car that stood in its box after the lights were started is reported only if it is moving when they go out (v1.7 reported any movement in between, so repositioning counted); the report shows how long the car had been moving; with a held `F1_STYLE` start the car is judged at the release; README: `STYLE=TEXT` row and the `DEBUG` row now match what the script does.
- v1.7: **less lag with `DEBUG=1`** (it searched the track's scene for the start nodes twice per frame; now it uses the nodes read once per session); boxes are named after their start slot (P1 = AC_START_0; v1.6 named them by the cars' race positions, which gave two boxes the same number on the official server); the admin menu has four buttons, `EXTRA_TOOLS=1` adds `Grid: toggle lines` and with `DEBUG=1` the test buttons; `DEBUG=1` no longer draws the yellow start-node markers (`SHOW_START_NODES=1` brings them back); the debug teleport button puts each car on the start node of its own session ID instead of the same slot for everybody.
- v1.6: **fixes `RECORD_IN=PRACTICE,RACE`** (v1.5 read only the first item, so the race did not record); with `DEBUG=1` it logs everything a multi-driver test needs (see "Test with several drivers"); at the session start a standing car trusts the start node it stands on over an assigned `forcedPosition` that disagrees; box shares and status events are spread out with a random delay; errors, the script version and the received settings are always logged.
- v1.5: `RECORD_IN` lets boxes be recorded by themselves in practice and qualifying sessions, not only in the race.
- v1.4: `LINE_FROM_NODE_M` puts the front line a fixed distance ahead of the start node for every car model; the debug status and log show `line-from-node=`.
- v1.3: with `DEBUG=1` the script writes its steps to the CSP log, marks the track's start nodes and has two admin buttons to nudge the front line, to fit `LINE_OFFSET_M` to a track (README: "Fit the line to a track"; Autodrom Most with the Tatuus: 0.65). The test rig can use another track.
- v1.2: a jump start in an `F1_STYLE` start is reported without a meaningless "32000 ms"; README: CSP version bug, where the admin buttons are, `REQUIRED=1`.
- v1.1: the slot box is measured from the car's physics origin (v1.0 was 0.42 m off on the Tatuus); with no assigned slot (pickup servers) a standing car takes the nearest start node; boxes are only recorded in a race session.
- v1.0: first release with the slot box. Do not use.

## Develop

See [DEVELOPING.md](DEVELOPING.md). Licence: MIT, see [LICENSE](LICENSE).
