#!/usr/bin/env python3
"""
Load test for webapp-cicd-service (no load balancer).
Hits the task's public IP directly to drive CPU above the 70% autoscaling threshold.

Service:        webapp-cicd-cluster / webapp-cicd-service  (af-south-1)
Target:         http://13.245.179.127:3001/
Scale trigger:  ECSServiceAverageCPUUtilization > 70%
Cooldowns:      60s scale-out / 60s scale-in
Task range:     1 → 3
"""

import threading
import time
import urllib.request

TARGET_URL = "http://13.245.179.127:3001/"
THREADS    = 50      # concurrent workers
DURATION   = 300     # seconds (5 min — enough to see scale-out + scale-in)
INTERVAL   = 0.05    # seconds between requests per thread

stop_event = threading.Event()
counters   = {"ok": 0, "err": 0}
lock       = threading.Lock()

def worker():
    while not stop_event.is_set():
        try:
            with urllib.request.urlopen(TARGET_URL, timeout=5) as r:
                r.read()
            with lock:
                counters["ok"] += 1
        except Exception:
            with lock:
                counters["err"] += 1
        time.sleep(INTERVAL)

print(f"Starting load test → {TARGET_URL}")
print(f"{THREADS} threads for {DURATION}s\n")

threads = [threading.Thread(target=worker, daemon=True) for _ in range(THREADS)]
for t in threads:
    t.start()

start = time.time()
while time.time() - start < DURATION:
    elapsed = int(time.time() - start)
    with lock:
        ok, err = counters["ok"], counters["err"]
    print(f"[{elapsed:>4}s]  OK: {ok:>7}  Errors: {err:>5}", end="\r")
    time.sleep(5)

stop_event.set()
for t in threads:
    t.join(timeout=2)

print(f"\n\nDone.  OK: {counters['ok']}  Errors: {counters['err']}")
print("Wait ~60s for scale-in cooldown — tasks will drain back to 1.")
