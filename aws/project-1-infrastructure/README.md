# 🚀 Project 1: Infrastructure as Code (AWS)

Create your first AWS infrastructure using **Terraform** and **ECS Fargate**.

---

## 🌐 What This Creates

- ECS Fargate cluster (serverless containers)
- ECS service running the configured container image
- CloudWatch log group for monitoring
- Security group for network access in the existing `projects-vpc`
- IAM roles for proper permissions

> This account has no default VPC, so the configuration looks up `projects-vpc` by
> its `Name` tag and places the service in its public subnets.

---

## 🧰 Prerequisites

- [AWS CLI](https://aws.amazon.com/cli/) installed and configured
- [Terraform](https://www.terraform.io/downloads.html) installed
- AWS account (Free Tier is fine)

---

## 🛠 Step-by-Step Deployment

### ✅ Step 1: Set Up AWS CLI

```bash
# macOS
brew install awscli

# Linux
sudo apt install awscli

# Windows
# Download from AWS website

# Configure AWS credentials
aws configure
# Provide Access Key, Secret Key, region (e.g. af-south-1), output (e.g. json)

# Verify login
aws sts get-caller-identity
```

---

### ✅ Step 2: Customize Your Settings

```bash
# Edit terraform.tfvars
# Change "yourname" to personalize

cluster_name = "john-devops-cluster"
vpc_name     = "projects-vpc"
```

---

### ✅ Step 3: Deploy Infrastructure

```bash
# Initialize Terraform
terraform init

# Review planned changes (works with the server's read-only role)
terraform plan

# Apply (needs temporary SSO admin credentials)
./run-with-sso.sh apply
```

---

### 🔑 AWS access on the projects server

The server's instance role (`ec2-ssm-role`) is read-only: `terraform init`,
`validate`, `fmt` and `plan` work directly. `apply` and `destroy` need admin
credentials from your SSO session.

If your SSO token has expired, refresh it on your **local** machine first:

```bash
aws sso login --profile assetsync-sso
```

Then, from your local machine, send temporary credentials to the server and run
Terraform with the helper script:

```bash
{ aws configure export-credentials --profile assetsync-sso --format env; \
  echo 'cd ~/side-devops-projects/aws/project-1-infrastructure && ./run-with-sso.sh apply'; \
} | ssh -i /home/gus/.ssh/projects-key.pem \
  ubuntu@ec2-13-247-60-145.af-south-1.compute.amazonaws.com 'bash -s'
```

Replace `apply` with `destroy` when tearing down. Credentials are passed over
SSH and are never stored on the server.

---

### ✅ Step 4: Get the Public IP

```bash
# Store outputs into variables
CLUSTER_NAME=$(terraform output -raw cluster_name)
SERVICE_NAME=$(terraform output -raw service_name)

# List running tasks
aws ecs list-tasks --cluster $CLUSTER_NAME --service-name $SERVICE_NAME

# Replace [TASK_ARN] with actual output
aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks [TASK_ARN]

# OR use this one-liner:
aws ecs describe-tasks \
  --cluster $CLUSTER_NAME \
  --tasks $(aws ecs list-tasks --cluster $CLUSTER_NAME --service-name $SERVICE_NAME --query 'taskArns[0]' --output text) \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' \
  --output text | \
  xargs -I {} aws ec2 describe-network-interfaces \
  --network-interface-ids {} \
  --query 'NetworkInterfaces[0].Association.PublicIp' \
  --output text
```

---

### ✅ Step 5: Test Your Application

* Copy the public IP from step 4
* Open in browser:
  `http://[PUBLIC_IP]`
* You should see the **Nginx Welcome Page**

---

### ✅ Step 6: View Logs in CloudWatch

```bash
LOG_GROUP=$(terraform output -raw log_group_name)
aws logs describe-log-streams --log-group-name $LOG_GROUP
```

---

## 🐞 Troubleshooting

### ❌ Error: `NoCredentialsError`

* Run `aws configure`
* Confirm with `aws sts get-caller-identity`

---

### ❌ Error: `UnauthorizedOperation`

* Attach `AdministratorAccess` policy to your IAM user
* Ensure ECS, EC2, IAM, and CloudWatch permissions are present

---

### ❌ Task Keeps Stopping

* Check logs in CloudWatch
* Verify container image is valid and accessible
* Ensure sufficient CPU/memory values

---

### ❌ Website Not Loading

* Wait 2–3 minutes for app to start
* Confirm public IP assignment
* Ensure port 80 is open in security group

---

### ❌ Error: `ResourceAlreadyExistsException`

* Edit `terraform.tfvars` to use a unique cluster name
* Or destroy existing infra: `terraform destroy`

---

## 🧹 Clean Up (Important!)

```bash
terraform destroy
# Confirm with 'yes'
```

Then verify in AWS Console that no resources remain to avoid unexpected charges.

---

## 🎓 What You Learned

✅ Infrastructure as Code with Terraform
✅ AWS ECS Fargate (serverless containers)
✅ IAM Roles & Permissions
✅ Security Groups & VPC
✅ CloudWatch Logging
✅ AWS CLI Commands

---

## 🔄 Next Steps

* Try deploying a different Docker image
* Modify the security group to allow other ports
* Move on to **Project 2: Automated Deployment Pipeline**
