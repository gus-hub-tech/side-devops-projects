# Terraform for the CI/CD pipeline

This configuration codifies the AWS resources created by `../aws-script/aws_setup.sh`:

- ECR repository with scan-on-push and a lifecycle policy (1 tagged, 1 untagged)
- ECS Fargate cluster, task definition, and service
- Internet-facing ALB, one IP target group, and an HTTP listener on port 80
- CloudWatch log group
- Security group exposing ports `80` (ALB) and `3001` (task)
- ECS task execution role
- GitHub Actions IAM user and its ECS/ECR policy attachments
- Application Auto Scaling target and CPU target-tracking policy (30%)
- Lookups (data sources) for the shared `projects-vpc` and its public subnets

The VPC, subnets, route tables, and internet gateway belong to the shared
infrastructure and are not managed here.

## Adopt the existing stack

`imports.tf` maps the live resource IDs to the Terraform addresses. The first
`terraform apply` imports them instead of creating duplicates.

```bash
cd aws/project-2-cicd-pipeline/terraform
terraform init
terraform plan
terraform apply
```

Review the plan before applying. It should show imports only — no replacements,
additions, or changes. The state currently tracks the live task definition
revision `:25`. If CI registers a newer task definition revision later, update
the `:25` in `imports.tf` to the revision Terraform should adopt;
`ignore_changes` keeps CI in control of revisions while Terraform owns the rest
of the service configuration.

The ALB, target group, and listener are **not** in `imports.tf`. They are deleted
and recreated regularly, and their ARNs change each time, so the only stable
identity is the name (`alb_name` / `target_group_name`). After an out-of-band
recreation, a normal `terraform apply` creates fresh resources and reattaches
the ECS service; there is no import ID to update. `aws_setup.sh` uses the same
names and discovers the resources on every run.

The ALB's two Elastic IPs (`webapp-cicd-loadbalancer-az1` / `-az2`) are
service-managed addresses that AWS allocates automatically for the ALB's public
subnets. They are not standalone `aws_eip` resources and are deliberately not
imported here: they follow the load balancer's lifecycle.

## AWS credentials

The `/home/ubuntu` EC2 instance role (`ec2-ssm-role`) is read-only and can run
`init`, `fmt`, `validate`, and `plan`. `apply` and `destroy` need the SSO admin
session:

```bash
aws sso login --profile assetsync-sso
export AWS_PROFILE=assetsync-sso
```

Use `run-with-sso.sh` from `../../project-1-infrastructure` when working through
the server's temporary credentials, as described there.

## Ownership after adoption

The GitHub Actions deploy job still registers new task definition revisions and
points the ECS service at them. To avoid fighting that workflow, the service
has `ignore_changes = [task_definition]` and the task definition has
`ignore_changes = [container_definitions]`. Terraform owns the service (including
its target group attachment), the ALB/listener, networking, desired count,
security group, cluster, lifecycle policy, autoscaling policy, and supporting
resources; CI owns application revisions and images. Terraform tracks only the
revision listed in `imports.tf`; revisions registered by CI after adoption stay
outside state, so `terraform destroy` will not deregister them.

`terraform output app_url` prints the stable `http://<alb-dns>/` address. The
ALB health check uses `GET /` with a 200 response expected.

The IAM access key for `github-actions-user` is deliberately not managed here.
Its secret can only be read when it is created, so Terraform cannot import the
existing key without replacing it. Rotate keys manually and update the GitHub
repository secrets (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`).

## State and cleanup

State is local by default. Keep `terraform.tfstate` private and back it up; for
shared/production use, configure an S3 backend with locking instead.

`terraform destroy` removes the stack, including the ECR images
(`force_delete = true`) and the IAM user (`force_destroy = true`, which deletes
its access keys). That invalidates the secrets currently stored in GitHub.
