provider "aws" {
  region = local.region
}

data "aws_availability_zones" "available" {
  # Exclude local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  region = "eu-west-1"
  name   = "ex-${basename(path.cwd)}"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  amp_remote_write_endpoint = "https://aps-workspaces.eu-west-1.amazonaws.com/workspaces/ws-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxx/api/v1/remote_write"

  adot_config_content = templatefile("${path.module}/adot-config.yaml.tftpl", {
    region                = local.region
    cluster_name          = local.name
    remote_write_endpoint = local.amp_remote_write_endpoint
  })

  amp_query_endpoint = trimsuffix(local.amp_remote_write_endpoint, "/api/v1/remote_write")

  grafana_datasource_config_content = yamlencode({
    apiVersion = 1
    datasources = [
      {
        name      = "AMP"
        type      = "prometheus"
        access    = "proxy"
        url       = local.amp_query_endpoint
        isDefault = true
        jsonData = {
          httpMethod     = "POST"
          sigV4Auth      = true
          sigV4AuthType  = "default"
          sigV4Region    = local.region
          prometheusType = "Prometheus"
        }
      }
    ]
  })

  cloudwatch_exporter_config_content = yamlencode({
    region              = local.region
    delay_seconds       = 120
    range_seconds       = 300
    period_seconds      = 60
    set_timestamp       = false
    use_get_metric_data = true
    metrics = [
      {
        aws_namespace   = "AWS/ECS"
        aws_metric_name = "CPUUtilization"
        aws_dimensions  = ["ClusterName", "ServiceName"]
        aws_statistics  = ["Average", "Maximum"]
      },
      {
        aws_namespace   = "AWS/ECS"
        aws_metric_name = "MemoryUtilization"
        aws_dimensions  = ["ClusterName", "ServiceName"]
        aws_statistics  = ["Average", "Maximum"]
      },
      {
        aws_namespace   = "AWS/ApplicationELB"
        aws_metric_name = "RequestCount"
        aws_dimensions  = ["LoadBalancer"]
        aws_statistics  = ["Sum"]
      },
      {
        aws_namespace   = "AWS/ApplicationELB"
        aws_metric_name = "TargetResponseTime"
        aws_dimensions  = ["LoadBalancer"]
        aws_statistics  = ["Average", "Maximum"]
      },
      {
        aws_namespace   = "AWS/ApplicationELB"
        aws_metric_name = "HTTPCode_Target_2XX_Count"
        aws_dimensions  = ["LoadBalancer"]
        aws_statistics  = ["Sum"]
      },
      {
        aws_namespace   = "AWS/ApplicationELB"
        aws_metric_name = "HTTPCode_Target_4XX_Count"
        aws_dimensions  = ["LoadBalancer"]
        aws_statistics  = ["Sum"]
      },
      {
        aws_namespace   = "AWS/ApplicationELB"
        aws_metric_name = "HTTPCode_Target_5XX_Count"
        aws_dimensions  = ["LoadBalancer"]
        aws_statistics  = ["Sum"]
      },
      {
        aws_namespace   = "AWS/RDS"
        aws_metric_name = "CPUUtilization"
        aws_dimensions  = ["DBInstanceIdentifier"]
        aws_statistics  = ["Average", "Maximum"]
      },
      {
        aws_namespace   = "AWS/RDS"
        aws_metric_name = "DatabaseConnections"
        aws_dimensions  = ["DBInstanceIdentifier"]
        aws_statistics  = ["Average", "Maximum"]
      },
      {
        aws_namespace   = "AWS/RDS"
        aws_metric_name = "FreeableMemory"
        aws_dimensions  = ["DBInstanceIdentifier"]
        aws_statistics  = ["Average", "Minimum"]
      }
    ]
  })

  services = {
    stig = {
      image          = "nginx:stable"
      container_port = 80
      listener_port  = 80
      cpu            = 256
      memory         = 512
    }
    windmil = {
      image          = "nginx:stable"
      container_port = 80
      listener_port  = 8081
      cpu            = 256
      memory         = 512
    }
    orchestrator = {
      image          = "nginx:stable"
      container_port = 80
      listener_port  = 8082
      cpu            = 256
      memory         = 512
    }
    grafana = {
      image          = "grafana/grafana:latest"
      container_port = 3000
      listener_port  = 3000
      cpu            = 512
      memory         = 1024
      health_check   = "/api/health"
      environment = [
        {
          name  = "GF_METRICS_ENABLED"
          value = "true"
        },
        {
          name  = "GF_AUTH_SIGV4_AUTH_ENABLED"
          value = "true"
        }
      ]
      entrypoint = [
        "sh",
        "-c"
      ]
      command = [
        "mkdir -p /etc/grafana/provisioning/datasources && printf '%s' \"$GRAFANA_DATASOURCE_CONFIG\" > /etc/grafana/provisioning/datasources/amp.yaml && exec /run.sh"
      ]
      secrets = [
        {
          name      = "GRAFANA_DATASOURCE_CONFIG"
          valueFrom = aws_ssm_parameter.grafana_datasource_config.arn
        }
      ]
      docker_labels = {
        ECS_PROMETHEUS_EXPORTER_PORT = "3000"
        ECS_PROMETHEUS_EXPORTER_PATH = "/metrics"
        ECS_PROMETHEUS_JOB_NAME      = "grafana"
      }
      task_exec_ssm_param_arns = [
        aws_ssm_parameter.grafana_datasource_config.arn
      ]
      tasks_iam_role_statements = [
        {
          sid = "QueryAMP"
          actions = [
            "aps:QueryMetrics",
            "aps:GetLabels",
            "aps:GetSeries",
            "aps:GetMetricMetadata"
          ]
          resources = [
            "arn:aws:aps:${local.region}:${data.aws_caller_identity.current.account_id}:workspace/${var.amp_workspace_id}"
          ]
        }
      ]
      triggers = {
        grafana_datasource_config_sha = sha256(local.grafana_datasource_config_content)
      }
    }
  }

  adot_service = {
    cpu           = 512
    memory        = 1024
    desired_count = 1

    enable_execute_command = true

    triggers = {
      adot_config_sha = sha256(local.adot_config_content)
    }

    container_definitions = {
      adot = {
        image     = "public.ecr.aws/aws-observability/aws-otel-collector:v0.48.0"
        essential = true
        user      = "0"

        secrets = [
          {
            name      = "AOT_CONFIG_CONTENT"
            valueFrom = aws_ssm_parameter.adot_config.arn
          }
        ]

        readonlyRootFilesystem = false

        enable_cloudwatch_logging              = true
        create_cloudwatch_log_group            = true
        cloudwatch_log_group_name              = "/ecs/${local.name}/adot"
        cloudwatch_log_group_retention_in_days = 7
      }
    }

    task_exec_ssm_param_arns = [
      aws_ssm_parameter.adot_config.arn
    ]

    tasks_iam_role_statements = [
      {
        sid     = "WriteMetricsToAMP"
        actions = ["aps:RemoteWrite"]
        resources = [
          "arn:aws:aps:${local.region}:${data.aws_caller_identity.current.account_id}:workspace/${var.amp_workspace_id}"
        ]
      },
      {
        sid = "ReadCloudWatchMetrics"
        actions = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics"
        ]
        resources = ["*"]
      },
      {
        sid = "DiscoverECSTargets"
        actions = [
          "ecs:ListTasks",
          "ecs:ListServices",
          "ecs:DescribeServices",
          "ecs:DescribeTasks",
          "ecs:DescribeTaskDefinition",
          "ecs:DescribeContainerInstances"
        ]
        resources = ["*"]
      }
    ]

    subnet_ids = module.vpc.private_subnets
    vpc_id     = module.vpc.vpc_id

    security_group_egress_rules = {
      all = {
        ip_protocol = "-1"
        cidr_ipv4   = "0.0.0.0/0"
      }
    }

    service_tags = {
      Service = "adot"
    }
  }

  cloudwatch_exporter_service = {
    cpu           = 256
    memory        = 512
    desired_count = 1

    enable_execute_command = true

    triggers = {
      cloudwatch_exporter_config_sha = sha256(local.cloudwatch_exporter_config_content)
    }

    container_definitions = {
      config_writer = {
        image     = "public.ecr.aws/docker/library/busybox:stable"
        essential = false

        command = [
          "sh",
          "-c",
          "printf '%s' \"$CLOUDWATCH_EXPORTER_CONFIG\" > /config/config.yml"
        ]

        secrets = [
          {
            name      = "CLOUDWATCH_EXPORTER_CONFIG"
            valueFrom = aws_ssm_parameter.cloudwatch_exporter_config.arn
          }
        ]

        mountPoints = [
          {
            sourceVolume  = "cloudwatch-exporter-config"
            containerPath = "/config"
            readOnly      = false
          }
        ]

        readonlyRootFilesystem = false
      }

      cloudwatch_exporter = {
        image     = "prom/cloudwatch-exporter:v0.16.0"
        essential = true

        portMappings = [
          {
            name          = "cloudwatch-exporter"
            containerPort = 9106
            hostPort      = 9106
            protocol      = "tcp"
          }
        ]

        dependsOn = [
          {
            containerName = "config_writer"
            condition     = "SUCCESS"
          }
        ]

        mountPoints = [
          {
            sourceVolume  = "cloudwatch-exporter-config"
            containerPath = "/config"
            readOnly      = true
          }
        ]

        dockerLabels = {
          ECS_PROMETHEUS_EXPORTER_PORT = "9106"
          ECS_PROMETHEUS_EXPORTER_PATH = "/metrics"
          ECS_PROMETHEUS_JOB_NAME      = "cloudwatch-exporter"
        }

        readonlyRootFilesystem = false
      }
    }

    volume = {
      cloudwatch-exporter-config = {}
    }

    task_exec_ssm_param_arns = [
      aws_ssm_parameter.cloudwatch_exporter_config.arn
    ]

    tasks_iam_role_statements = [
      {
        sid = "ReadCloudWatchMetrics"
        actions = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "tag:GetResources"
        ]
        resources = ["*"]
      }
    ]

    subnet_ids = module.vpc.private_subnets
    vpc_id     = module.vpc.vpc_id

    security_group_ingress_rules = {
      vpc = {
        description = "Allow ADOT to scrape CloudWatch exporter"
        from_port   = 9106
        ip_protocol = "tcp"
        cidr_ipv4   = module.vpc.vpc_cidr_block
      }
    }
    security_group_egress_rules = {
      all = {
        ip_protocol = "-1"
        cidr_ipv4   = "0.0.0.0/0"
      }
    }

    service_tags = {
      Service = "cloudwatch-exporter"
    }
  }

  tags = {
    Name       = local.name
    Example    = local.name
    Repository = "https://github.com/terraform-aws-modules/terraform-aws-ecs"
  }
}

