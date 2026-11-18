# GridBox

An Assetto Corsa online script (Custom Shaders Patch) that shows every driver their own grid spot after the formation lap.

- At the start of a race session each driver's client remembers where their car stood.
- It draws a thin white box (front line + side lines) with the grid position on the road, or only the position text.
- The box stays through the formation lap and disappears when the start lights go out.
- If a tyre is outside the box when the lights go out, or a car moves before they go out (jump start), a line is written to a report file on the admin's PC. Nothing goes to the chat. Nothing is checked while the lines are hidden.
- Admins can bring the boxes back for another formation lap.

It follows the lights of [tetematete's startLights.lua](https://github.com/tetematete/OSRLUASNIPPETS/tree/main/Server%20Scripts#start-lights), so run that script too.

## Install (server admin)

1. Use the raw link of `gridbox.lua`:
   `https://raw.githubusercontent.com/Equin0oX/ac-gridbox/refs/heads/main/gridbox.lua`
   (or download the file from this page, host it somewhere public yourself and use that link).
2. In your server manager (ACSM: the event's CSP extra options box; Content Manager: the server preset's CSP extra options) add:

```ini
[SCRIPT_...]
SCRIPT = "https://raw.githubusercontent.com/Equin0oX/ac-gridbox/refs/heads/main/gridbox.lua"

[GRIDBOX]
FINAL_REPORT=1
```

Keep the section name exactly `[SCRIPT_...]`, as for your other scripts. Players need CSP with online scripts (0.1.76 or newer; tested on 0.3.0-preview212). The server must be a CSP-only server (it already is if your other scripts work).

Anyone who can edit that link runs code on every player's PC. Use your own account with two-factor login, or pin the link to one commit (replace `refs/heads/main` with the commit hash).

## Use

Admins sign in with `/admin <password>` in the chat, then open the extras menu:

| Button | What it does |
|---|---|
| Grid: show boxes | shows the remembered boxes again at the same spots (another formation lap), until the next lights out |
| Grid: hide boxes | hides them |
| Grid: toggle lines | switches between lines + text and text only |
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

The last entry is the running count of reports; the file keeps the latest 999. If no admin is signed in when the lights go out, nothing is recorded. The start lights script's own "Jumped the start" chat lines are separate and still appear in the chat.

## Settings (all optional, in `[GRIDBOX]`)

| Key | Default | Meaning |
|---|---|---|
| STYLE | BOX | `BOX` lines + position text, `TEXT` only the position text (nothing is checked then) |
| FINAL_REPORT | 1 | report drivers who are outside at lights out |
| LIVE_REPORT | 0 | also report while a driver sits parked outside before the lights |
| JUMP_REPORT | 1 | report a car that moves before the lights go out (after it stood in its box) |
| JUMP_KMH | 2 | speed from which a car counts as moving |
| PATCH_M | 0.1 | length of a tyre's contact patch in metres |
| LINE_OFFSET_M | 0 | move the front line forward (+) or back (-) |
| BOX_WIDTH_M | 2.4 | distance between the side lines |
| LINE_WIDTH_M | 0.08 | width of the lines |
| TOLERANCE_M | 0 | extra slack beyond the outer edge of the lines |
| DEBUG | 0 | show a status line with the measured margins (`over=`, `side=`) for tuning |

A tyre is outside when any part of its contact patch is beyond the outer edge of the front line or a side line. A car standing too sideways counts too.

## Limits

- Each client only knows its own car and keeps it in memory: a driver who reconnects after the session start has no box until an admin re-records.
- It listens to the event of startLights.lua (key `Start Lights`); a changed layout there breaks the link, the show/hide buttons keep working.
- The painted grid boxes of a track cannot be read by scripts. The box is drawn from where the car spawned; use `STYLE=TEXT` where the painted boxes are good, or tune `LINE_OFFSET_M`.
