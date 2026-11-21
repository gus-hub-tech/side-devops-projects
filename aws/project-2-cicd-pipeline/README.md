# Project 2: Automated Deployment Pipeline (AWS)

A small Express app that is tested, containerized, pushed to Amazon ECR, and
deployed to Amazon ECS Fargate by GitHub Actions.

> This project lives inside the `side-devops-projects` monorepo. The app is in
> `aws/project-2-cicd-pipeline/`; the workflow that deploys it is at the
> repository root in `.github/workflows/deploy-aws.yml`.

---

## 🌐 What This Creates

* An Express status dashboard with health and version endpoints
* A Docker image based on `node:24-alpine`
* An Amazon ECR repository with image scanning on push
* An ECS Fargate cluster and service running one task
* CloudWatch logging for the container
* A GitHub Actions pipeline that tests, builds, pushes, and deploys on pushes
  to `main` that touch this project
* A public app URL in the form `http://<task-public-ip>:3001`

The setup script does **not** create a load balancer, custom domain, or
database. The deployed URL is the public IP of the running Fargate task, so it
changes whenever ECS replaces the task. ECS Fargate and ECR can incur small
charges while the stack is running; use the cleanup section when finished.

---

## 📁 Repository Layout

```text
side-devops-projects/
├── .github/
│   └── workflows/
│       └── deploy-aws.yml          # CI/CD workflow for this project
└── aws/
    └── project-2-cicd-pipeline/
        ├── app.js                  # Express app, middleware, and routes
        ├── server.js               # Listener, PORT validation, shutdown
        ├── test/
        │   ├── app.test.js         # Route, header, and response tests
        │   └── server.test.js      # PORT validation tests
        ├── Dockerfile              # node:24-alpine image
        ├── .dockerignore
        ├── package.json
        ├── package-lock.json
        ├── aws_setup.sh            # Creates the AWS infrastructure
        └── README.md
```

Push and pull-request runs are filtered to changes under
`aws/project-2-cicd-pipeline/` (or the workflow file itself). Changes to other
projects in the monorepo do not trigger this pipeline. A manual
`workflow_dispatch` run can still be started from the Actions tab.

---

## 🛠️ Prerequisites

* [Node.js](https://nodejs.org/) 18 or newer (CI uses Node 18; the Docker image
  uses Node 24)
