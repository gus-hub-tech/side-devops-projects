#!/bin/bash
# AWS Infrastructure Setup for CI/CD Pipeline

set -e  # Exit on any error

# Configuration variables (override any of these via environment variables)
CLUSTER_NAME="${CLUSTER_NAME:-webapp-cicd-cluster}"
SERVICE_NAME="${SERVICE_NAME:-webapp-cicd-service}"
TASK_FAMILY="${TASK_FAMILY:-webapp-cicd-task}"
ECR_REPOSITORY="${ECR_REPOSITORY:-my-webapp}"
AWS_REGION="${AWS_REGION:-af-south-1}"
VPC_NAME="${VPC_NAME:-projects-vpc}"
GITHUB_USER_NAME="${GITHUB_USER_NAME:-github-actions-user}"
CONTAINER_PORT="${CONTAINER_PORT:-3001}"

# Application Load Balancer (matches terraform/alb.tf)
# These are name-based placeholders on purpose: the ALB is deleted and
# recreated regularly, so no ARN, allocation ID, or DNS name is stored here.
# Every run looks the resources up by name and creates them if they are gone.
ALB_NAME="${ALB_NAME:-webapp-cicd-loadbalancer}"
TARGET_GROUP_NAME="${TARGET_GROUP_NAME:-webapp-cicd-target-group}"
ALB_PORT="${ALB_PORT:-80}"
HEALTH_CHECK_PATH="${HEALTH_CHECK_PATH:-/}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-30}"
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-5}"
HEALTHY_THRESHOLD="${HEALTHY_THRESHOLD:-5}"
UNHEALTHY_THRESHOLD="${UNHEALTHY_THRESHOLD:-2}"

# Application Auto Scaling (matches the live target/policy)
AUTOSCALING_MIN="${AUTOSCALING_MIN:-1}"
AUTOSCALING_MAX="${AUTOSCALING_MAX:-3}"
AUTOSCALING_CPU_TARGET="${AUTOSCALING_CPU_TARGET:-30}"
AUTOSCALING_SCALE_OUT_COOLDOWN="${AUTOSCALING_SCALE_OUT_COOLDOWN:-60}"
AUTOSCALING_SCALE_IN_COOLDOWN="${AUTOSCALING_SCALE_IN_COOLDOWN:-60}"
AUTOSCALING_POLICY_NAME="${AUTOSCALING_POLICY_NAME:-Target-tracking-auto scaling-policy}"

echo "=========================================="
echo "Setting up AWS infrastructure for CI/CD"
echo "=========================================="
echo "Cluster: $CLUSTER_NAME"
echo "Service: $SERVICE_NAME"
echo "ECR Repository: $ECR_REPOSITORY"
echo "Region: $AWS_REGION"
echo "VPC: $VPC_NAME"
echo "ALB: $ALB_NAME (port $ALB_PORT -> $TARGET_GROUP_NAME)"
echo ""

# Check if AWS CLI is configured
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "❌ AWS CLI not configured. Please run 'aws configure' first."
    exit 1
fi

echo "✅ AWS CLI configured"

# 1. Create ECR Repository
echo "📦 Creating ECR repository..."
if aws ecr describe-repositories --repository-names $ECR_REPOSITORY --region $AWS_REGION >/dev/null 2>&1; then
    echo "✅ ECR repository already exists"
else
    aws ecr create-repository \
        --repository-name $ECR_REPOSITORY \
        --region $AWS_REGION \
        --image-scanning-configuration scanOnPush=true
    echo "✅ ECR repository created"
fi

# 1b. Apply the ECR lifecycle policy (matches terraform/ecr.tf)
echo "🧹 Applying ECR lifecycle policy..."
ECR_TAGGED_IMAGE_COUNT="${ECR_TAGGED_IMAGE_COUNT:-1}"
ECR_UNTAGGED_IMAGE_COUNT="${ECR_UNTAGGED_IMAGE_COUNT:-1}"

if [ "$ECR_TAGGED_IMAGE_COUNT" -eq 1 ]; then
    TAGGED_LABEL="image"
else
    TAGGED_LABEL="images"
fi
if [ "$ECR_UNTAGGED_IMAGE_COUNT" -eq 1 ]; then
    UNTAGGED_LABEL="image"
else
    UNTAGGED_LABEL="images"
fi

