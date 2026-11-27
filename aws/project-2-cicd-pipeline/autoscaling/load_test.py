#!/usr/bin/env python3
"""
Load test for webapp-cicd-service via the Application Load Balancer.
The ALB spreads requests across every healthy task, so all tasks get load.

Service:        webapp-cicd-cluster / webapp-cicd-service  (af-south-1)
Target:         http://webapp-cicd-alb-267897426.af-south-1.elb.amazonaws.com/
Scale trigger:  ECSServiceAverageCPUUtilization > 30%
                (CloudWatch alarm: 3 consecutive 1-minute periods above 30%)
Cooldowns:      60s scale-out / 60s scale-in
Task range:     1 -> 3

Why this runs for 10 minutes:
  Scaling is neither instant nor triggered by a single spike:
    1. Average CPU must stay above 30% for 3 consecutive 1-minute periods.
    2. ECS then starts a new task and waits for it to pass health checks
       (~60-90s more).
  Expect the first scale-out roughly 3 minutes after the load starts.

  DO NOT stop the script early. If the load drops before the alarm has
  seen all three breaching periods, the alarm returns to OK and the
  service never scales. The previous run stopped after ~6 minutes and
  the load fell off right as scaling should have happened.

Timeline (100 threads, sustained load):
  ~0-60s    : CPU climbs to ~60-70% - well above the 30% threshold
  ~3 min    : Alarm fires; task 2 starts
  ~4-5 min  : Task 2 healthy and serving traffic
  ~5 min+   : If average CPU drops below 30% again, the policy may scale
              back in. That is normal target tracking - the same load is
              now spread across more tasks. Raise THREADS to keep more
              tasks busy (see "Notes" at the end of the output).
"""

import threading
import time
import urllib.request

TARGET_URL   = "http://webapp-cicd-alb-267897426.af-south-1.elb.amazonaws.com/"
THREADS      = 100   # plenty: 100 threads held CPU at 63-66% on one task
DURATION     = 600   # 10 min - covers 3 breaching periods + task provisioning
INTERVAL     = 0.02  # tight loop to keep CPU elevated as tasks multiply
MIN_DURATION = 300   # below this the 30% alarm may never fire

# Milestone messages printed on their own line so redirected logs stay readable.
MILESTONES = [
    (60,  "CPU should now be well above the 30% threshold"),
    (180, "~3 min of sustained load - the alarm should have fired by now"),
    (300, "5 min sustained - check the ECS Tasks tab for new tasks"),
    (480, "8 min sustained - waiting out the last evaluation periods"),
]

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

if DURATION < MIN_DURATION:
    print(f"WARNING: DURATION={DURATION}s is below {MIN_DURATION}s.")
    print("The 30% alarm needs 3 consecutive 1-minute periods, then ECS needs")
    print("time to start a task. The service may not scale before the load ends.\n")

print(f"Starting load test → {TARGET_URL}")
print(f"{THREADS} threads for {DURATION}s ({DURATION / 60:.0f} min) - do not stop early")
print("─" * 60)
print("Expected timeline:")
print("  ~60s  → CPU well above 30%")
print("  ~3min → Alarm fires, task 2 starts  (watch ECS Tasks tab)")
print("  ~4-5min → Task 2 healthy and serving traffic")
print("─" * 60)
print("Watch desired vs running tasks in a second terminal:")
print("  watch -n 10 \"aws ecs describe-services --cluster webapp-cicd-cluster \\")
print("    --service webapp-cicd-service --region af-south-1 \\")
print("    --query 'services[0].[desiredCount,runningCount]' --output text\"")
print("─" * 60 + "\n")

threads = [threading.Thread(target=worker, daemon=True) for _ in range(THREADS)]
for t in threads:
    t.start()

start = time.time()
next_milestone = 0
try:
    while time.time() - start < DURATION:
        elapsed = int(time.time() - start)
        with lock:
            ok, err = counters["ok"], counters["err"]
        rps = ok / elapsed if elapsed > 0 else 0

        while next_milestone < len(MILESTONES) and elapsed >= MILESTONES[next_milestone][0]:
            print()
            print(f"[{elapsed:>4}s] >>> {MILESTONES[next_milestone][1]}")
            next_milestone += 1

        print(
            f"[{elapsed:>4}s/{DURATION}s]  OK: {ok:>7}  Errors: {err:>5}  "
            f"RPS: {rps:>6.1f}",
            end="\r",
        )
        time.sleep(5)
except KeyboardInterrupt:
    print("\n\nStopped early (Ctrl-C).")
    print("If this ran for less than ~3 minutes, the 30% alarm probably never")
    print("saw 3 consecutive breaching periods, so the service may not scale.")
finally:
    stop_event.set()
    for t in threads:
        t.join(timeout=2)

print(f"\n\nDone after {int(time.time() - start)}s."
      f"  OK: {counters['ok']}  Errors: {counters['err']}")
print("Scale-in is not instant: after the load stops the extra tasks stay")
print("until CPU has been below the target for the scale-in cooldown/evaluation")
print("window, then desiredCount drains back to 1.")
print("If average CPU fell below 30% once tasks were added, that is expected:")
print("the same load is spread across more tasks - raise THREADS for more.")
