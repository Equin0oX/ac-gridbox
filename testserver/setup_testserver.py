# Builds a throw-away local AC server for testing gridbox.lua with ONE client (GridBox only reads the own car, so one driver is enough).
# Lives outside OneDrive on purpose (a junction to the game content inside OneDrive could get synced).
# usage: python gridbox\testserver\setup_testserver.py      (safe to re-run: rewrites cfg, welcome text and the deployed script)
# then:  F:\gridbox_testserver\run_server.bat   and join  acmanager://race/online/join?ip=127.0.0.1&httpPort=8091
# Sessions: Practice 3 min (join and load in here), then a 20-lap Race (Bowman Gray is ~15 s a lap: room for several formation laps)
# with the server's minimum 20 s grid wait, 10 s after the race, then it loops.
# The session timers run from server start even with nobody connected, so join right after starting the server.
# The admin password is made up on every run and printed at the end: in the game chat type /admin <password>, then use /next_session
# to skip the practice and /restart_session to rerun the current session. The server listens on all network interfaces, so the
# password must not be a known one.
import base64, os, secrets, shutil, subprocess, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
# Your Assetto Corsa folder and where the throw-away server goes; set the environment variables AC_GAME and GRIDBOX_TESTSERVER to
# override. CAR and TRACK must be installed in your game (the skins in ENTRY_LIST are only labels for the server): edit them below.
GAME = os.environ.get("AC_GAME", r"F:\SteamLibrary\steamapps\common\assettocorsa")
DEST = os.environ.get("GRIDBOX_TESTSERVER", r"F:\gridbox_testserver")
CAR = "tatuus_ft_60K"
TRACK = "aa_bgs"  # Bowman Gray Stadium, a short oval: quick formation laps
SCRIPT_SRC = os.path.join(HERE, "..", "gridbox.lua")
SCRIPT_DST = os.path.join(GAME, "extension", "lua", "online", "gridbox.lua")  # SCRIPT = gridbox.lua is read from here

# Section names must be the literal [SCRIPT_...] (as on the Rain Racers server); with custom names (SCRIPT_GRIDBOX) the game parsed the
# extra options but started no script. The CSP-only track name below was changed at the same time, so which of the two matters is not
# separated.
EXTRA_OPTIONS = """[SCRIPT_...]
SCRIPT = gridbox.lua

[SCRIPT_...]
SCRIPT = "https://raw.githubusercontent.com/tetematete/OSRLUASNIPPETS/refs/heads/main/Server%20Scripts/startLights.lua"

[STARTLIGHTS]
PENALTY_TYPE=-1
RANDOM_DELAY_RANGE=1,5
ADMIN_ONLY=0
SEQUENCE_LENGTH=10
SEQUENCE_START=5
REPLACE_AC_START=0
DEBUG_MODE=0
F1_STYLE=0

[GRIDBOX]
FINAL_REPORT=1
DEBUG=1
"""

# TRACK=csp/<build>/../<options>/../<track> is the CSP-only server name Content Manager writes (CSP wiki, "CSP-only servers and core options").
# 3465 is the build Rain Racers requires; the core option B (as on Rain Racers) is part of the same change.
SERVER_CFG = """[SERVER]
NAME=GridBox test
CARS=@CAR@
CONFIG_TRACK=
TRACK=csp/3465/../B/../@TRACK@
SUN_ANGLE=48
PASSWORD=
ADMIN_PASSWORD=@PASSWORD@
UDP_PORT=9610
TCP_PORT=9610
HTTP_PORT=8091
MAX_BALLAST_KG=0
QUALIFY_MAX_WAIT_PERC=120
PICKUP_MODE_ENABLED=1
LOOP_MODE=1
SLEEP_TIME=1
CLIENT_SEND_INTERVAL_HZ=15
SEND_BUFFER_SIZE=0
RECV_BUFFER_SIZE=0
RACE_OVER_TIME=10
KICK_QUORUM=85
VOTING_QUORUM=80
VOTE_DURATION=20
BLACKLIST_MODE=1
FUEL_RATE=100
DAMAGE_MULTIPLIER=0
TYRE_WEAR_RATE=100
ALLOWED_TYRES_OUT=2
ABS_ALLOWED=1
TC_ALLOWED=1
START_RULE=2
STABILITY_ALLOWED=0
AUTOCLUTCH_ALLOWED=1
TYRE_BLANKETS_ALLOWED=0
FORCE_VIRTUAL_MIRROR=1
REGISTER_TO_LOBBY=0
MAX_CLIENTS=2
NUM_THREADS=2
UDP_PLUGIN_LOCAL_PORT=0
UDP_PLUGIN_ADDRESS=
AUTH_PLUGIN_ADDRESS=
LEGAL_TYRES=SH;H;M
WELCOME_MESSAGE=cfg/welcome.txt

[PRACTICE]
NAME=Practice
TIME=3
IS_OPEN=1

[RACE]
NAME=Race
LAPS=20
WAIT_TIME=20
IS_OPEN=1

[DYNAMIC_TRACK]
SESSION_START=95
RANDOMNESS=0
SESSION_TRANSFER=90
LAP_GAIN=10

[WEATHER_0]
GRAPHICS=3_clear
BASE_TEMPERATURE_AMBIENT=18
BASE_TEMPERATURE_ROAD=22
VARIATION_AMBIENT=0
VARIATION_ROAD=0
"""