LIFECYCLE_POLICY=$(cat <<EOF
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep the $ECR_TAGGED_IMAGE_COUNT most recent tagged $TAGGED_LABEL",
      "selection": {
        "tagStatus": "tagged",
        "tagPatternList": ["*"],
        "countType": "imageCountMoreThan",
        "countNumber": $ECR_TAGGED_IMAGE_COUNT
      },
      "action": { "type": "expire" }
    },
    {
      "rulePriority": 2,
      "description": "Keep the $ECR_UNTAGGED_IMAGE_COUNT most recent untagged $UNTAGGED_LABEL",
      "selection": {
        "tagStatus": "untagged",
        "countType": "imageCountMoreThan",
        "countNumber": $ECR_UNTAGGED_IMAGE_COUNT
      },
      "action": { "type": "expire" }
    }
  ]
}
EOF
)

aws ecr put-lifecycle-policy \
    --repository-name "$ECR_REPOSITORY" \
    --region "$AWS_REGION" \
    --lifecycle-policy-text "$LIFECYCLE_POLICY" >/dev/null
echo "✅ ECR lifecycle policy applied"

# Get ECR repository URI
ECR_URI=$(aws ecr describe-repositories \
    --repository-names $ECR_REPOSITORY \
    --region $AWS_REGION \
    --query 'repositories[0].repositoryUri' \
    --output text)

echo "✅ ECR URI: $ECR_URI"

# 2. Create IAM role for ECS task execution
echo "🔐 Creating ECS execution role..."
EXECUTION_ROLE_NAME="ecsTaskExecutionRole-$CLUSTER_NAME"

if aws iam get-role --role-name $EXECUTION_ROLE_NAME >/dev/null 2>&1; then
    echo "✅ ECS execution role already exists"
else
    aws iam create-role \
        --role-name $EXECUTION_ROLE_NAME \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": {
                        "Service": "ecs-tasks.amazonaws.com"
                    },
                    "Action": "sts:AssumeRole"
                }
            ]
        }'

    aws iam attach-role-policy \
        --role-name $EXECUTION_ROLE_NAME \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
    
    echo "✅ ECS execution role created"
fi

# Get execution role ARN
EXECUTION_ROLE_ARN=$(aws iam get-role \
    --role-name $EXECUTION_ROLE_NAME \
    --query 'Role.Arn' \
    --output text)

