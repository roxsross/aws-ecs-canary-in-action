# ---- General ----

variable "aws_region" {
  description = "Region where the lab is deployed. Must match the region of the existing VPC."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix for every resource name. Keep it short: ALB and target group names are capped at 32 characters."
  type        = string
  default     = "canary-lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}$", var.project_name))
    error_message = "project_name must be 3-24 chars, lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "tags" {
  description = "Extra tags merged into every resource."
  type        = map(string)
  default     = {}
}

# ---- Network ----
# vpc_id empty (default) -> Terraform creates a minimal VPC.
# vpc_id set              -> nothing network related is created.

variable "vpc_id" {
  description = "ID of an existing VPC to deploy into. Leave empty (the default) to have Terraform create a small VPC for the lab."
  type        = string
  default     = ""

  validation {
    condition     = var.vpc_id == "" || can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must be empty, or look like vpc-0123456789abcdef0."
  }
}

variable "public_subnet_ids" {
  description = "Subnets for the internet facing ALB, in an existing VPC. At least two, in different availability zones. Required when vpc_id is set; ignored otherwise."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.public_subnet_ids) == 0 || length(var.public_subnet_ids) >= 2
    error_message = "An ALB needs at least two subnets in different availability zones."
  }
}

variable "service_subnet_ids" {
  description = "Subnets for the Fargate tasks, in an existing VPC. Defaults to public_subnet_ids when empty. Use private subnets only if they have a NAT gateway or the required VPC endpoints. Ignored when vpc_id is empty."
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "CIDR for the VPC Terraform creates. Only used when vpc_id is empty."
  type        = string
  default     = "10.42.0.0/16"
}

variable "vpc_az_count" {
  description = "How many availability zones to spread the created VPC's public subnets across. Only used when vpc_id is empty; the ALB needs at least 2."
  type        = number
  default     = 2

  validation {
    condition     = var.vpc_az_count >= 2
    error_message = "An ALB needs subnets in at least 2 availability zones."
  }
}

