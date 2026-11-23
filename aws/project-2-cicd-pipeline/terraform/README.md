# Terraform for the CI/CD pipeline

This configuration codifies the AWS resources created by `../aws_setup.sh`:

- ECR repository with scan-on-push and a lifecycle policy (1 tagged, 1 untagged)
- ECS Fargate cluster, task definition, and service
- CloudWatch log group
- Security group exposing port `3001`
- ECS task execution role
- GitHub Actions IAM user and its ECS/ECR policy attachments
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

Review the plan before applying. It should show 12 imports and no replacements.
The ECR lifecycle policy import is followed by an in-place update that adds the
tagged-image expiration rule. If the CI workflow has already registered a newer
ECS task definition revision, update the `:14` in `imports.tf` to the revision
Terraform should adopt.

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
`ignore_changes = [container_definitions]`. Terraform owns the service,
networking, desired count, security group, cluster, lifecycle policy, and
supporting resources; CI owns application revisions and images. Terraform
tracks only the revision listed in `imports.tf`; revisions registered by CI
after adoption stay outside state, so `terraform destroy` will not deregister
them.

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
