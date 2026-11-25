# Load Testing ECS Service Autoscaling

## `load_test.py`

A dependency-free Python load generator that drives CPU on the ECS task so the
service's CPU-based autoscaling policy can scale it out.

There is no load balancer in this project: the task is reached directly on port
3001 through its public IP, and ECS service CPU is measured inside the task's
cgroup. So the load has to hit the app itself — traffic from CloudShell or an
EC2 instance does not move `ECSServiceAverageCPUUtilization` unless it reaches
the task.

### What it does

- Starts `THREADS` worker threads.
- Each worker requests `TARGET_URL` (`/`, the dashboard — heavier than
  `/health`, so it burns more CPU per request) with a 5s timeout, then sleeps
  `INTERVAL` seconds.
- Counts successes and errors and prints a progress line every 5 seconds.
- Stops every worker after `DURATION` seconds and prints the totals.

Only the Python standard library is used (`threading`, `time`,
`urllib.request`), so nothing needs installing.

### Configuration

Edit the constants at the top of `load_test.py`:

| Constant | Default | Meaning |
| --- | --- | --- |
| `TARGET_URL` | `http://13.245.179.127:3001/` | Task public IP and port |
| `THREADS` | `50` | Concurrent workers |
| `DURATION` | `300` | Seconds to run |
| `INTERVAL` | `0.05` | Sleep between requests per worker |

`TARGET_URL` is hardcoded to one task, so update it whenever the task is
replaced (deploy, restart, or a scale event) — the public IP changes. To find
the current one:

```sh
TASK=$(aws ecs list-tasks --cluster webapp-cicd-cluster \
  --service-name webapp-cicd-service --desired-status RUNNING \
  --region af-south-1 --query 'taskArns[0]' --output text)

ENI=$(aws ecs describe-tasks --cluster webapp-cicd-cluster --tasks "$TASK" \
  --region af-south-1 \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value | [0]' \
  --output text)

aws ec2 describe-network-interfaces --network-interface-ids "$ENI" \
  --region af-south-1 \
  --query 'NetworkInterfaces[0].Association.PublicIp' --output text
```

### Running it

```sh
cd autoscaling
python3 load_test.py
```

Progress is printed on one line (carriage return), so a redirected log needs
`tr` to read it line by line:

```sh
python3 -u load_test.py > /tmp/load_test.log 2>&1
tr '\r' '\n' < /tmp/load_test.log | tail
```

### Measured result

Run against a task with `cpu = 256` (0.25 vCPU), 70% CPU target, 1 → 3 task
range:

```
Starting load test → http://13.245.179.127:3001/
50 threads for 300s

[   0s]  OK:      34  Errors:     0
[  20s]  OK:   16071  Errors:     0
[ 200s]  OK:  178881  Errors:     0
[ 295s]  OK:  265276  Errors:     0

Done.  OK: 269836  Errors: 0
```

- **269,836 requests in 300s ≈ 900 req/s**, zero errors.
- CPU stayed high enough for the policy to act: ECS logged
  `has started 2 tasks` and `desiredCount` went **1 → 3**.
- The two new tasks reached `RUNNING`; the deployment reported `COMPLETED`.

### Notes and caveats

- **300 seconds is marginal.** In the run above the scale-out was recorded
  ~19 seconds *after* the load stopped — it only fired because the last
  one-minute CPU datapoint was still high. Target tracking needs a few
  consecutive breaching datapoints plus time to start tasks, so give the load
  10–15 minutes when you want a comfortable margin.
- **Only one task receives load.** The script targets a single IP. When the
  service scales to 3, the average CPU becomes roughly one task at 100% and two
  near 0% (~33%). That stays above a 15% target, but with a higher target
  (e.g. 60%) it would look like the service is under-utilized and the policy
  could scale back in. To keep every task busy, run the script once per task IP.
- **Scale-in is not instant.** After the load ends, CPU drops immediately, but
  `desiredCount` returns to 1 only after the scale-in cooldown and evaluation
  window. The task keeps running (and billing) during that time.
- **Autoscaling must exist.** This script only creates load. If no
  Application Auto Scaling target/policy is registered for the service,
  `desiredCount` will not change. The policy is not defined in `terraform/`;
  if it was created in the console it lives outside Terraform's state.

## Files

| File | Purpose |
| --- | --- |
| `load_test.py` | Python load generator (this document). |
