# ==============================================================================
# ESMERALDA LAYER 4 GOVERNANCE & OBSERVABILITY ORCHESTRATOR MODULE
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.0"
    }
  }
}

locals {
  monitored_projects = toset(var.spoke_project_ids)
}

# 1. Attach Workload Spoke Projects to Central Governance Metrics Scope
resource "google_monitoring_monitored_project" "spoke_projects" {
  for_each      = local.monitored_projects
  metrics_scope = "locations/global/metricsScopes/${var.governance_project_id}"
  name          = each.value
}

# 2. Submodule 1: Telemetry Sinks (Log Sinks & Dataset Permissions)
module "telemetry_sinks" {
  source                = "./modules/1_telemetry_sinks"
  environment           = var.environment
  governance_project_id = var.governance_project_id
  spoke_project_ids     = var.spoke_project_ids
}

# 3. Submodule 2: DLP Inspection Templates
module "dlp_inspection" {
  source                = "./modules/2_dlp_inspection"
  governance_project_id = var.governance_project_id
}

# 4. Submodule 3: Alert Policies & Pub/Sub notification channel
module "alert_policies" {
  source                           = "./modules/3_alert_policies"
  environment                      = var.environment
  governance_project_id            = var.governance_project_id
  spoke_project_ids                = var.spoke_project_ids
  alert_email_address              = var.alert_email_address
  runaway_loop_token_threshold     = var.runaway_loop_token_threshold
  gateway_service_name             = var.ingress_gateway_service_name
  gateway_error_rate_threshold_pct = var.monitoring_config.error_rate_threshold_pct
}

# 5. Submodule 4: FinOps Analytics (Token Events Table & Chargeback View)
module "finops_analytics" {
  source                = "./modules/4_finops_analytics"
  environment           = var.environment
  governance_project_id = var.governance_project_id
  depends_on            = [module.telemetry_sinks]
}

# 6. Submodule 5: Model Armor Guardrail Templates
module "model_armor" {
  source                = "./modules/5_model_armor"
  environment           = var.environment
  governance_project_id = var.governance_project_id
}

# 7. Submodule 6: Central Agent Gateway & Registry (August 2026 Release)
module "agent_gateway" {
  source                    = "./modules/6_agent_gateway"
  environment               = var.environment
  governance_project_id     = var.governance_project_id
  region                    = var.region
  subnet_self_link          = var.subnet_self_link
  net_host_project_id       = var.net_host_project_id
  vpc_name                  = var.vpc_name
  model_armor_template_name = module.model_armor.prompt_template_name
  agent_invoker_sa_emails   = var.agent_invoker_sa_emails
  agent_project_ids         = var.agent_project_ids
  enable_agent_gateway      = var.enable_agent_gateway
  internal_root_ca_pem      = var.internal_root_ca_pem
}

# 8. Wiz GCP Connector (Folder Scope + Cloud Events + Serverless & Data Scanning)
module "wiz" {
  source                           = "https://wizio-public.s3.amazonaws.com/deployment-v3/gcp/terraform/latest/wiz-gcp-native-roles-terraform-module.zip"
  folder_id                        = "508277344479"
  worker_service_account_id        = "" # SaaS mode (clgcporg169-p001 outpost project no longer exists in GCP)
  wiz_managed_identity_external_id = "wizabe4ab4a70005d150b8d8e09080@prod-eu19.iam.gserviceaccount.com"
  serverless_scanning              = true
  data_scanning                    = true
  enable_shadow_data               = true
  forensic                         = true
  cloud_events                     = true
  cloud_events_project_id          = var.governance_project_id # resolves to esm-dev-governance-11d4
}

# 9. Grant Gemini Enterprise Agent Platform (GEAP) read permissions to Wiz Fetcher SA on the Folder
# (roles/wiz.cloudInventoryViewer does not yet bundle the new GEAP Agent Gateway / Agent Registry / Model Armor viewer permissions)
resource "google_folder_iam_member" "wiz_geap_viewer_roles" {
  for_each = toset([
    "roles/networkservices.viewer",
    "roles/agentregistry.viewer",
    "roles/networksecurity.viewer",
    "roles/modelarmor.viewer",
    "roles/iam.securityReviewer",
  ])
  folder = "folders/508277344479"
  role   = each.value
  member = "serviceAccount:wizabe4ab4a70005d150b8d8e09080@prod-eu19.iam.gserviceaccount.com"
}


# ------------------------------------------------------------------------------
# TERRAFORM MOVED BLOCKS (Refactoring root resources into submodules)
# ------------------------------------------------------------------------------

moved {
  from = google_logging_project_sink.central_sinks
  to   = module.telemetry_sinks.google_logging_project_sink.central_sinks
}

moved {
  from = google_bigquery_dataset_iam_member.dataset_writers
  to   = module.telemetry_sinks.google_bigquery_dataset_iam_member.dataset_writers
}

moved {
  from = google_data_loss_prevention_inspect_template.pii_redaction
  to   = module.dlp_inspection.google_data_loss_prevention_inspect_template.pii_redaction
}

moved {
  from = google_pubsub_topic.monitoring_alerts_topic
  to   = module.alert_policies.google_pubsub_topic.monitoring_alerts_topic
}

moved {
  from = google_monitoring_notification_channel.email_alert
  to   = module.alert_policies.google_monitoring_notification_channel.email_alert
}

moved {
  from = google_monitoring_notification_channel.pubsub_alert
  to   = module.alert_policies.google_monitoring_notification_channel.pubsub_alert
}

moved {
  from = google_logging_metric.realtime_token_consumption
  to   = module.alert_policies.google_logging_metric.realtime_token_consumption
}

moved {
  from = google_monitoring_alert_policy.runaway_loop_token_cap
  to   = module.alert_policies.google_monitoring_alert_policy.runaway_loop_token_cap
}

moved {
  from = google_monitoring_alert_policy.reasoning_engine_quota
  to   = module.alert_policies.google_monitoring_alert_policy.reasoning_engine_quota
}

moved {
  from = google_bigquery_table.token_events
  to   = module.finops_analytics.google_bigquery_table.token_events
}

moved {
  from = google_bigquery_table.vw_monthly_chargeback
  to   = module.finops_analytics.google_bigquery_table.vw_monthly_chargeback
}
