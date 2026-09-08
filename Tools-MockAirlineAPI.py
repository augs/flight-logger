#!/usr/bin/env python3
"""Mock in-flight WiFi API, for testing flight-logger without flying.

Serves a United-shaped response at the same path the bundled config uses, and
simulates a whole flight rather than returning a fixed payload: climb, cruise,
descent, and finally the on-ground flag. That matters because the interesting
behaviour is all temporal — metadata populating on the first poll, altitude
producing a real curve, and auto-stop firing only once on-ground has held for
three consecutive polls.

Usage:
    python3 Tools-MockAirlineAPI.py                 # 20-minute flight
    python3 Tools-MockAirlineAPI.py --minutes 5     # compressed
    python3 Tools-MockAirlineAPI.py --airline delta # different response shape

Then in the app: Settings -> Test API URL -> http://<this-machine-ip>:8080/portal/r/getAllSessionData

The phone must be on the same WiFi. The script prints the URL to use on start.
"""

import argparse
import json
import math
import socket
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

START = time.time()
ARGS = None


def local_ip() -> str:
    """Best-effort LAN address, so the printed URL is usable from the phone."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))          # no packets sent; just picks a route
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def profile(elapsed: float, total: float):
    """Altitude/speed/temperature for a point in the simulated flight.

    Deliberately a smooth climb and descent rather than a step: a real profile
    is what makes the chart work worth looking at, and a step would hide
    interpolation or ordering bugs.
    """
    frac = min(max(elapsed / total, 0.0), 1.0)
    cruise_ft = 35000.0

    if frac < 0.15:                     # climb
        altitude = cruise_ft * (frac / 0.15)
        on_ground = frac < 0.02
    elif frac < 0.80:                   # cruise, with gentle step changes
        altitude = cruise_ft + 1000.0 * math.sin((frac - 0.15) * 12)
        on_ground = False
    elif frac < 0.98:                   # descent
        altitude = cruise_ft * (1.0 - (frac - 0.80) / 0.18)
        on_ground = False
    else:                               # landed
        altitude = 12.0
        on_ground = True

    altitude = max(altitude, 0.0)
    speed = 0.0 if on_ground else 120.0 + (altitude / cruise_ft) * 400.0
    # Roughly -2C per 1000 ft from a 15C surface, expressed in F like United.
    temp_c = 15.0 - (altitude / 1000.0) * 2.0
    remaining = max(0.0, (total - elapsed) / 60.0)

    return altitude, speed, temp_c * 9 / 5 + 32, on_ground, remaining


def united_body(alt, speed, temp_f, on_ground, remaining):
    """United sends every numeric as a *string* — the shape that broke parsing."""
    return {
        "flifo": {
            "originAirportCode": "EWR",
            "destinationAirportCode": "SFO",
            "flightNumber": "1885",
            "flightStatus": "On Ground" if on_ground else "In Flight",
            "groundSpeedMPH": f"{speed:.0f}",
            "airTemperatureF": f"{temp_f:.0f}",
            "altitudeFt": f"{alt:.0f}",
            "altitudeMeters": f"{alt * 0.3048:.0f}",
            "aircraftModel": "Boeing 777-200",
            "onGround": on_ground,
            "timeRemainingToDestination": round(remaining),
        }
    }


def delta_body(alt, speed, temp_f, on_ground, remaining):
    """A deliberately different shape: real numbers, flat-ish keys, nested leg.

    Not a claim about Delta's actual API — it exists to prove a second config
    with different paths and types works without code changes, which is the
    whole premise of the plugin system.
    """
    return {
        "flightInfo": {
            "legs": [{
                "departure": {"code": "ATL"},
                "arrival": {"code": "LAX"},
                "flight": {"number": 1234, "equipment": "Airbus A321"},
                "telemetry": {
                    "altitude": round(alt),
                    "groundSpeed": round(speed),
                    "outsideAirTempC": round((temp_f - 32) * 5 / 9),
                    "weightOnWheels": "true" if on_ground else "false",
                    "minutesRemaining": round(remaining),
                },
                "status": "LANDED" if on_ground else "ENROUTE",
            }]
        }
    }


BODIES = {"united": united_body, "delta": delta_body}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        elapsed = time.time() - START
        total = ARGS.minutes * 60
        alt, speed, temp_f, on_ground, remaining = profile(elapsed, total)
        body = BODIES[ARGS.airline](alt, speed, temp_f, on_ground, remaining)

        payload = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

        phase = "GROUND" if on_ground else "AIR"
        print(f"  t+{elapsed:6.0f}s  {phase:6}  {alt:7.0f} ft  {speed:5.0f} mph  "
              f"{remaining:5.1f} min left   <- {self.path}")

    def log_message(self, *_):
        pass                                    # the line above is the useful one


def main():
    global ARGS
    parser = argparse.ArgumentParser()
    parser.add_argument("--minutes", type=float, default=20, help="simulated flight length")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--airline", choices=sorted(BODIES), default="united")
    ARGS = parser.parse_args()

    url = f"http://{local_ip()}:{ARGS.port}/portal/r/getAllSessionData"
    print(f"Mock {ARGS.airline} API — {ARGS.minutes:g} minute flight")
    print(f"Set Settings -> Test API URL to:\n    {url}\n")
    print("Any path is served, so a config's real path works unchanged.\n")

    HTTPServer(("0.0.0.0", ARGS.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
