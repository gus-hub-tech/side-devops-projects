# Blue/Green Deployment with CodeDeploy — Implementation Plan

Plan for the **"Try blue/green deployments with CodeDeploy"** item in the
project README's Next Steps. This document is a blueprint only; no
infrastructure or CI changes have been made yet.

Code snippets below are illustrative and should be checked against the current
Terraform AWS provider and AWS CLI docs before applying.

---

## 1. Current state and target state

### Current state

- GitHub Actions tests, builds an image, pushes it to ECR, renders a new ECS
  task definition, and calls `amazon-ecs-deploy-task-definition`.
- The ECS service uses the default `ECS` deployment controller, so deployments
  are **rolling updates** in place.
- There is **no load balancer**. The app is reached via the Fargate task's
  public IP on port `3001`, and the workflow discovers that IP at the end of the
  job with `ecs list-tasks` / `ec2 describe-network-interfaces`.
- Terraform adopts the live stack via `imports.tf`. It owns the service,
  networking, security group, cluster, and supporting resources. CI owns task
  definition revisions and images; `ignore_changes` prevents the two from
  fighting.

### Target state

- An internet-facing ALB with two target groups (`blue` and `green`) and a
  production listener.
- The ECS service uses the `CODE_DEPLOY` deployment controller and registers
  with the blue target group initially.
- CodeDeploy creates a replacement (green) task set, optionally routes test
  traffic to it, shifts production traffic per a deployment configuration, and
  terminates the original task set after a bake period.
- CI registers a task definition, generates an AppSpec, creates a CodeDeploy
  deployment, and waits for it to succeed. The published URL is the **stable
  ALB DNS name**, not a task IP.
- Automatic rollback on deployment failure (and later on CloudWatch alarms).

### Explicit non-goals for this pass

- HTTPS / ACM certificate / custom domain (can be layered on after).
- A database or Secrets Manager.
- Replacing CodeDeploy with ECS's newer built-in blue/green feature (the README
  specifically asks for CodeDeploy).

---

## 2. Decisions to make before starting

| Decision | Suggested default for this project | Why |
| --- | --- | --- |
| Traffic shifting | `CodeDeployDefault.ECSAllAtOnce` first, try canary/linear later | Simplest to debug; canary needs longer bake times and more patience |
| Test listener | Optional; add port `8080` listener if you want to validate green before shift | Adds another moving part; skip initially if time-boxed |
| Auto rollback | `DEPLOYMENT_FAILURE` immediately; add alarm-based rollback in phase 2 | Failure rollback is free; alarms need tuning |
| Original task set | Terminate after 5 minutes | Keeps both versions running briefly for manual verification |
| IAM for CI | Attach `AWSCodeDeployFullAccess` to `github-actions-user`, plus `iam:PassRole` for the CodeDeploy role | Fine for a learning account; scope down later |
| `aws_setup.sh` | Treat Terraform as source of truth for new resources; add a note to the script instead of duplicating all ALB/CodeDeploy creation | Avoid maintaining two definitions of the same infrastructure |

---

## 3. Phase 1 — Add the ALB and stable URL (separate, verifiable change)

This is also the README's preceding next step, so it stands on its own.

### 3.1 Files to add / change

**`terraform/alb.tf` (new)** — define:

- `aws_lb.webapp`: `internal = false`, `load_balancer_type = "application"`,
  subnets from `data.aws_subnets.public.ids`, security group `aws_security_group.alb`.
- `aws_lb_target_group.blue` and `aws_lb_target_group.green`:
  `target_type = "ip"`, port `var.container_port`, protocol `HTTP`, VPC from
  `data.aws_vpc.projects.id`, health check on `/health` with `matcher = "200"`.
  Both target groups must belong to the same ALB.
- `aws_lb_listener.prod`: port `80`, `default_action` type `forward` to the blue
  target group.
