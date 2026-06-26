# ECS Fargate Observability Example with ADOT, AMP, and Grafana

This example deploys an end-to-end metrics observability pipeline on Amazon ECS
Fargate using Terraform.

The pipeline is:

```text
ECS services and AWS CloudWatch metrics
-> CloudWatch Exporter
-> ADOT Collector
-> Amazon Managed Service for Prometheus
-> Grafana
```

It uses `terraform-aws-modules` for the core AWS infrastructure and deploys
ADOT Collector, CloudWatch Exporter, and Grafana as ECS services.

## What This Example Creates

This example creates:

- VPC with public and private subnets
- NAT gateway for private ECS tasks
- Application Load Balancer
- ECS cluster using Fargate and Fargate Spot capacity providers
- Example ECS services:
  - `stig`
  - `windmil`
  - `orchestrator`
- Dedicated Grafana ECS service
- Dedicated ADOT Collector ECS service
- Dedicated CloudWatch Exporter ECS service
- SSM parameters for ADOT, Grafana, and CloudWatch Exporter configs
- IAM roles and policies for:
  - ADOT remote write to AMP
  - ADOT ECS service discovery
  - Grafana AMP queries
  - CloudWatch Exporter CloudWatch metric reads

## Architecture

```text
Application services
  - expose HTTP through ALB
  - Grafana exposes /metrics

CloudWatch Exporter
  - reads AWS/ECS, AWS/ApplicationELB, and AWS/RDS metrics from CloudWatch
  - exposes Prometheus metrics on port 9106

ADOT Collector
  - discovers ECS tasks with ecs_observer
  - scrapes targets with Prometheus receiver
  - remote writes metrics to AMP using SigV4

Grafana
  - exposes UI through ALB port 3000
  - provisions AMP as the default Prometheus data source
  - queries AMP using SigV4 and the ECS task role
```

## Prerequisites

- Terraform `>= 1.5.7`
- AWS provider `>= 6.34`
- AWS CLI configured with permissions to create and manage:
  - VPC
  - ALB
  - ECS
  - IAM
  - SSM Parameter Store
  - CloudWatch Logs
  - Amazon Managed Service for Prometheus permissions
- An existing Amazon Managed Service for Prometheus workspace

## Configuration

### 1. Set the AMP Workspace ID

Update `terraform.tfvars`:

```hcl
amp_workspace_id = "ws-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### 2. Set the AMP Remote Write Endpoint

Update `local.amp_remote_write_endpoint` in `main.tf`:

```hcl
amp_remote_write_endpoint = "https://aps-workspaces.eu-west-1.amazonaws.com/workspaces/ws-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/api/v1/remote_write"
```

The Grafana query endpoint is derived from this value by removing
`/api/v1/remote_write`.

### 3. Set the AWS Region

The example currently uses:

```hcl
region = "eu-west-1"
```

Update `local.region` in `main.tf` if you need a different region. Make sure the
AMP workspace endpoint and workspace ID match the same region.

## Usage

Initialize Terraform:

```bash
terraform init
```

Review the plan:

```bash
terraform plan
```

Apply:

```bash
terraform apply
```

If running from the repository root instead of this directory:

```bash
terraform -chdir=examples/fargate init
terraform -chdir=examples/fargate plan
terraform -chdir=examples/fargate apply
```

## Access Grafana

Get the ALB DNS name:

```bash
aws elbv2 describe-load-balancers \
  --region eu-west-1 \
  --names ex-fargate \
  --query 'LoadBalancers[0].DNSName' \
  --output text
```

Open Grafana:

```text
http://<alb-dns-name>:3000
```

Default Grafana credentials:

```text
username: admin
password: admin
```

Change the password when prompted.

## AMP Data Source

The Grafana data source is provisioned automatically.

Data source name:

```text
AMP
```

It is configured as a Prometheus data source with SigV4 enabled:

```text
sigV4Auth: true
sigV4AuthType: default
sigV4Region: eu-west-1
```

You do not need to manually select SigV4 in the Grafana UI.

## Validation

### Check ECS Services

```bash
aws ecs describe-services \
  --region eu-west-1 \
  --cluster ex-fargate \
  --services adot cloudwatch-exporter grafana
```

Confirm each service has a running task.

### Check ADOT Logs

```bash
aws logs tail /ecs/ex-fargate/adot \
  --region eu-west-1 \
  --follow
```

Healthy logs include:

```text
Starting ECSDiscovery
Starting scrape manager
starting prometheus remote write exporter
Everything is ready. Begin running and processing data.
```

### Query Metrics in Grafana

In Grafana:

```text
Explore -> AMP -> Code
```

Run:

```promql
up
```

Expected result:

```text
1
```

for discovered targets such as `grafana` and `cloudwatch-exporter`.

Run:

```promql
cloudwatch_exporter_scrape_error
```

Expected result:

```text
0
```

Run:

```promql
aws_ecs_cpuutilization_average
```

Expected result:

```text
ECS CPU metrics by service
```

Run:

```promql
aws_applicationelb_request_count_sum
```

Expected result:

```text
ALB request count metrics
```

## Useful PromQL Queries

ECS CPU utilization:

```promql
avg by (service_name) (aws_ecs_cpuutilization_average)
```

ALB request count:

```promql
sum(aws_applicationelb_request_count_sum)
```

ALB target response time:

```promql
avg(aws_applicationelb_target_response_time_average)
```

ALB target 5xx count:

```promql
sum(aws_applicationelb_httpcode_target_5_xx_count_sum)
```

CloudWatch exporter health:

```promql
cloudwatch_exporter_scrape_error
```

Prometheus target health:

```promql
up
```

## Notes

- ADOT image `v0.48.0` does not include the `awscloudwatch` receiver.
- AWS service metrics are collected through CloudWatch Exporter and then scraped
  by ADOT.
- The ADOT config is stored in SSM Parameter Store and passed to the task through
  `AOT_CONFIG_CONTENT`.
- Grafana data source config is stored in SSM Parameter Store and written to
  Grafana provisioning config at startup.
- Terraform service triggers hash the generated configs so config changes cause
  ECS service redeployments.
- RDS metrics return data only if RDS instances exist in the configured region.
- This example creates billable resources.

## Cleanup

Destroy the stack when finished:

```bash
terraform destroy
```

Or from the repository root:

```bash
terraform -chdir=examples/fargate destroy
```

## Detailed Documentation

For the full implementation explanation and troubleshooting guide, see:

```text
../../docs/metrics-observability-pipeline.md
```
