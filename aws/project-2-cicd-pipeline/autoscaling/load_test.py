#!/usr/bin/env python3
"""
Load test for webapp-cicd-service (no load balancer).
Hits the task's public IP directly to drive CPU above the 15% autoscaling threshold.

Service:        webapp-cicd-cluster / webapp-cicd-service  (af-south-1)
Target:         http://13.245.138.123:3001/
Scale trigger:  ECSServiceAverageCPUUtilization > 15%
Cooldowns:      60s scale-out / 60s scale-in
Task range:     1 → 3

Timeline:
  ~0–30s   : CPU spikes above 15%
  ~90s     : Task 2 starts (60s cooldown)
  ~180s    : Task 3 starts (another 60s cooldown)
  ~240s    : All 3 tasks running — observe in ECS console
  stop     : CPU drops, 60s scale-in cooldown, drains back to 1
"""

import threading
import time
import urllib.request

TARGET_URL = "http://13.245.138.123:3001/"
THREADS    = 80      # increased to ensure CPU spikes hard across all tasks
DURATION   = 600     # 10 min — enough to reach 3 tasks AND observe them running
INTERVAL   = 0.02    # tighter loop = more requests per thread

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
print(f"{THREADS} threads for {DURATION}s")
print("─" * 55)
print("Expected timeline:")
print("  ~90s  → Task 2 starts")
print("  ~180s → Task 3 starts")
print("  ~240s → All 3 tasks running (check ECS console)")
print("─" * 55 + "\n")

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
