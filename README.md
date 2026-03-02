# test-ecs-container-stop-timeout

Sample app to verify if ECS_CONTAINER_STOP_TIMEOUT is working as expected.

The container ignores SIGTERM and continues running until it is forcibly terminated with SIGKILL after the stop timeout period.

## Prerequisites

- AWS CLI configured with appropriate permissions
- Docker installed
- An existing VPC with subnets

## Setup

### 1. Build and Push Container Image to Container Registry

#### Using GitHub Container Registry

```bash
# Authenticate Docker to GitHub Container Registry
echo $GITHUB_TOKEN | docker login ghcr.io -u <github_username> --password-stdin

# Build, tag, and push the image
docker buildx build --platform linux/amd64 -t test-ecs-container-stop-timeout:latest .

docker tag test-ecs-container-stop-timeout:latest ghcr.io/<github_username>/test-ecs-container-stop-timeout:latest
docker push ghcr.io/<github_username>/test-ecs-container-stop-timeout:latest
```

> NOTE: On Apple silicon (arm64) machines, you may want to build the image for amd64 architecture to ensure compatibility with ECS. You can do this using Docker Buildx:


#### Using Amazon ECR

```bash
# Create ECR repository
aws ecr create-repository --repository-name test-ecs-container-stop-timeout

#  Authenticate Docker to ECR
aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin <account_id>.dkr.ecr.<region>.amazonaws.com

# Build, tag, and push the image
docker buildx build --platform linux/amd64 -t test-ecs-container-stop-timeout:latest .
docker tag test-ecs-container-stop-timeout:latest <account_id>.dkr.ecr.<region>.amazonaws.com/test-ecs-container-stop-timeout:latest
docker push <account_id>.dkr.ecr.<region>.amazonaws.com/test-ecs-container-stop-timeout:latest
```

### 2. IAM Roles

| Role | Purpose |
|---|---|
| **Task Execution Role** | Required for the ECS agent to pull images from ECR and write logs to CloudWatch Logs |
| **Task Role** | Required only if the container needs to call AWS services (not needed for this container) |

Attach the following AWS managed policy to the Task Execution Role:

```
AmazonECSTaskExecutionRolePolicy
```

### 3. Create CloudWatch Logs Group

```bash
aws logs create-log-group --log-group-name /ecs/test-stop-timeout
```

### 4. Create ECS Cluster

```bash
aws ecs create-cluster --cluster-name test-cluster
```

### 5. Register ECS Task Definition

```json
{
  "family": "test-stop-timeout",
  "executionRoleArn": "arn:aws:iam::<account_id>:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "test-container",
      "image": "<container_image_uri>",
      "essential": true,
      "stopTimeout": 30,
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/test-stop-timeout",
          "awslogs-region": "<region>",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ],
  "requiresCompatibilities": ["FARGATE"],
  "networkMode": "awsvpc",
  "cpu": "256",
  "memory": "512"
}
```

> [!NOTE]
> **About `stopTimeout` behavior:**
> 
> The `stopTimeout` field is key for this test. It controls how long ECS waits after sending SIGTERM before sending SIGKILL.
> 
> - For **Fargate** launch type:
>   - The default value is **30 seconds** if not specified.
>   - The maximum value is **120 seconds (2 minutes)**.
> - For **EC2 (non-Fargate)** launch type:
>   - The default value is also **30 seconds** if not specified.
>   - The maximum value is **1,200 seconds (20 minutes)**.
> 
> This means that if you do not set the `stopTimeout` field, ECS will wait 30 seconds after sending SIGTERM before sending SIGKILL, regardless of launch type. However, you can set a longer timeout for EC2 tasks than for Fargate tasks.

> [!NOTE]
> **About `requiresCompatibilities`:**
>
> The `requiresCompatibilities` field specifies the launch types on which the task definition can run. Possible values are:
> 
> - `FARGATE`: Run tasks on AWS Fargate (serverless compute for containers)
> - `EC2`: Run tasks on Amazon EC2 instances
> - `EXTERNAL`: Run tasks on external instances (ECS Anywhere, e.g., on-premises)
> 
> You can specify one or more values in the array (e.g., `["EC2", "FARGATE"]`).


Here is how to register the task definition using AWS CLI:

```bash
aws ecs register-task-definition --cli-input-json file://task-definition.json
```

### 6. Network Configuration (Fargate)

- **VPC** + **Subnets** (private subnets recommended)
- **Security Group** with outbound HTTPS (port 443) access to ECR and CloudWatch Logs endpoints

## Running the Test

### Start the Task

#### For starting the Task on Fargate

```bash
aws ecs run-task \
  --cluster test-cluster \
  --task-definition test-stop-timeout \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[<subnet_id>],securityGroups=[<sg_id>],assignPublicIp=ENABLED}"
```

#### For starting the Task on a Specific Capacity Provider (EC2)

To start the ECS task on a specific EC2 capacity provider, use the `--capacity-provider-strategy` option. Do not specify `--launch-type` when using capacity providers.

Example:

```bash
aws ecs run-task \
  --cluster test-cluster \
  --task-definition test-stop-timeout \
  --capacity-provider-strategy capacityProvider=<your_capacity_provider>,weight=1 \
  --network-configuration "awsvpcConfiguration={subnets=[<subnet_id>],securityGroups=[<sg_id>],assignPublicIp=ENABLED}"
```

Replace `<your_capacity_provider>` with the name of your EC2 capacity provider.


### Stop the Task

```bash
aws ecs stop-task \
  --cluster test-cluster \
  --task <task_id>
```

## Expected Behavior

```
ECS Task starts
  → Container prints "Started" and runs sleep infinity
  → Task is stopped (aws ecs stop-task)
  → ECS agent sends SIGTERM to the container
  → Container ignores SIGTERM and prints "Received SIGTERM, ignoring..."
  → After stopTimeout seconds, ECS agent sends SIGKILL
  → Container is forcibly terminated
```

By changing the `stopTimeout` value in the task definition, you can verify the wait time before forced termination. The default is **30 seconds** and the maximum is **120 seconds** on Fargate.


## How to Measure the Time from ECS Task Stop Initiation to Completion

To measure the actual time it takes for an ECS task to stop after issuing the stop command, you can use the `aws ecs describe-tasks` command and check the `stoppingAt` and `stoppedAt` fields in the output. The difference between these two timestamps represents the duration from when the stop process started to when the task was fully stopped.

Example output:

```json
{
  "tasks": [
    {
       ... snip...
      "stoppedAt": "2026-03-02T11:31:21.861000+09:00",
      "stoppedReason": "Task stopped by user",
      "stoppingAt": "2026-03-02T11:25:05.472000+09:00",
      "tags": []
    }
  ]
}
```

By calculating the difference between `stoppingAt` and `stoppedAt`, you can determine the actual stop duration for the ECS task.
