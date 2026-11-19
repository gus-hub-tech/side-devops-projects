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

echo "=========================================="
echo "Setting up AWS infrastructure for CI/CD"
echo "=========================================="
echo "Cluster: $CLUSTER_NAME"
echo "Service: $SERVICE_NAME"
echo "ECR Repository: $ECR_REPOSITORY"
echo "Region: $AWS_REGION"
echo "VPC: $VPC_NAME"
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
echo "🛡️ Creating security group..."
SECURITY_GROUP_NAME="webapp-cicd-sg"

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

    # Add inbound rule for port 3001
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id $SECURITY_GROUP_ID \
        --protocol tcp \
        --port 3001 \
        --cidr 0.0.0.0/0

    echo "✅ Security group created: $SECURITY_GROUP_ID"
fi

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
                    "containerPort": 3001,
                    "protocol": "tcp"
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
else
    aws ecs create-service \
        --cluster $CLUSTER_NAME \
        --service-name $SERVICE_NAME \
        --task-definition $TASK_FAMILY \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
        --region $AWS_REGION >/dev/null
    echo "✅ ECS service created"
fi

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
echo "🔧 Next Steps:"
echo "1. Add the above secrets to your GitHub repository"
echo "2. Push your code to trigger the first deployment"
echo "3. Watch the GitHub Actions workflow"
echo "4. Get your app URL from the workflow output"
echo ""
echo "🧹 To clean up later, run the commands in the 'Clean Up Resources'"
echo "   section of this project's README."
echo ""
echo "=========================================="