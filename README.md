# GridBox

An Assetto Corsa online script (Custom Shaders Patch) that shows every driver their own grid spot after the formation lap.

- At the start of a race session each driver's client works out its grid box: the track's start slot of that car, or, if the slot cannot be determined, the spot where the car stands.
- It draws a thin white box (front line + side lines) with the grid position on the road, or only the position text.
- The box stays through the formation lap and disappears when the start lights go out.
- If a tyre is outside the box when the lights go out, or a car moves before they go out (jump start), a line is written to a report file on the admin's PC. Nothing goes to the chat. Nothing is checked while the lines are hidden.
- Admins can bring the boxes back for another formation lap, and can show the boxes of all drivers.

It follows the lights of [tetematete's startLights.lua](https://github.com/tetematete/OSRLUASNIPPETS/tree/main/Server%20Scripts#start-lights), so run that script too.

## Install (server admin)

1. Use the raw link of one release of `gridbox.lua`:
   `https://raw.githubusercontent.com/Equin0oX/ac-gridbox/refs/tags/v1.0/gridbox.lua`
   (or download the file from this page, host it somewhere public yourself and use that link).
2. In your server manager (ACSM: the event's CSP extra options box; Content Manager: the server preset's CSP extra options) add:

```ini
[SCRIPT_...]
SCRIPT = "https://raw.githubusercontent.com/Equin0oX/ac-gridbox/refs/tags/v1.0/gridbox.lua"

[GRIDBOX]
FINAL_REPORT=1
```

Keep the section name exactly `[SCRIPT_...]`, as for your other scripts. Players need CSP with online scripts (0.1.76 or newer; tested on 0.3.0-preview212). All tests ran on a CSP-only server (track name `csp/<build>/../<options>/../<track>`) with the literal `[SCRIPT_...]` section; whether a normal server loads the script too has not been tried.

Do not use a link with `refs/heads/main` on a live server: the script then changes whenever someone pushes to this repository, and it runs on every player's PC. The `v1.0` link never changes. For a newer version, read the changes and switch to its tag. Anyone who can edit the file behind the link runs code on every player's PC, so keep two-factor login on the account that owns it.

## Use

Admins sign in with `/admin <password>` in the chat, then open the extras menu:

| Button | What it does |
|---|---|
| Grid: show boxes | shows the remembered boxes again at the same spots (another formation lap), until the next lights out |
| Grid: hide boxes | hides them |
| Grid: toggle lines | switches between lines + text and text only |
| Grid: show all boxes | shows the boxes of all drivers (with position and name) on your screen, also after the lights; press again to turn off |
| Grid: re-record boxes | records every driver's spot again (cars must stand still) |

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
| STYLE | BOX | `BOX` lines + position text, `TEXT` only the position text (nothing is checked then) |
| FINAL_REPORT | 1 | report drivers who are outside at lights out |
| JUMP_REPORT | 1 | report a car that moves before the lights go out (after it stood in its box) |
| JUMP_KMH | 2 | speed from which a car counts as moving |
| PATCH_M | 0.1 | length of a tyre's contact patch in metres |
| LINE_OFFSET_M | 0 | move the front line forward (+) or back (-) |
| BOX_WIDTH_M | 2.4 | distance between the side lines |
| LINE_WIDTH_M | 0.08 | width of the lines |
| TOLERANCE_M | 0 | extra slack beyond the outer edge of the lines |
| SETTLE_SECONDS | 1.5 | seconds after a session starts before the box is recorded |
| STILL_KMH | 3 | speed under which a car counts as standing still |
| NEAR_M | 20 | a standing car is checked only within this distance of its box |
| DEBUG | 0 | show a status line with the measured margins (`over=`, `side=`) and where the box came from (`from=slot N` or `from=car`) |

A tyre is outside when any part of its contact patch is beyond the outer edge of the front line or a side line. A car standing too sideways counts too.

## Limits

- A client sends a box, a report or a command at most a few times a second; a stock server drops faster events, so GridBox queues them and retries.
- The box comes from the track's start slot (the `AC_START_n` node of the session's forced position). This assumes that slot lines up with the painted boxes and the car's spawn spot; it was checked only with fake data, not yet on a real track. Check it once on your track with `DEBUG=1`: the status line shows `slotErr`, the distance between the slot and where the car stood. If it is large, use `SOURCE=CAR` (or `STYLE=TEXT` where the painted boxes are good) and tune `LINE_OFFSET_M`.
- The paint itself is a texture and cannot be read.
- In the fallback (no start slot), a driver who reconnects after the session start, or who stands in the pit lane or is still moving when the session starts, gets no box until an admin records again.
- It listens to the event of startLights.lua (key `Start Lights`); a changed layout there breaks the link, the show/hide buttons keep working.

## Develop

See [DEVELOPING.md](DEVELOPING.md). Licence: MIT, see [LICENSE](LICENSE).
