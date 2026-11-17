# GridBox

An Assetto Corsa online script (Custom Shaders Patch) that shows every driver their own grid spot after the formation lap.

- At the start of a race session each driver's client remembers where their car stood.
- It draws a thin white box (front line + side lines) with the grid position on the road, or only the position text.
- The box stays through the formation lap and disappears when the start lights go out.
- If a tyre is outside the box when the lights go out, a chat message says so. Nothing is checked while the lines are hidden.
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
FINAL_CHAT=1
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

Procedure: the race starts, the game's lights go out, drivers drive the formation lap and park in their boxes, an admin starts the start lights, the boxes disappear at lights out and anyone outside is named in chat.

## Settings (all optional, in `[GRIDBOX]`)

| Key | Default | Meaning |
|---|---|---|
| STYLE | BOX | `BOX` lines + position text, `TEXT` only the position text (nothing is checked then) |
| FINAL_CHAT | 1 | name drivers who are outside at lights out |
| LIVE_CHAT | 0 | also write to chat while a driver sits outside before the lights |
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
