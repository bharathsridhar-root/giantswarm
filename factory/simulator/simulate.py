import random
import time

from prometheus_client import Gauge, start_http_server

MACHINES = ["press-1", "press-2", "cnc-1", "conveyor-1"]

temperature = Gauge(
    "factory_machine_temperature_celsius", "Machine temperature", ["machine"]
)
vibration = Gauge(
    "factory_machine_vibration_index", "Machine vibration index (baseline ~1.0)", ["machine"]
)
throughput = Gauge(
    "factory_machine_throughput_units_per_min", "Units produced per minute", ["machine"]
)

BASELINE = {
    m: {"temperature": 55.0, "vibration": 1.0, "throughput": 40.0} for m in MACHINES
}
state = {m: dict(BASELINE[m]) for m in MACHINES}
spiking_until = {m: 0.0 for m in MACHINES}


def step(machine: str, now: float) -> None:
    s = state[machine]
    base = BASELINE[machine]

    # Occasionally kick off a spike on a random machine (demoable anomaly).
    if now > spiking_until[machine] and random.random() < 0.01:
        spiking_until[machine] = now + random.uniform(30, 90)

    spiking = now < spiking_until[machine]

    # Random walk back toward baseline, wider swings while spiking.
    drift = 8.0 if spiking else 1.5
    s["temperature"] += random.uniform(-drift, drift * 1.5)
    s["temperature"] = max(base["temperature"] - 10, s["temperature"])

    vib_drift = 0.6 if spiking else 0.05
    s["vibration"] += random.uniform(-vib_drift * 0.3, vib_drift)
    s["vibration"] = max(0.5, s["vibration"])

    if spiking:
        s["throughput"] -= random.uniform(0, 3)
    else:
        s["throughput"] += random.uniform(-1, 1)
    s["throughput"] = min(base["throughput"] * 1.1, max(0, s["throughput"]))

    temperature.labels(machine=machine).set(round(s["temperature"], 1))
    vibration.labels(machine=machine).set(round(s["vibration"], 2))
    throughput.labels(machine=machine).set(round(s["throughput"], 1))


if __name__ == "__main__":
    start_http_server(9877)
    while True:
        now = time.time()
        for m in MACHINES:
            step(m, now)
        time.sleep(5)
