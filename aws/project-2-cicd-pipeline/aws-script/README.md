# `aws_setup.sh` — AWS Infrastructure Setup Script

This README documents [`aws_setup.sh`](aws_setup.sh), the bootstrap script in
this directory. The script is a one-shot, re-runnable
Bash program that creates the AWS resources required by the GitHub Actions
CI/CD pipeline in this repository.

It does **not** deploy the application image. It builds the empty "shell" of the
stack — ECR, ECS, IAM, networking, and logging — and registers an initial task
definition that uses `nginx:latest` as a placeholder. The first successful
pipeline run replaces that image with the real app.

---

## 📋 What It Creates

| # | Resource | Default name / value | Reused if it already exists? |
| --- | --- | --- | --- |
| 1 | Amazon ECR repository | `my-webapp` | Yes (`scanOnPush=true`) |
| 2 | ECS task execution role | `ecsTaskExecutionRole-webapp-cicd-cluster` | Yes |
| 3 | ECS Fargate cluster | `webapp-cicd-cluster` | Yes |
| 4 | VPC & subnets | existing `projects-vpc` | Always existing (never created) |
| 5 | Security group | `webapp-cicd-sg` | Yes |
| 6 | CloudWatch log group | `/ecs/webapp-cicd-task` | Yes |
| 7 | ECS task definition | family `webapp-cicd-task` | No — a **new revision** each run |
| 8 | ECS service | `webapp-cicd-service` | Yes |
| 9 | GitHub Actions IAM user | `github-actions-user` | Yes (new keys attempted each run) |

The script deliberately does **not** create a load balancer, a custom domain, or
a database. The Fargate task gets a public IP and the app is reached directly on
port `3001`, so the URL changes whenever ECS replaces the task.

---

## 🛠️ Prerequisites

