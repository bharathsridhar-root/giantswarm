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

    # Mean-reverting walk (pulls back toward baseline every tick) with
    # symmetric noise, wider while spiking, plus a hard clamp as a safety
    # net -- an earlier asymmetric-noise version had no upper bound and
    # drifted unboundedly upward over time regardless of spikes.
    temp_target = base["temperature"] + (35 if spiking else 0)
    s["temperature"] += (temp_target - s["temperature"]) * 0.15 + random.uniform(-2, 2)
    s["temperature"] = min(120, max(base["temperature"] - 10, s["temperature"]))

    vib_target = base["vibration"] + (1.8 if spiking else 0)
    s["vibration"] += (vib_target - s["vibration"]) * 0.15 + random.uniform(-0.05, 0.05)
    s["vibration"] = min(5.0, max(0.3, s["vibration"]))

    thr_target = base["throughput"] * (0.4 if spiking else 1.0)
    s["throughput"] += (thr_target - s["throughput"]) * 0.15 + random.uniform(-1, 1)
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