- Optional `aws_lb_listener.test` on port `8080`, also forwarding to blue at
  rest; CodeDeploy will point it at green during a deployment.

**`terraform/security.tf`** — update:

- Add an ALB security group: ingress `80` (and `8080` if used) from
  `0.0.0.0/0`, egress all.
- Change the webapp security group ingress on `3001` from `0.0.0.0/0` to
  `security_groups = [aws_security_group.alb.id]`.
- Update the header comment: the task no longer has a direct public URL.

**`terraform/ecs.tf`** — update `aws_ecs_service.webapp`:

- Add a `load_balancer` block pointing at `aws_lb_target_group.blue.arn`,
  `container_name = local.container_name`, `container_port = local.app_port`.
  A `CODE_DEPLOY` service needs an initial target group.
- Keep `assign_public_ip = true` for now (harmless; can be revisited).

**`terraform/variables.tf`** — add variables for names/settings that would
otherwise be hardcoded: `alb_name`, `alb_port`, `health_check_path`,
`blue_target_group_name`, `green_target_group_name`. Keep defaults consistent
with the existing `webapp-cicd-*` naming scheme.

**`terraform/outputs.tf`** — add `alb_dns_name`, `app_url` (e.g.
`http://${aws_lb.webapp.dns_name}`), and both target group ARNs/name outputs.
Replace `app_url_hint` with the ALB URL. The CI job can read these via
`terraform output` or `aws elbv2 describe-load-balancers`.

**`terraform/network.tf`** — update the comment that says the task uses a
public IP because there is no ALB. Confirm the public subnets span at least two
availability zones (ALB requirement).

### 3.2 Verify phase 1

```bash
cd aws/project-2-cicd-pipeline/terraform
terraform fmt -check
terraform validate
terraform plan   # expect: create ALB/TGs/listener/SG; in-place SG rule and ECS service update; no replacements
terraform apply  # use the SSO admin profile per terraform/README.md
curl -sS http://<alb-dns>/health
curl -sS http://<alb-dns>/api/version
```

Also confirm the app security group now rejects port `3001` from the internet
and accepts it only from the ALB security group. **Checkpoint:** stop here,
review, and confirm the ALB URL works before touching deployment behavior.

---

## 4. Phase 2 — Add CodeDeploy resources and switch the controller

### 4.1 Files to add / change

**`terraform/codedeploy.tf` (new)** — define:

- `aws_iam_role.codedeploy`: trust `codedeploy.amazonaws.com`, attach the
  managed `AWSCodeDeployRoleForECS` policy. CodeDeploy uses this to call ECS,
  ELB, Lambda, and CloudWatch APIs.
- `aws_codedeploy_app.webapp`: `compute_platform = "ECS"`.
- `aws_codedeploy_deployment_group.webapp` with:
  - `ecs_service { cluster_name, service_name }`
  - `deployment_style { deployment_type = "BLUE_GREEN", deployment_option = "WITH_TRAFFIC_CONTROL" }`
  - `load_balancer_info.target_group_pair_info` listing both target groups and
    `prod_traffic_route.listener_arns = [aws_lb_listener.prod.arn]` (plus the
    test listener if you added one)
  - `deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"` (or a canary/
    linear config once the basic flow works)
  - `auto_rollback_configuration { enabled = true, events = ["DEPLOYMENT_FAILURE"] }`
  - `blue_green_deployment_config` with termination of the original task set
    after ~5 minutes
- Later enhancement: CloudWatch alarms (ALB `HTTPCode_ELB_5XX_Count`,
  `TargetResponseTime`) referenced in `alarm_configuration.alarms` so bad
  deployments roll back on symptoms, not just hard failures.

**`terraform/ecs.tf`** — switch the deployment controller:

- Add `deployment_controller { type = "CODE_DEPLOY" }`.
- Remove `deployment_minimum_healthy_percent` / `deployment_maximum_percent`
  (rolling-update settings; not used with CodeDeploy).
