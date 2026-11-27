# Load Testing ECS Service Autoscaling

## `load_test.py`

A dependency-free Python load generator that drives CPU on the ECS service so
its CPU-based autoscaling policy can scale it out.

Traffic goes through the **Application Load Balancer**, which spreads requests
across every healthy task. That matters for a scale-out test: as ECS adds
tasks, the ALB sends each one work automatically, so no per-task IP juggling is
needed when tasks are replaced.

### What it does

- Starts `THREADS` worker threads against the ALB URL.
- Each worker requests `TARGET_URL` (`/`, the dashboard — heavier than
  `/health`, so it burns more CPU per request) with a 5s timeout, then sleeps
  `INTERVAL` seconds.
- Counts successes and errors and prints a progress line every 5 seconds.
- Prints milestone lines at 1, 3, 5 and 8 minutes so a redirected log still
  shows that the load stayed up.
- Runs for 10 minutes by default, then stops every worker and prints totals.

Only the Python standard library is used (`threading`, `time`,
`urllib.request`), so nothing needs installing.

### Why it must run for several minutes

The 30% target-tracking policy does **not** react to a single spike:

1. Average CPU must stay above **30% for 3 consecutive 1-minute periods**
   before the CloudWatch alarm fires.
2. ECS then provisions a new task and waits for it to pass health checks
   (~60–90s more).

So the first new task shows up roughly **3 minutes after sustained load
starts**, and the service needs load to keep going after that. A previous run
stopped after ~6 minutes and the load fell off just as scaling should have
happened, so the alarm reset and nothing scaled.

**Do not stop the script early.** If it exits before the alarm has seen three
breaching periods, `desiredCount` will not change.

### Configuration

Edit the constants at the top of `load_test.py`:

| Constant | Default | Meaning |
| --- | --- | --- |
| `TARGET_URL` | ALB DNS name | Stable ALB endpoint (unlike a task public IP) |
| `THREADS` | `100` | Concurrent workers — held CPU at 63–66% on one task |
| `DURATION` | `600` | Seconds to run (10 min); keep at 300+ or the alarm may not fire |
| `INTERVAL` | `0.02` | Sleep between requests per worker |
| `MIN_DURATION` | `300` | Prints a warning if `DURATION` is set below this |

`THREADS = 100` is more than enough to cross 30%. If CPU only reached ~63–66%
on one task, it will still be well above the threshold while the service is at
one or two tasks.

```python
TARGET_URL = "http://webapp-cicd-loadbalancer-1259148409.af-south-1.elb.amazonaws.com/"
```

The ALB DNS name is stable across deployments. You only need to change it if
the load balancer itself is recreated. Find the current one with:

```sh
aws elbv2 describe-load-balancers --region af-south-1 \
  --query 'LoadBalancers[].DNSName' --output text
```

### Running it

```sh
cd autoscaling
python3 load_test.py
```

To log a full run while still seeing it live:

```sh
python3 -u load_test.py 2>&1 | tee /tmp/load_test.log
```

If you redirect without `tee`, progress is written on one line (carriage
return), so convert it before reading:

```sh
python3 -u load_test.py > /tmp/load_test.log 2>&1
tr '\r' '\n' < /tmp/load_test.log | tail
```

In a second terminal, watch the task count change. The ECS console's **Tasks**
tab shows the same thing:

```sh
watch -n 10 "aws ecs describe-services --cluster webapp-cicd-cluster \
  --service webapp-cicd-service --region af-south-1 \
  --query 'services[0].[desiredCount,runningCount]' --output text"
```

### What to expect

With `THREADS = 100` and the 30% target:

- CPU climbs to roughly **63–66%** on a single task — comfortably above 30%.
- The scale-out alarm fires after **3 consecutive 1-minute periods**; task 2
  starts around the **3-minute mark**.
- ECS brings task 2 to `RUNNING`/healthy about **1–2 minutes later**.
- The ALB then sends load to both tasks, so **average service CPU drops**. If
  it falls below 30%, the policy may scale in again. That is normal
  target-tracking behaviour, not a failed test: the same load is now spread
  over more tasks. Raise `THREADS` if you want to hold three tasks above 30%.

Watch for these in the ECS service events:

```
service webapp-cicd-service has started 2 tasks: ...
(service webapp-cicd-service) was unable to place a task ...
```

### Notes and caveats

- **30% is the live policy target.** `terraform/variables.tf` and
  `aws-script/aws_setup.sh` now both default to `30`, so the two paths stay in
  sync with the console policy. Override `autoscaling_cpu_target` in a
  `terraform.tfvars` (or `AUTOSCALING_CPU_TARGET` for the script) if you change
  the live target again.
- **Scale-in is not instant.** After the load ends, CPU drops immediately, but
  `desiredCount` returns to 1 only after the scale-in cooldown and evaluation
  window. The extra task keeps running (and billing) during that time.
- **Average CPU falls as tasks are added.** Service CPU is the average across
  tasks, not the busiest task. Scaling out can therefore bring the metric back
  under the target and trigger scale-in. More threads (more load) is the fix
  when you want to keep the maximum task count up.
- **Autoscaling must exist.** This script only creates load. If no
  Application Auto Scaling target/policy is registered for the service,
  `desiredCount` will not change.

## Files

| File | Purpose |
| --- | --- |
| `load_test.py` | Python load generator (this document). |