resource "aws_ssm_parameter" "adot_config" {
  name = "/${local.name}/adot/config"
  type = "String"

  value = local.adot_config_content

  tags = local.tags
}

resource "aws_ssm_parameter" "grafana_datasource_config" {
  name = "/${local.name}/grafana/datasource"
  type = "String"

  value = local.grafana_datasource_config_content

  tags = local.tags
}

resource "aws_ssm_parameter" "cloudwatch_exporter_config" {
  name = "/${local.name}/cloudwatch-exporter/config"
  type = "String"

  value = local.cloudwatch_exporter_config_content

  tags = local.tags
}

################################################################################
# Cluster and Services
################################################################################

module "ecs_cluster" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "7.5.0"

  cluster_name = local.name

  # Capacity provider
  cluster_capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy = {
    FARGATE = {
      weight = 50
      base   = 20
    }
    FARGATE_SPOT = {
      weight = 50
    }
  }

  services = merge(
    {
      for service_name, service in local.services : service_name => {
        cpu    = service.cpu
        memory = service.memory

        desired_count = 1

        # Enables ECS Exec
        enable_execute_command = true

        container_definitions = {
          (service_name) = {
            cpu        = service.cpu
            memory     = service.memory
            essential  = true
            image      = service.image
            command    = try(service.command, null)
            entrypoint = try(service.entrypoint, null)

            portMappings = [
              {
                name          = service_name
                containerPort = service.container_port
                hostPort      = service.container_port
                protocol      = "tcp"
              }
            ]

            # The stock nginx and Grafana images write runtime files by default.
            readonlyRootFilesystem = false

            environment  = try(service.environment, null)
            dockerLabels = try(service.docker_labels, null)
            secrets      = try(service.secrets, null)
          }
        }

        load_balancer = {
          service = {
            target_group_arn = module.alb.target_groups[service_name].arn
            container_name   = service_name
            container_port   = service.container_port
          }
        }

        subnet_ids = module.vpc.private_subnets
        vpc_id     = module.vpc.vpc_id

        triggers                  = try(service.triggers, null)
        task_exec_ssm_param_arns  = try(service.task_exec_ssm_param_arns, null)
        tasks_iam_role_statements = try(service.tasks_iam_role_statements, null)

        security_group_ingress_rules = {
          alb = {
            description                  = "Service port"
            from_port                    = service.container_port
            ip_protocol                  = "tcp"
            referenced_security_group_id = module.alb.security_group_id
          }
          vpc = {
            description = "Service metrics from VPC"
            from_port   = service.container_port
            ip_protocol = "tcp"
            cidr_ipv4   = module.vpc.vpc_cidr_block
          }
        }
        security_group_egress_rules = {
          all = {
            ip_protocol = "-1"
            cidr_ipv4   = "0.0.0.0/0"
          }
        }

        service_tags = {
          Service = service_name
        }
      }
    },
    {
      adot                  = local.adot_service
      "cloudwatch-exporter" = local.cloudwatch_exporter_service
    }
  )

  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 10.0"

  name = local.name

  load_balancer_type = "application"

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  # For example only
  enable_deletion_protection = false

  # Security Group
  security_group_ingress_rules = {
    for service_name, service in local.services : service_name => {
      from_port   = service.listener_port
      to_port     = service.listener_port
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
      description = "Allow ${service_name} listener"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = module.vpc.vpc_cidr_block
    }
  }

  listeners = {
    for service_name, service in local.services : service_name => {
      port     = service.listener_port
      protocol = "HTTP"

      forward = {
        target_group_key = service_name
      }
    }
  }

  target_groups = {
    for service_name, service in local.services : service_name => {
      backend_protocol                  = "HTTP"
      backend_port                      = service.container_port
      target_type                       = "ip"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true

      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        matcher             = "200"
        path                = try(service.health_check, "/")
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      # There's nothing to attach here in this definition. Instead,
      # ECS will attach the IPs of the tasks to this target group.
      create_attachment = false
    }
  }

  tags = local.tags
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.tags
}