- Extend `ignore_changes` on the service to include `load_balancer`, because
  CodeDeploy swaps the service's target group as part of each deployment. Keep
  the existing `task_definition` ignore.

**`terraform/iam.tf`** — give CI the ability to drive CodeDeploy:

- Attach `AWSCodeDeployFullAccess` (or a scoped inline policy with
  `codedeploy:CreateDeployment`, `RegisterApplicationRevision`,
  `GetDeployment`, etc.) to `aws_iam_user.github_actions`.
- Add `iam:PassRole` for the CodeDeploy service role ARN.
- `AmazonECS_FullAccess` already covers many CodeDeploy actions, but do not rely
  on that implicitly; verify the effective permissions.

**`terraform/outputs.tf`** — output `codedeploy_application_name` and
`codedeploy_deployment_group_name` for the workflow.

### 4.2 Verify phase 2

- `terraform plan`: expect creation of the new CodeDeploy/IAM resources and an
  **in-place** update to `aws_ecs_service.webapp`. No resource replacement.
- After `apply`, check the deployment group in the console shows the ECS
  service, both target groups, and the production listener.
- Do not run a deployment through the old job after this point — it would use
  the rolling-update action against a `CODE_DEPLOY` service and fail.

---

## 5. Phase 3 — Change the CI/CD pipeline

File: `.github/workflows/deploy-aws.yml`, `deploy` job.

### 5.1 Steps to replace/insert

1. Keep: credential configuration, ECR login, image build/push, task definition
   download and render with `amazon-ecs-render-task-definition@v1`.
2. **Replace** `amazon-ecs-deploy-task-definition@v1` with:
   - Strip read-only fields from the rendered JSON (`taskDefinitionArn`,
     `revision`, `status`, `requiresAttributes`, `compatibilities`,
     `registeredAt`, `registeredBy`) with `jq`.
   - Register it:
     `aws ecs register-task-definition --cli-input-json file://task-definition.json --query taskDefinition.taskDefinitionArn --output text`
   - Generate `appspec.yaml` (see below) from the registered ARN plus subnet /
     security group / container port values fetched from AWS or Terraform
     outputs. Avoid stale hardcoded IDs in secrets.
3. Create the deployment:

   ```bash
   APPSPEC_B64=$(base64 -w0 appspec.yaml)
   DEPLOYMENT_ID=$(aws deploy create-deployment \
     --application-name "$CODEDEPLOY_APP" \
     --deployment-group-name "$CODEDEPLOY_GROUP" \
     --revision "revisionType=AppSpecContent,appSpecContent={content=${APPSPEC_B64}}" \
     --query deploymentId --output text)
   aws deploy wait deployment-successful --deployment-id "$DEPLOYMENT_ID"
   ```

4. **Replace** the "get task public IP" step with printing the ALB URL, plus a
   link to the CodeDeploy deployment in the AWS console. Optionally add a
   `curl` smoke check against `/health` and `/api/version`.
5. Add new env/secrets or dynamic lookups for the CodeDeploy app/group names,
   ALB DNS name, subnet IDs, and webapp security group ID. Prefer discovery via
   `aws elbv2` / `aws ec2` or committed Terraform outputs over manual secrets.

### 5.2 Example AppSpec (generated in CI)

```yaml
version: 0.0
Resources:
  - TargetService:
      Type: AWS::ECS::Service
      Properties:
        TaskDefinition: "arn:aws:ecs:af-south-1:<acct>:task-definition/webapp-cicd-task:<rev>"
        LoadBalancerInfo:
          ContainerName: "webapp"
          ContainerPort: 3001
        PlatformVersion: "LATEST"
        NetworkConfiguration:
          AwsvpcConfiguration:
            Subnets: ["subnet-...", "subnet-..."]
            SecurityGroups: ["sg-..."]
# Optional lifecycle hooks (Lambda functions) for validation:
# Hooks:
#   - BeforeAllowTraffic: "validate-green"
#   - AfterAllowTraffic: "smoke-test-green"
```

