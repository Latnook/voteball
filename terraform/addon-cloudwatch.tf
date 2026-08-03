# IRSA for the CloudWatch agent. No pre-baked helper toggle exists for CloudWatch, so attach AWS's
# managed CloudWatchAgentServerPolicy (write-only telemetry: logs:PutLogEvents/CreateLogStream/
# CreateLogGroup + cloudwatch:PutMetricData) via role_policy_arns. The add-on's SA is
# amazon-cloudwatch:cloudwatch-agent.
module "cloudwatch_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-cloudwatch-irsa"
  role_policy_arns = {
    cloudwatch = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["amazon-cloudwatch:cloudwatch-agent"]
    }
  }
}

# Fluent Bit's application-log pipeline, narrowed to the app namespace.
#
# This string REPLACES the add-on's default application-log.conf -- it is not merged into it. An
# omitted [FILTER] or [OUTPUT] block therefore does not error: Fluent Bit starts, reports healthy,
# and silently ships nothing. It was copied verbatim out of the live `fluent-bit-config` ConfigMap
# of add-on v6.3.0 (`kubectl get cm fluent-bit-config -n amazon-cloudwatch`) and changed in exactly
# two ways, both marked below. Re-copy it from the cluster if the add-on version is ever bumped.
locals {
  cloudwatch_app_namespace = "devops-app"

  # CHANGE 1: Path was /var/log/containers/*.log -- every pod in every namespace. Scoping it to the
  #   app namespace drops ci (Jenkins + BuildKit build output), argocd, monitoring, kube-system and
  #   external-secrets, which together were ~95% of the volume. Losing the Jenkins build logs is
  #   consistent with this repo's existing position that JENKINS_HOME is disposable and the durable
  #   CI record is the `ci: image tag <sha>` commits on master, not console output.
  # CHANGE 2: the two extra [INPUT] blocks that tailed Fluent Bit's and the CloudWatch agent's OWN
  #   logs are gone, along with the now-redundant Exclude_Path. They are agents logging about
  #   themselves; `kubectl logs -n amazon-cloudwatch` still reaches them when something breaks.
  fluent_bit_application_log_conf = <<-EOT
    [INPUT]
      Name                tail
      Tag                 application.*
      Path                /var/log/containers/*_${local.cloudwatch_app_namespace}_*.log
      multiline.parser    docker, cri
      DB                  /var/fluent-bit/state/flb_container.db
      Mem_Buf_Limit       50MB
      Skip_Long_Lines     On
      Refresh_Interval    10
      Rotate_Wait         30
      storage.type        filesystem
      Read_from_Head      $${READ_FROM_HEAD}

    [FILTER]
      Name                aws
      Match               application.*
      az                  false
      ec2_instance_id     false
      Enable_Entity       true

    [FILTER]
      Name                kubernetes
      Match               application.*
      Kube_URL            https://kubernetes.default.svc:443
      Kube_Tag_Prefix     application.var.log.containers.
      Merge_Log           On
      Merge_Log_Key       log_processed
      K8S-Logging.Parser  On
      K8S-Logging.Exclude Off
      Labels              Off
      Annotations         Off
      Use_Kubelet         On
      Kubelet_Port        10250
      Buffer_Size         0
      Use_Pod_Association On

    [OUTPUT]
      Name                cloudwatch_logs
      Match               application.*
      region              $${AWS_REGION}
      log_group_name      /aws/containerinsights/$${CLUSTER_NAME}/application
      log_stream_prefix   $${HOST_NAME}-
      auto_create_group   true
      extra_user_agent    container-insights
      add_entity          true
  EOT
}

# CloudWatch pod logging (AWS-managed EKS add-on): deploys Fluent Bit to ship pod logs to CloudWatch
# Logs. Logging lives outside the cluster (AWS-native, IAM-gated) -- keeps the node RAM budget
# lighter than an in-cluster Loki.
#
# EVERYTHING ELSE THIS ADD-ON CAN DO IS DELIBERATELY OFF, because it is metered and this stack
# already collects the same signals for free. Measured on this account before the change:
#
#   - containerInsights   ~3.1 GB/day into .../performance, and $3.00/day of CW:ObservationUsage
#                         ($30.03 in July alone). 61% of those records were Type=ControlPlane --
#                         apiserver/etcd/scheduler metrics that kube-prometheus-stack ALREADY
#                         scrapes into Grafana at no charge. It was a paid second copy.
#   - applicationSignals  the sole source of this account's ~89k monthly X-Ray traces, plus
#                         ~25 MB/day into /aws/application-signals/data.
#   - kubeStateMetrics    duplicates kube-prometheus-stack's own kube-state-metrics.
#   - nodeExporter        duplicates kube-prometheus-stack's own node-exporter -- and as a DaemonSet
#                         requesting 256m CPU / 128Mi it was billed in Spot node capacity too.
#   - dcgmExporter        GPU telemetry; this node group has no GPUs.
#   - neuronMonitor       Inferentia/Trainium telemetry; likewise.
#
# Re-enabling containerInsights or applicationSignals costs real money per day. Do not flip either
# back on to "get more observability" without checking Grafana first -- it is almost certainly
# already there. See docs/production-readiness.md and the alert rules in charts/voteball.
resource "aws_eks_addon" "cloudwatch" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "amazon-cloudwatch-observability"
  addon_version            = "v6.3.0-eksbuild.1" # verified for K8s 1.34 via aws eks describe-addon-versions (2026-07-19)
  service_account_role_arn = module.cloudwatch_irsa.iam_role_arn

  configuration_values = jsonencode({
    containerInsights  = { enabled = false }
    applicationSignals = { enabled = false }
    kubeStateMetrics   = { enabled = false }
    nodeExporter       = { enabled = false }
    dcgmExporter       = { enabled = false }
    neuronMonitor      = { enabled = false }

    containerLogs = {
      enabled = true
      fluentBit = {
        config = {
          extraFiles = {
            "application-log.conf" = local.fluent_bit_application_log_conf
          }
        }
      }
    }
  })

  # Depends on the log groups so the add-on adopts groups that already carry a retention policy,
  # rather than auto-creating never-expiring ones (see aws_cloudwatch_log_group.fluent_bit below).
  #
  # The ALB controller installs a cluster-wide mutating webhook on Services. Without this dependency,
  # Terraform creates this add-on in PARALLEL with the ALB release, and the add-on's Service can hit
  # the webhook before its backend pods are Ready -> AdmissionRequestDenied (hit once on first apply,
  # 2026-07-19). Depending on the ALB release (helm waits for its Deployment to be available) forces
  # the webhook backend to exist before this add-on creates any Service.
  depends_on = [
    helm_release.aws_load_balancer_controller,
    aws_cloudwatch_log_group.fluent_bit,
  ]
}

# The three log groups Fluent Bit writes: pod logs, node-agent logs (kubelet/containerd/CNI) and
# host logs. Every one of its [OUTPUT] blocks sets auto_create_group true, which creates them with
# retention "Never expire" -- so before this existed they survived `terraform destroy` and kept
# accumulating across every rebuild, billed forever, owned by no stack.
#
# 7 days is chosen against how this stack is actually used: it is rebuilt often enough that
# month-old pod logs describe infrastructure that no longer exists, and Grafana holds the metrics.
# Raise it if you ever need to investigate something a week after it happened.
#
# NOTE FOR AN EXISTING CLUSTER: these groups already exist, so the first apply after adding this
# needs a one-time import per group or it fails with ResourceAlreadyExistsException. Deleting them
# instead does not work -- Fluent Bit recreates them within seconds, before apply gets there:
#   terraform import 'aws_cloudwatch_log_group.fluent_bit["application"]' /aws/containerinsights/voteball/application
# A fresh (or forked) deploy needs none of this; the groups do not exist yet.
resource "aws_cloudwatch_log_group" "fluent_bit" {
  for_each = toset(["application", "dataplane", "host"])

  name              = "/aws/containerinsights/${var.cluster_name}/${each.key}"
  retention_in_days = 7
}