# 3. Create ECS cluster
echo "🏗️ Creating ECS cluster..."
EXISTING_CLUSTER=$(aws ecs describe-clusters \
    --clusters "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'clusters[0].clusterName' \
    --output text 2>/dev/null || true)

if [ "$EXISTING_CLUSTER" = "$CLUSTER_NAME" ]; then
    echo "✅ ECS cluster already exists"
else
    aws ecs create-cluster \
        --cluster-name $CLUSTER_NAME \
        --region $AWS_REGION
    echo "✅ ECS cluster created"
fi

# 4. Get VPC and subnet information
echo "🌐 Getting VPC information..."
VPC_ID=$(aws ec2 describe-vpcs \
    --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$VPC_NAME" \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null || true)

# Fall back to the account's default VPC if the named VPC doesn't exist
if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
    echo "⚠️  VPC '$VPC_NAME' not found, checking for a default VPC..."
    VPC_ID=$(aws ec2 describe-vpcs \
        --region "$AWS_REGION" \
        --filters "Name=is-default,Values=true" \
        --query 'Vpcs[0].VpcId' \
        --output text 2>/dev/null || true)
fi

if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
    echo "❌ No VPC found in $AWS_REGION."
    echo "   Create the '$VPC_NAME' VPC or set VPC_NAME to an existing VPC, then re-run."
    exit 1
fi

# Prefer the public subnets (same naming convention as project 1)
SUBNETS=$(aws ec2 describe-subnets \
    --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${VPC_NAME}-subnet-public*" \
    --query 'Subnets[*].SubnetId' \
    --output text | tr '\t' ',')

# Fall back to every subnet in the VPC if no public subnets are tagged
if [ -z "$SUBNETS" ] || [ "$SUBNETS" = "None" ]; then
    echo "⚠️  No '$VPC_NAME-subnet-public*' subnets found, using all subnets in $VPC_ID"
    SUBNETS=$(aws ec2 describe-subnets \
        --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[*].SubnetId' \
        --output text | tr '\t' ',')
fi

if [ -z "$SUBNETS" ] || [ "$SUBNETS" = "None" ]; then
    echo "❌ No subnets found in VPC $VPC_ID."
    exit 1
fi

echo "✅ VPC: $VPC_ID"
echo "✅ Subnets: $SUBNETS"

# 5. Create security group
# The ALB and the ECS tasks share this group: ALB_PORT is the public listener,
# CONTAINER_PORT is the task port (also reachable directly by public IP).
echo "🛡️ Creating security group..."
SECURITY_GROUP_NAME="webapp-cicd-sg"

ensure_ingress() {
    local port=$1
    local existing
    existing=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --group-ids "$SECURITY_GROUP_ID" \
        --query "SecurityGroups[0].IpPermissions[?IpProtocol=='tcp' && FromPort==\`$port\` && ToPort==\`$port\` && contains(IpRanges[].CidrIp, '0.0.0.0/0')] | length(@)" \
        --output text)
    if [ "$existing" = "0" ]; then
        aws ec2 authorize-security-group-ingress \
            --region "$AWS_REGION" \
            --group-id "$SECURITY_GROUP_ID" \
            --protocol tcp \
            --port "$port" \
            --cidr 0.0.0.0/0 >/dev/null
        echo "✅ Added inbound rule for port $port"
    fi
}

SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || true)

if [ -n "$SECURITY_GROUP_ID" ] && [ "$SECURITY_GROUP_ID" != "None" ]; then
    echo "✅ Security group already exists: $SECURITY_GROUP_ID"
else
    SECURITY_GROUP_ID=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name $SECURITY_GROUP_NAME \
        --description "Security group for webapp CI/CD" \
        --vpc-id $VPC_ID \
        --query 'GroupId' \
        --output text)
    echo "✅ Security group created: $SECURITY_GROUP_ID"
fi

# Adding the rules after creation also repairs an older stack that only had 3001.
ensure_ingress "$ALB_PORT"
ensure_ingress "$CONTAINER_PORT"

# 5b. Create the ALB, its target group, and the HTTP listener
# This mirrors terraform/alb.tf. The two Elastic IPs shown in the console for
# this ALB (webapp-cicd-loadbalancer-az1 / -az2) are service-managed: AWS
# allocates them automatically when the ALB is created, so there is no
# ec2 allocate-address call here and no aws_eip resource in Terraform.
echo "⚖️  Creating ALB, target group, and listener..."

# A load-balanced ECS service needs the ECS service-linked role.
aws iam create-service-linked-role \
    --aws-service-name ecs.amazonaws.com >/dev/null 2>&1 || true

# Discover by name on every run rather than caching ARNs: the ALB may have
# been deleted and recreated since the previous run.
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups \
    --region "$AWS_REGION" \
    --names "$TARGET_GROUP_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null || true)

if [ -z "$TARGET_GROUP_ARN" ] || [ "$TARGET_GROUP_ARN" = "None" ]; then
    TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
        --region "$AWS_REGION" \
        --name "$TARGET_GROUP_NAME" \
        --protocol HTTP \
        --port "$CONTAINER_PORT" \
        --vpc-id "$VPC_ID" \
        --target-type ip \
        --health-check-protocol HTTP \
        --health-check-path "$HEALTH_CHECK_PATH" \
        --health-check-interval-seconds "$HEALTH_CHECK_INTERVAL" \
        --health-check-timeout-seconds "$HEALTH_CHECK_TIMEOUT" \
        --healthy-threshold-count "$HEALTHY_THRESHOLD" \
        --unhealthy-threshold-count "$UNHEALTHY_THRESHOLD" \
        --matcher 'HttpCode=200' \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text)
    echo "✅ Target group created: $TARGET_GROUP_NAME"
else
    echo "✅ Target group already exists: $TARGET_GROUP_NAME"
fi

# The ECS network configuration uses a comma-separated list; --subnets needs
# the same IDs space-separated.
SUBNET_IDS_SPACE="${SUBNETS//,/ }"

ALB_ARN=$(aws elbv2 describe-load-balancers \
    --region "$AWS_REGION" \
    --names "$ALB_NAME" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>/dev/null || true)

if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --region "$AWS_REGION" \
        --name "$ALB_NAME" \
        --subnets $SUBNET_IDS_SPACE \
        --security-groups "$SECURITY_GROUP_ID" \
        --scheme internet-facing \
        --type application \
        --ip-address-type ipv4 \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text)
    echo "✅ ALB created: $ALB_NAME"
else
    echo "✅ ALB already exists: $ALB_NAME"
fi

LISTENER_ARN=$(aws elbv2 describe-listeners \
    --region "$AWS_REGION" \
    --load-balancer-arn "$ALB_ARN" \
    --query "Listeners[?Port==\`$ALB_PORT\`].ListenerArn | [0]" \
    --output text 2>/dev/null || true)

if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" = "None" ]; then
    aws elbv2 create-listener \
        --region "$AWS_REGION" \
        --load-balancer-arn "$ALB_ARN" \
        --protocol HTTP \
        --port "$ALB_PORT" \
        --default-actions "Type=forward,TargetGroupArn=$TARGET_GROUP_ARN" >/dev/null
    echo "✅ Listener created on port $ALB_PORT"
