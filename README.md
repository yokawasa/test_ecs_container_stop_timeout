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
docker build -t test-ecs-container-stop-timeout .
docker tag test-ecs-container-stop-timeout:latest ghcr.io/<github_username>/test-ecs-container-stop-timeout:latest
docker push ghcr.io/<github_username>/test-ecs-container-stop-timeout:latest
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

:::note info
**About `stopTimeout` behavior:**

The `stopTimeout` field is key for this test. It controls how long ECS waits after sending SIGTERM before sending SIGKILL.

- For **Fargate** launch type:
  - The default value is **30 seconds** if not specified.
  - The maximum value is **120 seconds (2 minutes)**.
- For **EC2 (non-Fargate)** launch type:
  - The default value is also **30 seconds** if not specified.
  - The maximum value is **1,200 seconds (20 minutes)**.

This means that if you do not set the `stopTimeout` field, ECS will wait 30 seconds after sending SIGTERM before sending SIGKILL, regardless of launch type. However, you can set a longer timeout for EC2 tasks than for Fargate tasks.
:::

:::note info
**About `requiresCompatibilities`:**

The `requiresCompatibilities` field specifies the launch types on which the task definition can run. Possible values are:

- `FARGATE`: Run tasks on AWS Fargate (serverless compute for containers)
- `EC2`: Run tasks on Amazon EC2 instances
- `EXTERNAL`: Run tasks on external instances (ECS Anywhere, e.g., on-premises)

You can specify one or more values in the array (e.g., `["EC2", "FARGATE"]`).
:::

Here is how to register the task definition using AWS CLI:

```bash
aws ecs register-task-definition --cli-input-json file://task-definition.json
```

### 6. Network Configuration (Fargate)

- **VPC** + **Subnets** (private subnets recommended)
- **Security Group** with outbound HTTPS (port 443) access to ECR and CloudWatch Logs endpoints

## Running the Test

### Start the Task

```bash
aws ecs run-task \
  --cluster test-cluster \
  --task-definition test-stop-timeout \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[<subnet_id>],securityGroups=[<sg_id>],assignPublicIp=ENABLED}"
```

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