ENTRY = "[CAR_%d]\nMODEL=@CAR@\nSKIN=%s\nSPECTATOR_MODE=0\nDRIVERNAME=\nTEAM=\nGUID=\nBALLAST=0\n\n"
ENTRY_LIST = ENTRY % (0, "2FIS_BSB_45") + ENTRY % (1, "2FIS_BSB_21")

RUN_BAT = """@echo off
cd /d "%~dp0"
title GridBox test server (UDP/TCP 9610, HTTP 8091)
acServer.exe
pause
"""


def is_link(path):
    try:
        os.readlink(path)  # works for symlinks and directory junctions
        return True
    except OSError:
        return False


def welcome_text(welcome, ini):
    """CSP extra options hidden in the welcome message: UTF-8, zlib (level 6), base64 without '=', 32 tabs and $CSP0: in front, appended after the text."""
    blob = base64.b64encode(zlib.compress(ini.encode("utf-8"), 6)).decode("ascii").rstrip("=")
    return welcome + "\t" * 32 + "$CSP0:" + blob


def decode_welcome(text):
    blob = text.split("\t" * 32 + "$CSP0:", 1)[1]
    return zlib.decompress(base64.b64decode(blob + "=" * (-len(blob) % 4))).decode("utf-8")


def main():
    assert decode_welcome(welcome_text("hi\n", EXTRA_OPTIONS)) == EXTRA_OPTIONS, "welcome encoding does not round-trip"
    # mklink would happily link a folder that does not exist: check first, so a missing car shows up here and not later in the game
    for what, path in (("car " + CAR, os.path.join(GAME, "content", "cars", CAR)), ("track " + TRACK, os.path.join(GAME, "content", "tracks", TRACK)),
                       ("game server folder", os.path.join(GAME, "server", "acServer.exe"))):
        if not os.path.exists(path):
            sys.exit("not found: the %s (%s). Set AC_GAME to your assettocorsa folder or change CAR / TRACK at the top of this script." % (what, path))
    password = secrets.token_urlsafe(6)
    srv = os.path.join(GAME, "server")
    for sub in ("cfg", "logs\\session", "logs\\error", "system\\data", "manager"):
        os.makedirs(os.path.join(DEST, sub), exist_ok=True)
    if not os.path.exists(os.path.join(DEST, "acServer.exe")):  # also keeps a re-run possible while the server is running (exe is locked)
        shutil.copy2(os.path.join(srv, "acServer.exe"), DEST)
    shutil.copy2(os.path.join(srv, "system", "data", "surfaces.ini"), os.path.join(DEST, "system", "data"))
    for f in os.listdir(os.path.join(srv, "manager")):
        shutil.copy2(os.path.join(srv, "manager", f), os.path.join(DEST, "manager"))
    # content: only the Tatuus is linked (the game's own copy, read-only use, so server and client checksum the same data.acd).
    # The track is deliberately NOT linked: with TRACK=csp/3465/../B/../aa_bgs the server would resolve tracks\csp\aa_bgs, checksum it
    # and kick every client ("Checksum failed", the client has no such path). Unresolvable track files make the server skip those
    # checksums, which is what a local test needs.
    content = os.path.join(DEST, "content")
    cars = os.path.join(content, "cars")
    if is_link(cars):  # old layout: the whole cars folder was a junction into the CM server folder, never write through it
        os.rmdir(cars)
    os.makedirs(cars, exist_ok=True)
    os.makedirs(os.path.join(content, "tracks"), exist_ok=True)
    link = os.path.join(cars, CAR)
    if is_link(link):
        os.rmdir(link)  # removes the link only
    subprocess.run(["cmd", "/c", "mklink", "/J", link, os.path.join(GAME, "content", "cars", CAR)], check=True)
    for name, text in (("server_cfg.ini", SERVER_CFG), ("entry_list.ini", ENTRY_LIST),
                       ("welcome.txt", welcome_text("GridBox test server\n", EXTRA_OPTIONS))):
        text = text.replace("@CAR@", CAR).replace("@TRACK@", TRACK).replace("@PASSWORD@", password)
        with open(os.path.join(DEST, "cfg", name), "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    with open(os.path.join(DEST, "run_server.bat"), "w", newline="\r\n") as f:
        f.write(RUN_BAT)
    os.makedirs(os.path.dirname(SCRIPT_DST), exist_ok=True)
    shutil.copy2(SCRIPT_SRC, SCRIPT_DST)
    print("test server ready in", DEST)
    print("script deployed to", SCRIPT_DST)
    print("admin password (chat: /admin <password>):", password)
    print("the password only takes effect after the server is (re)started")


if __name__ == "__main__":
    sys.exit(main())