The target group pair and listener live in the CodeDeploy deployment group, not
in the AppSpec. If you add hooks, add their Lambda functions and permissions to
Terraform too.

---

## 6. Phase 4 — Verify blue/green behavior end to end

1. **Baseline deploy:** push a change through the new pipeline. Confirm
   CodeDeploy creates a green task set, registers it with the green target
   group, shifts the listener, and terminates blue after the bake period.
2. **Zero-downtime check:** run a loop during the shift:
   `while true; do curl -sf http://<alb-dns>/health >/dev/null || echo FAIL; done`
3. **Color check:** use `/api/version` (or a new `/api/color` endpoint reading
   an `ENV` variable from the task definition) to see which version is live.
4. **Rollback drill:** deploy a deliberately unhealthy revision (e.g. wrong
   health check path or an app that exits). Confirm CodeDeploy rolls traffic
   back to blue and the run fails instead of silently succeeding.
5. **Drift check:** after a successful deployment, run `terraform plan`. It
   should be clean; if not, extend `ignore_changes` or fix ownership so CI and
   Terraform do not fight over `task_definition` / `load_balancer`.
6. **Canary/linear trial:** switch the deployment group config to
   `CodeDeployDefault.ECSCanary10Percent5Minutes` or
   `ECSLinear10PercentEvery1Minutes`, deploy again, and watch the staged shift.

---

## 7. Phase 5 — Docs and cleanup

- `README.md`: update "What This Creates", the public URL section (ALB DNS),
  the pipeline description, and mark the ALB and blue/green Next Steps items
  complete once verified.
- `terraform/README.md`: list the new ALB, target groups, listener, CodeDeploy
  app/deployment group, and IAM role; explain that CodeDeploy (not Terraform)
  mutates the service's target group and task definition during deployments.
- `aws_setup.sh`: add a note that it is the initial bootstrap only and that
  Terraform is authoritative for load balancing/CodeDeploy, or extend the script
  if fresh-install parity matters.
- Note ongoing cost: ALB hourly charge plus two full Fargate task sets running
  during each deployment. `terraform destroy` will remove the new resources as
  well as the existing stack.

---

## 8. Risks and gotchas

- **In-place security group rule change** (`0.0.0.0/0` → ALB SG only) can cause a
  brief interruption; apply in a maintenance window and verify immediately.
- **State ownership:** the service's `load_balancer` and `task_definition` are
  mutated by CodeDeploy/CI. Without `ignore_changes`, the next `terraform apply`
  will try to revert a deployment.
- **Task definition registration:** read-only fields must be stripped before
  `register-task-definition`, or the API will reject the payload.
- **ALB subnets:** must be in at least two availability zones; the shared VPC's
  public subnets should already satisfy this, but verify.
- **Target groups:** both must be on the same ALB and must not be used by a
  different deployment group.
- **AppSpec must include network config** (`awsvpcConfiguration`) for Fargate
  services; stale subnet/security group IDs will make deployments fail.
- **Old workflow step removal:** leaving the rolling-update deploy action in
  place alongside CodeDeploy will cause conflicting deployments.
- **Cost:** double Fargate capacity during the bake window and ALB hour/LCU
  charges while the stack runs.
- **Rollback limit:** rollback restores the previous task set; it does not undo
  database or external side effects (no database in this project yet).

---

## 9. Suggested commit sequence

1. `feat(terraform): add ALB, target groups, and listener`
2. `fix(security): restrict app port to ALB security group`
3. `chore(terraform): output ALB DNS and update docs`
4. `feat(codedeploy): add ECS CodeDeploy application and deployment group`
5. `feat(ci): register task definition and create CodeDeploy deployment`
6. `docs: document blue/green flow and mark next steps complete`

Each commit should be accompanied by the verification steps from its phase;
phases 1 and 2 are deliberate checkpoints before CI behavior changes.
