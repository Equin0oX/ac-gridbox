# Developing GridBox

GridBox is a single Lua file, `gridbox.lua`, that runs on every player's PC as an Assetto Corsa online script (Custom Shaders Patch, CSP). Read `README.md` first for what it does.

## What is in this repository

| File | What it is |
|---|---|
| `gridbox.lua` | the script |
| `README.md` | what it does, install block, settings |
| `tests/run_tests.py` | headless tests: the real Lua file under LuaJIT with stubbed CSP functions |
| `testserver/setup_testserver.py` | builds a throw-away local AC server and deploys the script, to test in the game with one driver |
| `LICENSE` | MIT |

## Run the tests (no game needed)

```
pip install lupa
python tests/run_tests.py
```

All checks print PASS. The stubs mimic CSP types (vec3 methods return self or `out` like CSP). Add a test for every change and keep the stubs type-faithful, otherwise bugs hide.

## Test in the game

Needs Assetto Corsa, CSP 0.1.76 or newer (tested on 0.3.0-preview212), Content Manager, and the car and track named at the top of `setup_testserver.py` (`CAR`, `TRACK`; also the skins in `ENTRY_LIST` and the `LEGAL_TYRES` line for yours). The setup script stops with a message if the car or track is not installed.

1. Set `AC_GAME` (your assettocorsa folder) and optionally `GRIDBOX_TESTSERVER` (where the server folder goes), then `python testserver/setup_testserver.py`. It builds the server, writes the CSP extra options and copies `gridbox.lua` to `assettocorsa\extension\lua\online\`. It prints a random admin password: the server listens on all interfaces, so there is no fixed one.
2. Start `acServer.exe` from the server folder. Its session timers run from start even with nobody connected, so join soon.
3. Close the game if it is open, then run `Start-Process "acmanager://race/online/join?ip=127.0.0.1&httpPort=8091"` and press Drive in Content Manager.
4. In the chat: `/admin <the printed password>`, `/next_session` to skip practice, `/restart_session` to rerun a session.
5. The server prints chat as `CHAT [name]: text`, so a script can be watched from outside the game with `ac.sendChatMessage`.

Script edits reload live in the running game (no rejoin) but the script forgets its state, so it records the box again about 1.5 s later if you stand still in a race session. Server settings (the extra options) only change after a server restart and a rejoin.

The test server sets `DEBUG=1`: the status line shows `from=slot N slotErr=...` or `from=car`, and `GridBox:` lines go to `Documents\Assetto Corsa\logs\custom_shaders_patch.log` (grep that file instead of screenshotting the game). To test on another track set `GRIDBOX_TRACK` and `GRIDBOX_LAYOUT` before running the setup script, for example `rt_autodrom_most` and `no_chicane` (Autodrom Most, which has painted grid boxes). Start the server with its output captured, so a silent stop leaves a trace: `Start-Process acServer.exe -WorkingDirectory <server folder> -WindowStyle Hidden -RedirectStandardOutput server_out.txt -RedirectStandardError server_err.txt`.

Start lights: the test server also runs tetematete's `startLights.lua` from its public GitHub link. GridBox listens to its `Start Lights` event (same key and layout), so a layout change there breaks the link.

## Tools for a test with several drivers

`tools/analyze_log.py <csp log>` prints the timeline of a start from the `GridBox:` lines of a DEBUG=1 log and recomputes who was outside or moving from the tyre positions logged at the lights-out (same maths as `measure()`; the defaults for tyre width, patch, box width and line width are at the top of the file). `tools/collect_logs.ps1` copies the CSP log and the report file; `tools/watch_logs.ps1` runs in the background and keeps copies, also across a game restart. The unit tests build a 3-car log with the harness stubs; extend the stubs (`OTHERS`) when a new log line needs more car fields.

CSP lists: an INI value with commas is a list; `config:get(section, key, default)` returns only the first item, the rest comes with the 4th argument (`offset`). v1.5 lost the race from `RECORD_IN=PRACTICE,RACE` this way; the test stub of the INI config now behaves like that.

## How the box is found

`record()` works only in the sessions named in `RECORD_IN` (default `RACE`; an admin's re-record works in any). It tries the track's start slot first: `ac.getSession(sim.currentSessionIndex).forcedPosition` is taken as the 0-based number n of the node `AC_START_n`, the front line goes at the node plus the front-axle offset, and the label is n+1. Measured on the test rig (stock pickup server): `forcedPosition` is -1, so a standing car outside the pit lane takes the start node nearest to it (`SLOT_RADIUS_M`, default 2 m; all nodes are listed with `findNodes('AC_START_?')`, as in tetematete's `getBoxes`), labelled by its grid position among the connected cars. If no node is near enough, the node API is unavailable or the car is moving, it falls back to the car: a standing car, outside the pit lane (tried again every 0.5 s for 3 s). `SOURCE=CAR` skips the slot.

Measured on the rig (Tatuus, Bowman Gray, stock pickup server): the track's 60 `AC_START_n` nodes can be read and `getPosition()` works as a world position. **The game spawns a car with its PHYSICS origin on the node** (`car.transform.position`), not the model origin (`car.position`): the Tatuus model origin is 0.42 m ahead (its `GRAPHICS_OFFSET` z), and the axles then lie 1.70 m ahead of and 1.23 m behind the node = (1 - CG_LOCATION) and CG_LOCATION of the 2.930 m wheelbase. Measuring from `car.position` put the box 0.42 m back (v1.0 bug: a parked car read `over=+0.39`); from the physics origin `slotErr` is 0.01 m. Still unverified: that an assigned `forcedPosition >= 0` is the 0-based index (the rig never sets one), other cars, and the alignment with painted boxes (the rig track has none). The DEBUG status shows `from=slot N slotErr=<m>`; its second line shows `why-not-slot=...`, the node count and the nearest node.

## The report file

Scripts cannot write normal files. GridBox sends a hidden `ac.OnlineEvent` and the client of a signed-in admin writes it through `ac.storage` to `Documents\Assetto Corsa\cfg\extension\state\lua\shared-gridbox`. CSP stores the keys hashed, so the lines are unordered; each value starts with a time stamp. Report numbers are 16 bit, so they are clamped to 32 m / 32 s.

A stock server accepts about one event per 200 ms from a client and the send function returns false when it refuses, so events wait in a small queue (`outbox`) and are retried on later frames.

## Traps that cost hours

- The script section must be named exactly `[SCRIPT_...]`, and the track name of a CSP-only server `csp/3465/../B/../<track>`. With a custom section name (`[SCRIPT_GRIDBOX]`) and a plain `csp/3465/../<track>` the game parsed the settings but never started any script. Which of the two matters is unknown, so use both.
- Do not link the track under `content/tracks/csp/<track>` on the test server: the server then checksums a path the client lacks and kicks everyone with "Checksum failed". Leave the track unresolvable and the server skips those checksums.
- Welcome message encoding: UTF-8, zlib level 6, base64 without `=`, 32 tabs and `$CSP0:` in front, appended after the text. `setup_testserver.py` has an encoder and a decoder check.
- The game spawns the car's physics origin (`car.transform.position`) on `AC_START_n`; `car.position` is the model origin and can sit ahead of it (0.42 m on the Tatuus, see above).
- The car origin is not at ground level in every car. Lines are placed by a ray down onto the track meshes (`render.createRay(...):track()`), not from contact points or wheel height.
- The game's `racePosition` counts empty entry slots. Grid position is 1 + the connected cars ahead.
- `mklink /J` succeeds even when the target folder does not exist, so a wrong car or track name only shows up later. The setup script checks first.

## References

- CSP Lua API for online scripts: `assettocorsa\extension\internal\lua-sdk\ac_online_script\lib.lua` in your own CSP install.
- CSP wiki "Misc - Server extra options" (online scripts, welcome message encoding, CSP-only servers).
- Content Manager source (github.com/gro-ove/actools) for how it builds the welcome message and the track name.
- tetematete's snippets: github.com/tetematete/OSRLUASNIPPETS (start lights, and `getBoxes` to read the track's start slots).

## Not tested yet in the game

The slot-based box (see above), the show-all-boxes button, the retry of a failed recording, the pit-lane guard, the queue for refused sends, more than one driver at once, a real server, the admin show/hide/toggle buttons and `STYLE=TEXT`. The tests cover all of them with stubs only.

## Be careful with the public link

Whoever can edit the file behind the `SCRIPT =` link runs code on every player's PC. Keep two-factor login on that account, and give servers a link pinned to a tag or commit, never to `main`. Publish a change as a new tag (v1.1, ...) and tell the server admins to read it before switching.
