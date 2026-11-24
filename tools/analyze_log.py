# Reads GridBox lines from one or more CSP logs (Documents\Assetto Corsa\logs\custom_shaders_patch.log, run with DEBUG=1) and prints
# what happened at a start: who was in the session, which box each car had, how every car moved around the lights-out, who was
# outside (recomputed from the tyre positions at the lights-out, not taken from anyone's own report) and what looks wrong.
# usage: python tools/analyze_log.py <log> [<more logs>]
import math, re, sys

LINE = re.compile(r"GridBox(?: v[\d.]+)?:? (?:t=(-?\d+) )?(.*)$")
NUM = r"(-?\d+(?:\.\d+)?)"
PATCH, TYRE_W, BOX_W, LINE_W = 0.1, 0.25, 2.4, 0.08  # script defaults (PATCH_M, a tyre's width, BOX_WIDTH_M, LINE_WIDTH_M)


def entries(paths):
    for path in paths:
        for raw in open(path, encoding="utf-8", errors="replace"):
            m = LINE.search(raw)
            if m and "GridBox" in raw:
                yield path, (int(m.group(1)) if m.group(1) else None), m.group(2).strip()


def margins(wheels, box):
    """over / side in metres (> 0: outside), the same maths as measure() in gridbox.lua, from tyre centres and the box's front line."""
    (lx, lz), (fx, fz) = box["line"], box["face"]
    rx, rz = fz, -fx
    hx = wheels[0][0] + wheels[1][0] - wheels[2][0] - wheels[3][0]
    hz = wheels[0][1] + wheels[1][1] - wheels[2][1] - wheels[3][1]
    n = math.hypot(hx, hz) or 1
    hx, hz = hx / n, hz / n
    c, s = abs(hx * fx + hz * fz), abs(hx * rx + hz * rz)
    tw, half = TYRE_W / 2, LINE_W / 2
    over = max((w[0] - lx) * fx + (w[1] - lz) * fz + PATCH / 2 * c + tw * s for w in wheels[:2]) - half
    side = max(abs((w[0] - lx) * rx + (w[1] - lz) * rz) + tw * c + PATCH / 2 * s - BOX_W / 2 for w in wheels) - half
    return over, side


def main(paths):
    out, problems = [], []
    P = out.append
    drivers = {}   # car index -> {"name", "model"}
    snaps = {}     # car index -> lights-out snapshot
    moved = {}     # car index -> ms from the lights-out
    lights_events, recorded, failed, dbg, errors = [], [], [], [], []
    last_t = None
    for path, t, text in entries(paths):
        if t is not None:
            last_t = t
        if "loaded, CSP build" in text:
            P("[%s] script loaded: %s" % (path.split("\\")[-1].split("/")[-1], text))
        elif "welcome received" in text:
            P("[welcome] " + text)
        elif text.startswith("session:") or text.startswith("start lights event") or text.startswith("lights out:") or text.startswith("boxes known"):
            P("t=%s %s" % (t, text))
        elif text.startswith("recorded"):
            recorded.append((t, text)); P("t=%s %s" % (t, text))
        elif text.startswith("no box recorded"):
            failed.append((t, text)); P("t=%s %s" % (t, text))
        elif text.startswith("driver "):
            dbg.append((t, text)); P("t=%s %s" % (t, text))
        elif text.startswith("report received"):
            P("t=%s %s" % (t, text))
        elif "disagrees" in text:
            problems.append("t=%s %s" % (t, text))
        elif text.startswith("error:") or "log format error" in text:
            errors.append("t=%s %s" % (t, text))
        elif "event dropped" in text or "send refused" in text:
            problems.append("t=%s %s" % (t, text))
        elif text.startswith("at start lights: car") or text.startswith("car list: car"):
            m = re.match(r"(?:at start lights|car list): car \[(\d+)\] sid=(\S+) (.*) model=(\S+) race position", text)
            if m:
                drivers[int(m.group(1))] = {"name": m.group(3), "model": m.group(4), "sid": m.group(2)}
        elif text.startswith("car [") and "moved first" in text:
            m = re.match(r"car \[(\d+)\] .* moved first at " + NUM + " ms", text)
            if m:
                moved[int(m.group(1))] = float(m.group(2)); P("t=%s %s" % (t, text))
        elif text.startswith("lights-out snapshot"):
            idx = re.match(r"lights-out snapshot: car \[(\d+)\] sid=(\S+) (.*?) model=(\S+) v=" + NUM, text)
            wh = re.search(r"wheels((?: \(-?[\d.]+,-?[\d.]+\)){4})", text)
            box = re.search(r"box P(\d+) line=\(" + NUM + "," + NUM + r"\) face=\(" + NUM + "," + NUM + r"\) len=" + NUM, text)
            if idx and wh:
                i = int(idx.group(1))
                wheels = [tuple(map(float, p)) for p in re.findall(r"\((-?[\d.]+),(-?[\d.]+)\)", wh.group(1))]
                snaps[i] = {"name": idx.group(3), "model": idx.group(4), "v": float(idx.group(5)), "wheels": wheels, "pos": int(box.group(1)) if box else None,
                            "box": {"line": (float(box.group(2)), float(box.group(3))), "face": (float(box.group(4)), float(box.group(5)))} if box else None}
                drivers.setdefault(i, {"name": idx.group(3), "model": idx.group(4)})
    P("")
    P("=== cars at the lights-out (tyres recomputed against each shared box) ===")
    for i in sorted(snaps):
        s = snaps[i]
        if s["box"]:
            over, side = margins(s["wheels"], s["box"])
            verdict = "OUTSIDE" if over > 0 or side > 0 else "inside"
            P("car [%d] %-22s %-20s P%-2s v=%5.1f km/h over=%+.3f side=%+.3f m  %s%s" % (i, s["name"], s["model"], s["pos"], s["v"], over, side, verdict,
              ("  moved %+.0f ms from the lights-out" % moved[i]) if i in moved else ""))
            if over > 0 or side > 0:
                problems.append("car [%d] %s is %s at the lights-out (over %+.3f, side %+.3f)" % (i, s["name"], verdict, over, side))
        else:
            P("car [%d] %-22s %-20s no box known to this log, v=%.1f km/h" % (i, s["name"], s["model"], s["v"]))
            problems.append("car [%d] %s: no box known at the lights-out (share lost, script not running, or not recorded)" % (i, s["name"]))
    for i in sorted(moved):
        if moved[i] < 0:
            problems.append("car [%d] %s moved %.0f ms BEFORE the lights-out" % (i, drivers.get(i, {}).get("name", "?"), -moved[i]))
    for t, text in failed:
        problems.append("t=%s %s" % (t, text))
    for t, text in recorded:
        m = re.search(r"slotErr=(\S+)", text)
        if m and m.group(1) != "-" and float(m.group(1)) > 0.2:
            problems.append("t=%s large slot error: %s" % (t, text[:160]))
    problems += ["ERROR " + e for e in errors]
    P("")
    P("=== things to look at ===")
    for p in problems or ["nothing flagged"]:
        P("- " + p)
    print("\n".join(out))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__ or "usage: python tools/analyze_log.py <log> [<more logs>]")
    main(sys.argv[1:])