* [Docker](https://www.docker.com/products/docker-desktop)
* [AWS CLI](https://aws.amazon.com/cli/) v2, configured with credentials
* [`jq`](https://jqlang.github.io/jq/) — `aws_setup.sh` uses it to read the
  generated access keys
* [Git](https://git-scm.com/)
* A GitHub account and an AWS account

The AWS identity running `aws_setup.sh` needs permission to manage ECR, ECS,
IAM, EC2 networking (VPCs, subnets, and security groups), and CloudWatch Logs.
For a throwaway learning account, `AdministratorAccess` is the simplest option.

---

## ✅ Step 1: Run Locally

From `aws/project-2-cicd-pipeline/`:

```bash
npm install
npm start
```

Then open:

| URL | Purpose |
| --- | --- |
| <http://localhost:3001> | HTML status dashboard |
| <http://localhost:3001/health> | JSON health probe |
| <http://localhost:3001/api/info> | Runtime details |
| <http://localhost:3001/api/version> | App name, version, environment |

Run the test suite with:

```bash
npm test
```

`npm test` uses the built-in Node.js test runner (`node --test`) and Supertest.
The tests cover every route, the 404 fallback, security headers, request ID
handling, and invalid `PORT` values. They import the Express app directly, so
no port is opened during route tests.

---

## ✅ Step 2: Build and Run the Docker Image

```bash
docker build -t my-webapp .
docker run --rm -p 3001:3001 -e ENVIRONMENT=local my-webapp
```

Visit <http://localhost:3001> or check the health endpoint:

```bash
curl http://localhost:3001/health
```

The image uses `npm ci --omit=dev`, so only production dependencies are
installed. `.dockerignore` keeps `node_modules`, `.git`, logs, the README, and
the setup script out of the build context.

---

## ✅ Step 3: Create the AWS Infrastructure

```bash
aws configure
aws sts get-caller-identity
chmod +x aws_setup.sh
./aws_setup.sh
```

The script defaults to `af-south-1` and the existing `projects-vpc`. It creates
or reuses the following resources:

| Resource | Default name |
| --- | --- |
| ECR repository | `my-webapp` |
| ECS cluster | `webapp-cicd-cluster` |
| ECS service | `webapp-cicd-service` |
| ECS task definition family | `webapp-cicd-task` |
| CloudWatch log group | `/ecs/webapp-cicd-task` |
| Security group | `webapp-cicd-sg` (inbound TCP `3001` from `0.0.0.0/0`) |
| ECS execution role | `ecsTaskExecutionRole-webapp-cicd-cluster` |
| GitHub Actions IAM user | `github-actions-user` |

The script is designed to be re-runnable: existing resources are detected and
reused. Note that it registers a new task definition revision each time it runs,
and it creates new access keys only if the IAM user has fewer than two.

### VPC and subnet behavior

* It looks for a VPC tagged `Name=projects-vpc`.
* If that VPC is not found, it falls back to the account's default VPC.
* It prefers subnets tagged `projects-vpc-subnet-public*`; if none exist, it
  uses every subnet in the selected VPC.
* The service is created with `assignPublicIp=ENABLED` so the task can be
  reached directly on port `3001`.

Override any of the defaults with environment variables:

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

At the end, the script prints the values to use as GitHub secrets.

> The initial task definition uses the placeholder image `nginx:latest`. The
> service will not run your app until the first successful pipeline deployment
> replaces that image.

---

## ✅ Step 4: Add GitHub Repository Secrets

Go to **Settings → Secrets and variables → Actions** and add:

| Secret | Required | Default used by the workflow | Purpose |
| --- | --- | --- | --- |
| `AWS_ACCESS_KEY_ID` | Yes | — | GitHub Actions AWS access key |
| `AWS_SECRET_ACCESS_KEY` | Yes | — | GitHub Actions AWS secret key |
| `AWS_REGION` | No | `af-south-1` | AWS region |
| `ECR_REPOSITORY` | No | `my-webapp` | ECR repository name |
| `ECS_CLUSTER` | No | `webapp-cicd-cluster` | ECS cluster name |
| `ECS_SERVICE` | No | `webapp-cicd-service` | ECS service name |
| `ECS_TASK_DEFINITION` | No | `webapp-cicd-task` | ECS task definition family |

The setup script also prints `ECR_REGISTRY`. The workflow does not use that
value as a secret: it gets the registry from the
`aws-actions/amazon-ecr-login` action.

If you changed any names while running `aws_setup.sh`, set the matching secrets
so the workflow updates the correct resources. Secret names are case-sensitive.

---

## ✅ Step 5: Push and Deploy

Run these commands from the **repository root** (the directory containing
`.github/`), not from inside the project folder:

```bash
git add aws/project-2-cicd-pipeline
git commit -m "Update AWS CI/CD project"
git push origin main
```

What happens next:

* A push to `main` that touches `aws/project-2-cicd-pipeline/**` triggers the
  workflow.
* A pull request runs the **Test Application** job only.
* `workflow_dispatch` allows a manual run from the **Actions** tab.
* The **Deploy to AWS ECS** job runs only from `main`.

---

## 📊 What the Pipeline Does

### Test Application job

1. Checks out the repository.
2. Sets up Node.js 18 with npm caching.
3. Runs `npm ci`.
4. Runs `npm test` (the `node:test` + Supertest suite).
5. Builds the Docker image to verify the `Dockerfile`.

### Deploy to AWS ECS job

Runs only after the test job succeeds and only on `main`:

1. Validates that the required AWS secrets are present.
2. Configures AWS credentials.
3. Logs in to Amazon ECR.
4. Builds and pushes two image tags: the Git commit SHA and `latest`.
5. Downloads the current ECS task definition.
6. Replaces the `webapp` container image with the new image.
7. Deploys the new task definition to the ECS service and waits for stability.
8. Looks up the task's public IP and prints the app URL, health URL, and
   CloudWatch console link in the job log.

Look for output like:

```text
🚀 Deployment successful!
📱 Your app is live at: http://<public-ip>:3001
🏥 Health check: http://<public-ip>:3001/health
📊 API endpoint: http://<public-ip>:3001/api/info
```

---

## ✅ Step 6: Open the Deployed App

Use the URL printed by the workflow:

* App: `http://<public-ip>:3001`
* Health: `http://<public-ip>:3001/health`
* API info: `http://<public-ip>:3001/api/info`
* Version: `http://<public-ip>:3001/api/version`

To find the current public IP yourself:

```bash
CLUSTER=webapp-cicd-cluster
SERVICE=webapp-cicd-service
REGION=af-south-1

TASK_ARN=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" \
  --region "$REGION" --query 'taskArns[0]' --output text)

ENI=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --region "$REGION" \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
  --output text)

aws ec2 describe-network-interfaces --network-interface-ids "$ENI" \
  --region "$REGION" --query 'NetworkInterfaces[0].Association.PublicIp' \
  --output text
```

Because there is no load balancer, this IP changes when ECS replaces the task.
For a stable URL, add an Application Load Balancer and Route 53 record.

### Application endpoints

| Route | Response |
| --- | --- |
| `GET /` | HTML status dashboard (version, environment, hostname, Node version, uptime, start time) |
| `GET /health` | JSON health payload with status, uptime, version, environment, and time |
| `GET /api/info` | JSON runtime details (app, version, environment, hostname, Node version, uptime, start time, timestamp) |
| `GET /api/version` | JSON app name, version, and environment |
| `GET /favicon.ico` | Empty `204` response |
| Anything else | JSON `404` listing the valid routes |

All responses include basic hardening headers (`X-Content-Type-Options`,
`X-Frame-Options`, `Referrer-Policy`, a restrictive `Content-Security-Policy`)
and `Cache-Control: no-store`.

### Application behavior

The service reads these environment variables:

| Variable | Default | Notes |
| --- | --- | --- |
| `PORT` | `3001` | Must be an integer from `1` to `65535`; invalid values exit immediately |
| `HOST` | `0.0.0.0` | Bind address; `0.0.0.0` is required inside a container |
| `ENVIRONMENT` | `development` | Displayed on the dashboard and in the API responses; the ECS task definition sets it to `production` |

Other behavior:

* `app.js` builds the Express app without startup side effects; `server.js`
  owns the listener, `PORT` validation, keep-alive settings, and graceful
  shutdown. That split lets tests import the app without opening a port.
* Logs one line per request to stdout (method, path, status, duration, client
  IP, request ID). CloudWatch captures these in `/ecs/webapp-cicd-task`.
* Accepts or generates an `X-Request-Id` and returns it in the response header.
* Shuts down gracefully on `SIGTERM` and `SIGINT`: stops accepting connections,
  drains in-flight requests, and forces exit after 10 seconds.
* Keeps idle connections open slightly longer than the typical 60-second load
  balancer timeout (`keepAliveTimeout` 65s, `headersTimeout` 66s).
* Has no database or external service dependency.

---

## 🔁 Making Changes

```bash
git add aws/project-2-cicd-pipeline
git commit -m "Update dashboard text"
git push origin main
```

GitHub Actions redeploys automatically. A deployment usually takes a few
minutes because the workflow waits for the ECS service to stabilize.

---

## 🧱 AWS Components

* **Amazon ECR** — stores the Docker images and scans them on push.
* **Amazon ECS Fargate** — runs the service on serverless compute
  (`awsvpc` networking, `256` CPU units, `512` MiB memory, one task).
* **CloudWatch Logs** — captures container stdout in `/ecs/webapp-cicd-task`.
* **IAM** — an ECS task execution role for pulling images and writing logs, and
  a GitHub Actions user with ECS and ECR permissions.
* **EC2 security group** — allows inbound TCP `3001` from anywhere.
* **Existing VPC/subnets** — the script reuses networking rather than creating
  a new VPC.

---

## 🔧 Troubleshooting

### Local issues

* **`npm install` fails**

  ```bash
  npm cache clean --force
  rm -rf node_modules package-lock.json
  npm install
  ```

* **Port 3001 is already in use**

  ```bash
  lsof -ti :3001 | xargs kill -9
  PORT=3002 npm start
  ```

* **Docker build fails** — make sure you are in
  `aws/project-2-cicd-pipeline/`, where the `Dockerfile` lives.

### AWS setup issues

* **`jq: command not found`** — install `jq`; the setup script needs it to read
  the access key output.
* **AWS CLI is not configured**

  ```bash
  aws configure
  aws sts get-caller-identity
  ```

* **`AccessDenied` during setup** — the identity needs permissions for ECR,
  ECS, IAM, EC2 networking, and CloudWatch Logs.
* **No VPC found** — create a VPC tagged `projects-vpc`, or pass
  `VPC_NAME=<existing-vpc>`.
* **Access key creation fails** — an IAM user can have at most two access keys.
  Delete an old key or reuse an existing one.
* **Script fails unexpectedly** — rerun with shell tracing:

  ```bash
  bash -x aws_setup.sh
  ```

### GitHub Actions issues

* **Workflow does not run**
  * Confirm the push is to `main`.
  * Confirm the change is under `aws/project-2-cicd-pipeline/` or modifies
    `.github/workflows/deploy-aws.yml`.
  * Check that Actions are enabled for the repository.
* **Authentication fails** — recheck `AWS_ACCESS_KEY_ID` and
  `AWS_SECRET_ACCESS_KEY`; secret names are case-sensitive.
* **ECR push fails** — confirm the repository exists and the IAM user has ECR
  permissions.
* **Deploy job skipped** — the deploy job only runs on `main` after the test
  job succeeds.

### Deployment issues

* **ECS service is not updating** — check the service events and the task's
  CloudWatch logs.
* **Task stops immediately** — inspect `/ecs/webapp-cicd-task`; common causes
  are a bad `PORT`, a missing execution role permission, or an image pull
  failure.
* **Cannot reach the app**
  * Wait for the service to finish stabilizing.
  * Confirm the task is running and has a public IP.
  * Confirm the security group allows TCP `3001`.
  * Re-read the latest public IP from the workflow log; it changes after a
    deployment.
* **Container restarts repeatedly** — verify the app listens on `0.0.0.0` and
  on the port expected by the task definition.

---

## 📈 Advanced Usage

### Runtime environment variables

Locally:

```bash
PORT=8080 ENVIRONMENT=staging npm start
```

With Docker:

```bash
docker run --rm -p 8080:8080 -e PORT=8080 -e ENVIRONMENT=staging my-webapp
```

For ECS, add the same names to the container's `environment` array in the task
definition.

### Separate staging and production resources

Override all resource names so the environments do not share state:

```bash
AWS_REGION=af-south-1 \
VPC_NAME=projects-vpc \
CLUSTER_NAME=webapp-staging-cluster \
SERVICE_NAME=webapp-staging-service \
TASK_FAMILY=webapp-staging-task \
ECR_REPOSITORY=my-webapp-staging \
GITHUB_USER_NAME=github-actions-staging \
./aws_setup.sh
```

Two limitations to be aware of:

* The security group name is hardcoded as `webapp-cicd-sg`; two environments in
  the same VPC will reuse the same security group.
* The workflow has a single set of secret values, so running staging and
  production from the same repository requires separate workflows or
  environment-specific configuration.

### Monitoring

CloudWatch Logs is already configured. The setup script does not create alarms;
add CloudWatch alarms for CPU, memory, or task health if you want proactive
alerting.

---

## 🧹 Clean Up Resources

Set the names you used, then run the commands from top to bottom:

```bash
REGION=af-south-1
CLUSTER=webapp-cicd-cluster
SERVICE=webapp-cicd-service
TASK_FAMILY=webapp-cicd-task
ECR_REPO=my-webapp
LOG_GROUP=/ecs/webapp-cicd-task
SG_NAME=webapp-cicd-sg
EXEC_ROLE=ecsTaskExecutionRole-webapp-cicd-cluster
GH_USER=github-actions-user

# Stop and delete the ECS service and cluster
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --desired-count 0 --region "$REGION"
aws ecs delete-service --cluster "$CLUSTER" --service "$SERVICE" \
  --force --region "$REGION"
aws ecs wait services-inactive --cluster "$CLUSTER" --services "$SERVICE" \
  --region "$REGION"
aws ecs delete-cluster --cluster "$CLUSTER" --region "$REGION"

# Deregister the task definition revisions
aws ecs list-task-definitions --family-prefix "$TASK_FAMILY" \
  --region "$REGION" --query 'taskDefinitionArns[]' --output text \
  | xargs -r -n1 aws ecs deregister-task-definition --region "$REGION" \
      --task-definition

# Delete the ECR repository and log group
aws ecr delete-repository --repository-name "$ECR_REPO" \
  --force --region "$REGION"
aws logs delete-log-group --log-group-name "$LOG_GROUP" --region "$REGION"

# Delete the security group after the task's network interface is gone
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)
aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION"

# Delete the GitHub Actions IAM user and its access keys
aws iam list-access-keys --user-name "$GH_USER" \
  --query 'AccessKeyMetadata[].AccessKeyId' --output text \
  | xargs -r -n1 aws iam delete-access-key --user-name "$GH_USER" \
      --access-key-id
aws iam detach-user-policy --user-name "$GH_USER" \
  --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess
aws iam detach-user-policy --user-name "$GH_USER" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess
aws iam delete-user --user-name "$GH_USER"

# Delete the ECS task execution role
aws iam detach-role-policy --role-name "$EXEC_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws iam delete-role --role-name "$EXEC_ROLE"
```

Task definitions cannot be deleted, only deregistered. If the security group
deletion fails, wait a minute for the task's network interface to be released
and try again.

---

## 🌟 What You Learned

* Building a small Node.js/Express service with health and info endpoints
* Separating app creation from server startup so the app is testable
* Testing Express routes with `node:test` and Supertest
* Containerizing an app with a cached, production-only dependency install
* Creating ECR, ECS Fargate, IAM, security group, and CloudWatch resources
  with a shell script
* Writing a GitHub Actions workflow with separate test and deploy jobs
* Passing an image tag through the pipeline and rendering an ECS task
  definition
* Reading application logs and troubleshooting an ECS deployment

## 🚀 Next Steps

* ~~Replace the placeholder `npm test` script with real tests~~ ✅ Complete
* Add test coverage reporting to the CI test job
* Add an integration test for graceful shutdown on `SIGTERM`
* Add an Application Load Balancer and a stable DNS name
* Try blue/green deployments with CodeDeploy
* Add a database and store connection details in Secrets Manager
* Add CloudWatch alarms and a dashboard
* Move on to **Project 3: Kubernetes Orchestration**