variable "assign_public_ip" {
  description = "Give tasks a public IP. Required when running in public subnets without NAT, which is the cheapest setup for a lab."
  type        = bool
  default     = true
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB on port 80. Defaults to the whole internet because the dashboard is meant to be shared; narrow it to your own IP for anything less disposable."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---- Container image ----

variable "ecr_repository_name" {
  description = "ECR repository holding the app image. Defaults to <project_name>-app."
  type        = string
  default     = ""
}

variable "create_ecr_repository" {
  description = "Let Terraform own the ECR repository. Leave false when the repository is created by scripts/build-push.sh, which is the default flow."
  type        = bool
  default     = false
}

variable "image_tag" {
  description = "Tag deployed to the stable service on the first apply."
  type        = string
  default     = "v1"
}

variable "container_image" {
  description = "Full image reference. Overrides ECR account/region/tag composition when set."
  type        = string
  default     = ""
}

variable "container_port" {
  description = "Port the app listens on."
  type        = number
  default     = 8080
}

# ---- ECS sizing ----

variable "task_cpu" {
  description = "Fargate CPU units per task."
  type        = string
  default     = "256"
}

variable "cpu_architecture" {
  description = "Must match the architecture the image was built for. scripts/build-push.sh builds a multi-arch (amd64+arm64) manifest by default, so X86_64 and ARM64 both work out of the box."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "task_memory" {
  description = "Fargate memory (MiB) per task. Must be valid for the chosen CPU."
  type        = string
  default     = "512"
}

variable "desired_count" {
  description = "Tasks running in the service. During a canary deployment ECS temporarily runs both the current and new revision side by side."
  type        = number
  default     = 2
}

variable "app_version" {
  description = "APP_VERSION reported by the running tasks. Bump it on each rollout so the dashboard shows which revision answered."
  type        = string
  default     = "1.0.0"
}

variable "enable_execute_command" {
  description = "Enable ECS Exec so you can shell into a task for debugging."
  type        = bool
  default     = true
}

# ---- Native ECS canary deployment (deployment_configuration) ----

variable "canary_percent" {
  description = "Percentage of production traffic shifted to the new revision during the canary phase."
  type        = number
  default     = 10

  validation {
    condition     = var.canary_percent >= 0.1 && var.canary_percent <= 100
    error_message = "canary_percent must be between 0.1 and 100."
  }
}

variable "canary_bake_time_in_minutes" {
  description = "Minutes to hold the canary traffic split before shifting the rest, if the alarms below stay OK."
  type        = number
  default     = 5

  validation {
    condition     = var.canary_bake_time_in_minutes >= 0 && var.canary_bake_time_in_minutes <= 1440
    error_message = "canary_bake_time_in_minutes must be between 0 and 1440."
  }
}

variable "bake_time_in_minutes" {
  description = "Minutes both revisions run side by side after 100% of traffic has shifted, before ECS terminates the old one. Gives an instant traffic rollback window without a redeploy."
  type        = number
  default     = 5

  validation {
    condition     = var.bake_time_in_minutes >= 0 && var.bake_time_in_minutes <= 1440
    error_message = "bake_time_in_minutes must be between 0 and 1440."
  }
}

# ---- Load balancer behaviour ----

variable "deregistration_delay" {
  description = "Seconds the ALB keeps draining a removed target. Low on purpose so rollbacks feel instant."
  type        = number
  default     = 10
}

variable "health_check_path" {
  description = "Target group health check path."
  type        = string
  default     = "/api/health"
}

variable "health_check_interval" {
  description = "Seconds between target group health checks."
  type        = number
  default     = 15
}

variable "healthy_threshold" {
  description = "Consecutive successes before a target is considered healthy."
  type        = number
  default     = 2
}

variable "unhealthy_threshold" {
  description = "Consecutive failures before a target is considered unhealthy."
  type        = number
  default     = 2
}

variable "enable_deletion_protection" {
  description = "Protect the ALB from accidental deletion. Off for a lab you want to tear down."
  type        = bool
  default     = false
}

# ---- Observability and alarms (trigger the automatic rollback) ----

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the app log group."
  type        = number
  default     = 7
}

variable "alarm_period" {
  description = "Alarm evaluation period in seconds."
  type        = number
  default     = 60
}

variable "alarm_evaluation_periods" {
  description = "Periods that must breach before the alarm fires. 1 keeps a live demo snappy; use 2-3 in production."
  type        = number
  default     = 1
}

variable "alarm_5xx_threshold" {
  description = "Number of 5xx responses from the canary target group, per period, that trips the alarm."
  type        = number
  default     = 3
}

variable "alarm_latency_threshold_seconds" {
  description = "p95 target response time (seconds) from the canary target group that trips the alarm."
  type        = number
  default     = 1
}

variable "alarm_error_rate_threshold" {
  description = "Canary error rate (percent, from the EMF metrics the app emits) that trips the alarm."
  type        = number
  default     = 5
}

variable "enable_emf_alarm" {
  description = "Create the error rate alarm built on the app's embedded metrics."
  type        = bool
  default     = true
}

variable "enable_dashboard" {
  description = "Create a CloudWatch dashboard comparing both tracks."
  type        = bool
  default     = true
}

variable "metrics_namespace" {
  description = "Namespace for the app's embedded metrics."
  type        = string
  default     = "CanaryLab"
}

variable "alarm_sns_topic_arns" {
  description = "Optional SNS topics notified on ALARM and OK."
  type        = list(string)
  default     = []
}

# ---- App configuration ----

variable "admin_token" {
  description = "When set, /api/chaos and /api/reset require the X-Admin-Token header. Leave empty for an open lab."
  type        = string
  default     = ""
  sensitive   = true
}

variable "record_mode" {
  description = "How much traffic detail is written to DynamoDB: full, agg or off."
  type        = string
  default     = "full"

  validation {
    condition     = contains(["full", "agg", "off"], var.record_mode)
    error_message = "record_mode must be one of: full, agg, off."
  }
}