else
    CURRENT_TARGET_GROUP=$(aws elbv2 describe-listeners \
        --region "$AWS_REGION" \
        --listener-arns "$LISTENER_ARN" \
        --query 'Listeners[0].DefaultActions[0].TargetGroupArn' \
        --output text)
    if [ "$CURRENT_TARGET_GROUP" != "$TARGET_GROUP_ARN" ]; then
        aws elbv2 modify-listener \
            --region "$AWS_REGION" \
            --listener-arn "$LISTENER_ARN" \
            --default-actions "Type=forward,TargetGroupArn=$TARGET_GROUP_ARN" >/dev/null
        echo "✅ Listener now forwards to $TARGET_GROUP_NAME"
    else
        echo "✅ Listener already forwards to the target group"
    fi
fi

ALB_DNS_NAME=$(aws elbv2 describe-load-balancers \
    --region "$AWS_REGION" \
    --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].DNSName' \
    --output text)
echo "✅ ALB DNS: $ALB_DNS_NAME"

# 6. Create CloudWatch log group
echo "📊 Creating CloudWatch log group..."
LOG_GROUP_NAME="/ecs/$TASK_FAMILY"

EXISTING_LOG_GROUP=$(aws logs describe-log-groups \
    --region "$AWS_REGION" \
    --log-group-name-prefix "$LOG_GROUP_NAME" \
    --query "logGroups[?logGroupName=='$LOG_GROUP_NAME'].logGroupName" \
    --output text 2>/dev/null || true)

if [ "$EXISTING_LOG_GROUP" = "$LOG_GROUP_NAME" ]; then
    echo "✅ CloudWatch log group already exists"
else
    aws logs create-log-group \
        --log-group-name $LOG_GROUP_NAME \
        --region $AWS_REGION
    echo "✅ CloudWatch log group created"
fi

# 7. Create initial task definition with placeholder image
echo "📋 Creating initial task definition..."
aws ecs register-task-definition \
    --family $TASK_FAMILY \
    --network-mode awsvpc \
    --requires-compatibilities FARGATE \
    --cpu 256 \
    --memory 512 \
    --execution-role-arn $EXECUTION_ROLE_ARN \
    --container-definitions '[
        {
            "name": "webapp",
            "image": "nginx:latest",
            "portMappings": [
                {
                    "containerPort": $CONTAINER_PORT,
                    "hostPort": $CONTAINER_PORT,
                    "protocol": "tcp",
                    "name": "webapp-$CONTAINER_PORT-tcp"
                }
            ],
            "environment": [
                {
                    "name": "ENVIRONMENT",
                    "value": "production"
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "'$LOG_GROUP_NAME'",
                    "awslogs-region": "'$AWS_REGION'",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ]' \
    --region $AWS_REGION >/dev/null

echo "✅ Initial task definition created"

# 8. Create ECS service
echo "🚀 Creating ECS service..."
EXISTING_SERVICE=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$AWS_REGION" \
    --query 'services[0].serviceName' \
    --output text 2>/dev/null || true)

if [ "$EXISTING_SERVICE" = "$SERVICE_NAME" ]; then
    echo "✅ ECS service already exists"
    CURRENT_TARGET_GROUP=$(aws ecs describe-services \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --region "$AWS_REGION" \
        --query 'services[0].loadBalancers[0].targetGroupArn' \
        --output text)
    if [ "$CURRENT_TARGET_GROUP" != "$TARGET_GROUP_ARN" ]; then
        aws ecs update-service \
            --cluster "$CLUSTER_NAME" \
            --service "$SERVICE_NAME" \
            --load-balancers "targetGroupArn=$TARGET_GROUP_ARN,containerName=webapp,containerPort=$CONTAINER_PORT" \
            --availability-zone-rebalancing ENABLED \
            --region "$AWS_REGION" >/dev/null
        echo "✅ ECS service attached to the target group"
    fi
else
    aws ecs create-service \
        --cluster $CLUSTER_NAME \
        --service-name $SERVICE_NAME \
        --task-definition $TASK_FAMILY \
        --desired-count 1 \
        --launch-type FARGATE \
        --load-balancers "targetGroupArn=$TARGET_GROUP_ARN,containerName=webapp,containerPort=$CONTAINER_PORT" \
        --availability-zone-rebalancing ENABLED \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
        --region $AWS_REGION >/dev/null
    echo "✅ ECS service created with the ALB target group"
fi

# 8b. Configure Application Auto Scaling (matches terraform/autoscaling.tf)
echo "📈 Configuring ECS service autoscaling..."
aws application-autoscaling register-scalable-target \
    --service-namespace ecs \
    --resource-id "service/$CLUSTER_NAME/$SERVICE_NAME" \
    --scalable-dimension ecs:service:DesiredCount \
    --min-capacity "$AUTOSCALING_MIN" \
    --max-capacity "$AUTOSCALING_MAX" \
    --region "$AWS_REGION" >/dev/null

aws application-autoscaling put-scaling-policy \
    --service-namespace ecs \
    --resource-id "service/$CLUSTER_NAME/$SERVICE_NAME" \
    --scalable-dimension ecs:service:DesiredCount \
    --policy-name "$AUTOSCALING_POLICY_NAME" \
    --policy-type TargetTrackingScaling \
    --target-tracking-scaling-policy-configuration "{
        \"TargetValue\": $AUTOSCALING_CPU_TARGET,
        \"PredefinedMetricSpecification\": {
            \"PredefinedMetricType\": \"ECSServiceAverageCPUUtilization\"
        },
        \"ScaleOutCooldown\": $AUTOSCALING_SCALE_OUT_COOLDOWN,
        \"ScaleInCooldown\": $AUTOSCALING_SCALE_IN_COOLDOWN,
        \"DisableScaleIn\": false
    }" \
    --region "$AWS_REGION" >/dev/null

