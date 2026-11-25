#!/usr/bin/env python3
"""
Load test for webapp-cicd-service (no load balancer).
Hits task public IPs directly to drive CPU above the 15% autoscaling threshold.

Service:        webapp-cicd-cluster / webapp-cicd-service  (af-south-1)
Current tasks:  13.245.150.226:3001  |  13.244.99.126:3001
Scale trigger:  ECSServiceAverageCPUUtilization > 70%
Cooldowns:      60s scale-out / 60s scale-in
Task range:     1 → 3

Timeline:
  ~0–30s   : CPU spikes above 70%
  ~90s     : Task 2 starts (60s cooldown)
  ~150s    : Task 3 starts (another 60s cooldown)
  ~210s    : All 3 tasks running
  stop     : CPU drops, 60s scale-in cooldown, drains back to 1
"""

import threading
import time
import urllib.request

# Hit BOTH current task IPs — load is spread across all running tasks
TARGET_URLS = [
    "http://13.245.150.226:3001/",
    "http://13.244.99.126:3001/",
]

THREADS_PER_URL = 50   # 50 threads × 2 URLs = 100 total workers
DURATION        = 480  # 8 min — well past the 2→3 scale-out + observation window
INTERVAL        = 0.02 # tight loop to keep CPU elevated even as tasks multiply

stop_event = threading.Event()
counters   = {"ok": 0, "err": 0}
lock       = threading.Lock()

def worker(url):
    while not stop_event.is_set():
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                r.read()
            with lock:
                counters["ok"] += 1
        except Exception:
            with lock:
                counters["err"] += 1
        time.sleep(INTERVAL)

print(f"Starting load test → {TARGET_URLS}")
print(f"{THREADS_PER_URL} threads × {len(TARGET_URLS)} URLs = {THREADS_PER_URL * len(TARGET_URLS)} total workers for {DURATION}s")
print("─" * 60)
print("Expected timeline:")
print("  ~90s  → Task 2 starts  (watch ECS console)")
print("  ~150s → Task 3 starts")
print("  ~210s → All 3 tasks running ✓")
print("─" * 60 + "\n")

threads = []
for url in TARGET_URLS:
    for _ in range(THREADS_PER_URL):
        t = threading.Thread(target=worker, args=(url,), daemon=True)
        threads.append(t)
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