* [AWS CLI](https://aws.amazon.com/cli/) v2, installed and configured
  (`aws configure` + `aws sts get-caller-identity` must succeed)
* [`jq`](https://jqlang.github.io/jq/) — used to parse the access key JSON
* Permissions to manage ECR, ECS, IAM, EC2 networking (VPCs, subnets, security
  groups), and CloudWatch Logs. For a throwaway learning account,
  `AdministratorAccess` is the simplest option.
* A VPC tagged `Name=projects-vpc` in the chosen region, **or** a default VPC to
  fall back to

The script starts with `set -e`, so it stops at the first failing command.

---

## 🚀 How to Run

From `aws/project-2-cicd-pipeline/aws-script/`:

```bash
chmod +x aws_setup.sh
./aws_setup.sh
```

Any configuration value can be overridden with an environment variable:

```bash
AWS_REGION=af-south-1 \
VPC_NAME=projects-vpc \
CLUSTER_NAME=webapp-cicd-cluster \
SERVICE_NAME=webapp-cicd-service \
TASK_FAMILY=webapp-cicd-task \
ECR_REPOSITORY=my-webapp \
GITHUB_USER_NAME=github-actions-user \
./aws_setup.sh
```

For debugging, run it with shell tracing:

```bash
bash -x aws_setup.sh
```

### Configuration variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLUSTER_NAME` | `webapp-cicd-cluster` | ECS cluster name; also used in the execution role name |
| `SERVICE_NAME` | `webapp-cicd-service` | ECS service name |
| `TASK_FAMILY` | `webapp-cicd-task` | ECS task definition family and log group suffix |
| `ECR_REPOSITORY` | `my-webapp` | Docker image repository name |
| `AWS_REGION` | `af-south-1` | Region for all resources (IAM is global) |
| `VPC_NAME` | `projects-vpc` | `Name` tag used to find an existing VPC and public subnets |
| `GITHUB_USER_NAME` | `github-actions-user` | IAM user whose keys are used by GitHub Actions |

---

## 🔍 Step-by-Step Walkthrough

1. **Preflight check** — `aws sts get-caller-identity` verifies that credentials
   work; the script exits with an error message otherwise.

2. **ECR repository** — creates the repository with image scanning on push, then
   reads back its `repositoryUri` (printed as `ECR_REGISTRY` at the end).

3. **ECS task execution role** — creates `ecsTaskExecutionRole-$CLUSTER_NAME`
   with an `ecs-tasks.amazonaws.com` trust policy and attaches the managed
   `AmazonECSTaskExecutionRolePolicy` so tasks can pull images and write logs.

4. **ECS cluster** — creates the cluster unless a cluster with that name is
   already present.

5. **Network discovery** — selects a VPC by `Name` tag, falling back to the
   account's default VPC. It then prefers subnets tagged
   `<VPC_NAME>-subnet-public*`, falling back to *all* subnets in the VPC.
   Subnet IDs are joined into the comma-separated list ECS expects.

6. **Security group** — finds or creates `webapp-cicd-sg` in the selected VPC.
   On creation it adds a single inbound rule: TCP `3001` from `0.0.0.0/0`.

7. **CloudWatch log group** — creates `/ecs/$TASK_FAMILY` if it is missing.
   Container stdout is sent here via the `awslogs` driver.

8. **Task definition** — registers a new Fargate revision (`awsvpc`, `256` CPU
   units, `512` MiB) with one container named `webapp`, port `3001`,
   `ENVIRONMENT=production`, and the `awslogs` configuration. The image is the
   `nginx:latest` placeholder.

9. **ECS service** — creates the service with `desired-count 1`, launch type
   `FARGATE`, and `assignPublicIp=ENABLED` so the task is reachable directly.

10. **GitHub Actions IAM user** — creates the user (if missing) with the
    `AmazonECS_FullAccess` and `AmazonEC2ContainerRegistryFullAccess` managed
    policies, then attempts to create an access key. Keys are parsed with `jq`;
    if AWS refuses (for example, the user already has the maximum of two keys),
    placeholder text is printed instead.

---

## 🔁 Re-running the Script

The script is written to be idempotent for named resources: existing ECR
repositories, roles, clusters, security groups, log groups, services, and users
are detected and reused.

Two things are **not** fully idempotent:

* **Task definitions** — `register-task-definition` always runs, so each
  invocation creates a new revision. Old revisions remain registered (they can
  be deregistered during cleanup).
* **Access keys** — `create-access-key` is attempted every time. IAM allows at
  most two keys per user; once the limit is reached the script prints
  placeholder values and asks you to reuse or rotate existing keys.

Also note that the inbound `3001` rule is only added when the security group is
first created; an existing group is assumed to already be configured.

---

## 🔑 Output: GitHub Secrets

On success the script prints the values to add under **Settings → Secrets and
variables → Actions** in the GitHub repository:

| Secret | Source |
| --- | --- |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | The newly created IAM access key |
| `AWS_REGION` | The region used by the script |
| `ECR_REPOSITORY` | The ECR repository name |
| `ECR_REGISTRY` | The repository URI (informational; the workflow uses `amazon-ecr-login`) |
| `ECS_CLUSTER` | The ECS cluster name |
| `ECS_SERVICE` | The ECS service name |
| `ECS_TASK_DEFINITION` | The task definition family |

> ⚠️ The secret access key is printed to the terminal in plain text. Treat the
> output as sensitive: do not paste it into logs or issues, and store it only as
> an encrypted GitHub Actions secret.

---

## ⚠️ Security and Cost Notes

* The security group opens port `3001` to `0.0.0.0/0`. This is convenient for a
  learning project but not appropriate for sensitive workloads; restrict the
  CIDR or put an ALB in front of the service for production use.
* The GitHub Actions user receives broad managed policies (`ECS` and `ECR`
  full access). Scope these down for longer-lived environments.
* Fargate and ECR can incur small charges while the stack runs. Use the cleanup
  commands in the [main README](../README.md#-clean-up-resources) when finished.
* The security group name is hardcoded to `webapp-cicd-sg`, so separate staging
  and production runs in the same VPC will share one security group.

---

## 🧰 Troubleshooting

| Symptom | Fix |
| --- | --- |
| `❌ AWS CLI not configured` | Run `aws configure`, then `aws sts get-caller-identity` |
| `jq: command not found` | Install `jq` and re-run |
| `AccessDenied` on a resource | Grant permissions for ECR, ECS, IAM, EC2 networking, and CloudWatch Logs |
| `No VPC found in <region>` | Create a VPC tagged `projects-vpc` or set `VPC_NAME` to an existing VPC |
| `No subnets found in VPC` | Tag subnets as `<VPC_NAME>-subnet-public*` or verify the VPC has subnets |
| `Could not create new access keys` | Delete an old key or reuse an existing one (IAM limit: two keys per user) |
| Task will not serve the app yet | Expected: the initial image is `nginx:latest` until the first pipeline deploy |

---

## 🔗 Related Documentation

* [Main project README](../README.md) — full walkthrough, pipeline details, and cleanup commands
* [Terraform README](../terraform/README.md) — import blocks that adopt these resources for day-two management
* [Deployment workflow](../../../.github/workflows/deploy-aws.yml) — the CI/CD pipeline that consumes the printed secrets