echo "✅ Autoscaling: min $AUTOSCALING_MIN, max $AUTOSCALING_MAX, CPU target ${AUTOSCALING_CPU_TARGET}%"

# 9. Create IAM user for GitHub Actions
echo "👤 Creating GitHub Actions IAM user..."
if aws iam get-user --user-name $GITHUB_USER_NAME >/dev/null 2>&1; then
    echo "✅ GitHub Actions user already exists"
    echo "ℹ️ You may need to create new access keys"
else
    aws iam create-user --user-name $GITHUB_USER_NAME
    
    # Attach policies for GitHub Actions
    aws iam attach-user-policy \
        --user-name $GITHUB_USER_NAME \
        --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess
    
    aws iam attach-user-policy \
        --user-name $GITHUB_USER_NAME \
        --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess
    
    echo "✅ GitHub Actions user created with ECS and ECR permissions"
fi

# Create access keys for GitHub Actions
echo "🔑 Creating access keys for GitHub Actions..."
ACCESS_KEY_OUTPUT=$(aws iam create-access-key --user-name $GITHUB_USER_NAME 2>/dev/null || echo "failed")

if [ "$ACCESS_KEY_OUTPUT" = "failed" ]; then
    echo "⚠️ Could not create new access keys (user may already have 2 keys)"
    echo "ℹ️ You may need to delete old keys first or use existing ones"
    AWS_ACCESS_KEY_ID="[Use existing or create new access key]"
    AWS_SECRET_ACCESS_KEY="[Use existing or create new secret key]"
else
    AWS_ACCESS_KEY_ID=$(echo $ACCESS_KEY_OUTPUT | jq -r '.AccessKey.AccessKeyId')
    AWS_SECRET_ACCESS_KEY=$(echo $ACCESS_KEY_OUTPUT | jq -r '.AccessKey.SecretAccessKey')
fi

echo ""
echo "=========================================="
echo "🎉 SETUP COMPLETE!"
echo "=========================================="
echo ""
echo "📋 GitHub Repository Secrets to Add:"
echo ""
echo "AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID"
echo "AWS_SECRET_ACCESS_KEY: $AWS_SECRET_ACCESS_KEY"
echo "AWS_REGION: $AWS_REGION"
echo "ECR_REPOSITORY: $ECR_REPOSITORY"
echo "ECR_REGISTRY: $ECR_URI"
echo "ECS_CLUSTER: $CLUSTER_NAME"
echo "ECS_SERVICE: $SERVICE_NAME"
echo "ECS_TASK_DEFINITION: $TASK_FAMILY"
echo ""
echo "🌐 Application URL (stable ALB DNS name):"
echo "http://$ALB_DNS_NAME"
echo "   Health check: http://$ALB_DNS_NAME$HEALTH_CHECK_PATH"
echo "   The ALB creates two service-managed Elastic IPs (one per public subnet);"
echo "   they belong to the ALB and are removed when it is deleted."
echo ""
echo "🔧 Next Steps:"
echo "1. Add the above secrets to your GitHub repository"
echo "2. Push your code to trigger the first deployment"
echo "3. Watch the GitHub Actions workflow"
echo "4. Use the ALB URL above (it stays the same across deployments)"
echo ""
echo "🧹 To clean up later, run the commands in the 'Clean Up Resources'"
echo "   section of this project's README."
echo ""
echo "=========================================="