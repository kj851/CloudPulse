# CloudPulse FinOps Dashboard - Main Shiny App
# This app provides an interface for querying and visualizing
# cloud cost and usage data across multiple CSPs AWS, Azure, and GCP.
# It includes a credential entry page, dynamic query configuration,
# and interactive visualizations with forecasting capabilities.
# Secure credential handling and error management are implemented.
# Copyright (c) 2026, Keaton Szantho

library(shiny)
library(plotly)
library(dplyr)
library(DT)
library(ggridges)
library(ggplot2)
library(bslib)
library(promises)
library(forecast)
library(DBI)
library(shinycssloaders)
library(jsonlite)

if (requireNamespace("future", quietly = TRUE)) {
  future::plan(future::multisession)
} else {
  message("'future' package not available; async futures disabled.")
}

`%notin%` <- function(x, y) !(x %in% y)
spinner <- function(expr, ...) expr

get_mock_cost                   <- NULL
get_mock_usage                  <- NULL
get_mock_metadata               <- NULL
get_mock_instances              <- NULL
gcp_db_instances_metadata       <- NULL
aws_rds_instances_metadata      <- NULL
azure_db_instances_metadata     <- NULL
aws_rds_instances_metadata      <- NULL
gcp_db_instance_usage           <- NULL
aws_rds_instance_usage          <- NULL
azure_db_instance_usage         <- NULL
gcp_db_cost_by_instance         <- NULL
aws_rds_cost_by_instance        <- NULL
azure_db_cost_by_instance       <- NULL
train_forecast_usage            <- NULL

# ══════════════════════════════════════════════════════════════════════════════
# SECURITY MODULE
# ══════════════════════════════════════════════════════════════════════════════

# Global constants for security and input validation
max_login_attempts  <- 5L        # lock out after this many failures
lockout_seconds     <- 1200L      # 20-minute lockout window
session_timeout   <- 3600L     # auto-logout after 1 hour of inactivity
max_input_chars    <- 500L      # max chars for free-text fields
max_note_chars    <- 1000L     # max chars for notes/textarea fields

# Input sanitisation
sanitize_text <- function(x, max_len = max_input_chars) {
  if (is.null(x) || !is.character(x)) return("")
  x <- trimws(x)
  # Strip HTML / script tags
  x <- gsub("<[^>]*>", "", x, perl = TRUE)
  # Strip shell metacharacters
  x <- gsub("[;&|`$(){}\\<>]", "", x, perl = TRUE)
  # Truncate
  if (nchar(x) > max_len) x <- substr(x, 1, max_len)
  x
}

sanitize_uuid <- function(x) {
  x <- trimws(x %||% "")
  if (!grepl("^[0-9a-fA-F\\-]{8,36}$", x, perl = TRUE)) return("")
  x
}

sanitize_aws_key <- function(x) {
  x <- trimws(x %||% "")
  # AWS access keys: AKIA/ASIA/AROA + 16 uppercase alphanumeric
  if (!grepl(
    "^(AKIA|ASIA|AROA|AGPA|AIDA|AIPA|ANPA|ANVA|APKA)[A-Z0-9]{16}$",
    x, perl = TRUE
  )) return("")
  x
}

sanitize_aws_region <- function(x) {
  x <- trimws(x %||% "")
  valid_regions <- c(
    "us-east-1","us-east-2","us-west-1","us-west-2",
    "eu-west-1","eu-west-2","eu-west-3","eu-central-1","eu-north-1",
    "ap-southeast-1","ap-southeast-2","ap-northeast-1","ap-northeast-2",
    "ap-south-1","sa-east-1","ca-central-1","me-south-1","af-south-1",
    "gov-east-1", "gov-west-1", "us-gov-east-1","us-gov-west-1",
    "cn-north-1", "cn-northwest-1", "us-iso-east-1", "us-isob-east-1",
  )
  if (x %notin% valid_regions) return("us-east-1")
  x
}

sanitize_gcp_project <- function(x) {
  x <- trimws(x %||% "")
  # GCP project IDs: lowercase letters, digits, hyphens, 6-30 chars
  if (!grepl("^[a-z][a-z0-9\\-]{4,28}[a-z0-9]$", x, perl = TRUE)) return("")
  x
}

sanitize_gcp_json <- function(x) {
  x <- trimws(x %||% "")
  if (nchar(x) > 10000) return("")  # sanity size limit
  # Must be parseable JSON containing expected service account fields
  result <- tryCatch(
    jsonlite::fromJSON(x),
    error = function(e) NULL
  )
  if (is.null(result)) return("")
  required_fields <- c("type", "project_id", "private_key_id", "client_email")
  if (!all(required_fields %in% names(result))) return("")
  if (!identical(result$type, "service_account")) return("")
  x
}

sanitize_datetime <- function(x) {
  x <- trimws(x %||% "")
  # Accept YYYY-MM-DD HH:MM only
  if (!grepl("^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}$", x, perl = TRUE)) return("")
  dt <- tryCatch(as.POSIXct(
    x, format = "%Y-%m-%d %H:%M"
  ), error = function(e) NA)
  if (is.na(dt)) return("")
  if (dt <= Sys.time()) return("")  # must be in the future
  x
}

sanitize_instance_list <- function(x) {
  x <- trimws(x %||% "")
  # Comma-separated alphanumeric + hyphen identifiers only
  parts <- trimws(strsplit(x, ",")[[1]])
  parts <- parts[grepl(
    "^[a-zA-Z0-9][a-zA-Z0-9\\-_]{0,62}$",
    parts, perl = TRUE
  )]
  paste(parts, collapse = ", ")
}

sanitize_numeric <- function(x, min_val, max_val, default_val) {
  x <- suppressWarnings(as.numeric(x))
  if (is.na(x) || x < min_val || x > max_val) return(default_val)
  floor(x)
}

`%||%` <- function(a, b) if (!is.null(a)) a else b

# Rate limiter
# Per-session login attempt tracking
# (stored in reactiveValues passed from server)
check_rate_limit <- function(attempts, last_attempt_time) {
  now <- Sys.time()
  # Reset counter if lockout window has passed
  if (!is.null(last_attempt_time) &&
    as.numeric(difftime(
      now, last_attempt_time, units = "secs"
    )) > lockout_seconds) {
    return(list(locked = FALSE, attempts = 0L, reset = TRUE))
  }
  locked <- !is.null(attempts) && attempts >= max_login_attempts
  list(locked = locked, attempts = attempts %||% 0L, reset = FALSE)
}

remaining_lockout <- function(last_attempt_time) {
  if (is.null(last_attempt_time)) return(0)
  elapsed <- as.numeric(difftime(Sys.time(), last_attempt_time, units = "secs"))
  max(0, lockout_seconds - elapsed)
}

# Safe error messages
safe_error <- function(e) {
  # Map known error types to user-friendly messages
  msg <- conditionMessage(e)
  if (grepl(
    "credentials|auth|permission|access denied",
    msg, ignore.case = TRUE
  ))
    return("Authentication failed. Please check your credentials.")
  if (grepl("network|connection|timeout|refused", msg, ignore.case = TRUE))
    return("Connection error. Please check your network and try again.")
  if (grepl("not found|no such", msg, ignore.case = TRUE))
    return("Resource not found. Please verify your configuration.")
  # Generic fallback — never expose raw error text
  "An unexpected error occurred. Please try again."
}

# Security load data files
source("data/aws.r")
source("data/azure.r")
source("data/GCP.r")
source("data/mock.r")
source("data/forecast.r")
source("data/kubernetes.r")

# Theme and CSS
modern_theme <- bs_theme(
  preset    = "bootstrap",
  primary   = "#0D6EFD",
  secondary = "#6C757D",
  success   = "#198754",
  danger    = "#DC3545",
  warning   = "#FFC107",
  info      = "#0DCAF0",
  light     = "#F8F9FA",
  dark      = "#212529",
  base_font = font_collection(font_google("Inter"), "sans-serif")
)

app_css <- HTML("
  body { font-family: 'Inter', sans-serif; }
  .navbar { display: none; }

  /* ── Light mode cards ── */
  .card {
    border: none;
    box-shadow: 0 0.125rem 0.25rem rgba(0,0,0,0.075);
  }
  .card-header {
    background-color: #f8f9fa;
  }

  /* ── Dark mode — white text everywhere ── */
  [data-bs-theme='dark'] body,
  [data-bs-theme='dark'],
  [data-bs-theme='dark'] .card,
  [data-bs-theme='dark'] .card-body,
  [data-bs-theme='dark'] .card-header,
  [data-bs-theme='dark'] .card-title,
  [data-bs-theme='dark'] p,
  [data-bs-theme='dark'] h1,
  [data-bs-theme='dark'] h2,
  [data-bs-theme='dark'] h3,
  [data-bs-theme='dark'] h4,
  [data-bs-theme='dark'] h5,
  [data-bs-theme='dark'] h6,
  [data-bs-theme='dark'] label,
  [data-bs-theme='dark'] .form-label,
  [data-bs-theme='dark'] .form-check-label,
  [data-bs-theme='dark'] .text-muted,
  [data-bs-theme='dark'] small,
  [data-bs-theme='dark'] span,
  [data-bs-theme='dark'] td,
  [data-bs-theme='dark'] th,
  [data-bs-theme='dark'] .sidebar,
  [data-bs-theme='dark'] .bslib-sidebar-layout > .sidebar { color: #ffffff !important; }

  [data-bs-theme='dark'] .card { background-color: #1e2535 !important; }
  [data-bs-theme='dark'] .card-header { background-color: #161d2e !important; }
  [data-bs-theme='dark'] .sidebar,
  [data-bs-theme='dark'] .bslib-sidebar-layout > .sidebar { background-color: #161d2e !important; }
  [data-bs-theme='dark'] hr { border-color: #2d3748; }
  [data-bs-theme='dark'] .form-control,
  [data-bs-theme='dark'] .form-select { background-color: #2d3748 !important; color: #ffffff !important; border-color: #4a5568 !important; }
  [data-bs-theme='dark'] .form-control::placeholder { color: #a0aec0 !important; }
  [data-bs-theme='dark'] .dataTables_wrapper,
  [data-bs-theme='dark'] table.dataTable { color: #ffffff !important; background-color: #1e2535 !important; }
  [data-bs-theme='dark'] table.dataTable thead th { background-color: #161d2e !important; color: #ffffff !important; }
  [data-bs-theme='dark'] table.dataTable tbody tr:nth-child(odd) { background-color: #252f42 !important; }
  [data-bs-theme='dark'] table.dataTable tbody tr:nth-child(even) { background-color: #1e2535 !important; }
  [data-bs-theme='dark'] .dataTables_info,
  [data-bs-theme='dark'] .dataTables_length label,
  [data-bs-theme='dark'] .dataTables_filter label { color: #ffffff !important; }
  [data-bs-theme='dark'] .alert { color: #ffffff !important; }
  [data-bs-theme='dark'] .badge { color: #ffffff !important; }

  /* ── Buttons ── */
  .btn-primary { background-color: #667eea; border-color: #667eea; }
  .btn-primary:hover { background-color: #764ba2; border-color: #764ba2; }

  /* ── Dev page cards ── */
  .instance-card { transition: box-shadow 0.2s; }
  .instance-card:hover { box-shadow: 0 0.5rem 1rem rgba(0,0,0,0.15) !important; }
  .status-badge { font-size: 0.75rem; padding: 0.25rem 0.6rem; border-radius: 999px; }
  .status-running  { background-color: #d1fae5; color: #065f46; }
  .status-stopped  { background-color: #fee2e2; color: #991b1b; }
  .status-pending  { background-color: #fef3c7; color: #92400e; }
  [data-bs-theme='dark'] .status-running  { background-color: #065f46; color: #d1fae5; }
  [data-bs-theme='dark'] .status-stopped  { background-color: #991b1b; color: #fee2e2; }
  [data-bs-theme='dark'] .status-pending  { background-color: #92400e; color: #fef3c7; }
")

# Credentials UI

# Multi-cloud credentials UI (replaces single-provider login)
credentials_ui <- function() {
  div(
    class = "d-flex align-items-center justify-content-center min-vh-100 py-5",
    style = "background: linear-gradient(135deg, #0D1F3C 0%, #1a3a5c 50%, #0D1F3C 100%);",
    div(
      style = "width: 100%; max-width: 700px; padding: 0 1rem;",

      # Header
      div(class = "text-center mb-4",
        tags$img(src = "logo.png", height = "60px",
          onerror = "this.style.display='none'", style = "margin-bottom: 0.5rem;"),
        h1("CloudPulse", class = "fw-bold text-white mb-1", style = "font-size: 2.2em;"),
        p("Multi-Cloud FinOps & Infrastructure Platform", class = "mb-0",
          style = "color: #38BDF8; font-size: 1em; letter-spacing: 2px; text-transform: uppercase;")
      ),

      div(class = "card shadow-lg p-4",
        style = "border: none; border-radius: 16px; background: rgba(255,255,255,0.97);",

        h5("Connect Cloud Providers", class = "fw-bold mb-1"),
        p("Connect one or more providers simultaneously.", class = "text-muted small mb-4"),

        # Tabs for each provider
        navset_tab(
          nav_panel("AWS",
            div(class = "pt-3",
              div(class = "form-check form-switch mb-3",
                checkboxInput("connect_aws", "Connect AWS", value = FALSE),
              ),
              conditionalPanel("input.connect_aws == true",
                div(class = "mb-2", textInput("aws_access_key", "Access Key ID",
                  placeholder = "AKIA...", width = "100%")),
                div(class = "mb-2", passwordInput("aws_secret_key", "Secret Access Key",
                  placeholder = "Enter secret key", width = "100%")),
                div(class = "mb-2", textInput("aws_region", "Region",
                  value = "us-east-1", width = "100%")),
                div(class = "mb-2",
                  checkboxInput("aws_k8s_enabled", "Include EKS clusters", value = FALSE))
              )
            )
          ),
          nav_panel("Azure",
            div(class = "pt-3",
              div(class = "form-check form-switch mb-3",
                checkboxInput("connect_azure", "Connect Azure", value = FALSE)
              ),
              conditionalPanel("input.connect_azure == true",
                div(class = "mb-2", textInput("azure_subscription", "Subscription ID",
                  placeholder = "UUID", width = "100%")),
                div(class = "mb-2", textInput("azure_tenant", "Tenant ID",
                  placeholder = "UUID", width = "100%")),
                div(class = "mb-2", textInput("azure_client_id", "Client ID",
                  placeholder = "UUID", width = "100%")),
                div(class = "mb-2", passwordInput("azure_client_secret", "Client Secret",
                  placeholder = "Enter secret", width = "100%")),
                div(class = "mb-2",
                  checkboxInput("azure_k8s_enabled", "Include AKS clusters", value = FALSE))
              )
            )
          ),
          nav_panel("GCP",
            div(class = "pt-3",
              div(class = "form-check form-switch mb-3",
                checkboxInput("connect_gcp", "Connect GCP", value = FALSE)
              ),
              conditionalPanel("input.connect_gcp == true",
                div(class = "mb-2", textInput("gcp_project_id", "Project ID",
                    placeholder = "my-project",
                    width = "100%"
                  )
                ),
                div(
                  class = "mb-2",
                  textAreaInput("gcp_service_account", "Service Account JSON",
                    placeholder = "Paste service account key JSON",
                    rows = 4, width = "100%"
                  )
                ),
                div(class = "mb-2",
                  checkboxInput(
                    "gcp_k8s_enabled", "Include GKE clusters",
                    value = FALSE
                  )
                )
              )
            )
          ),
          nav_panel("Mock / Demo",
            div(class = "pt-3",
              div(class = "alert alert-info",
                icon("circle-info"),
                " Uses realistic mock data for all providers.",
                tags$br(),
                tags$small("Enables all features without real credentials.")
              ),
              checkboxInput(
                "use_mock_all", "Use mock data for all providers",
                value = TRUE
              ),
              conditionalPanel("input.use_mock_all == true",
                div(class = "alert alert-success p-2",
                  tags$small("✅ Mock mode: AWS, Azure, GCP,
                   and Kubernetes data will be simulated.")
                )
              )
            )
          )
        ),

        hr(),
        div(class = "d-grid gap-2",
          actionButton("login_btn", "Connect & Launch Dashboard",
            class = "btn btn-primary btn-lg fw-bold",
            style = "border-radius: 10px; background: #0D1F3C; border-color: #0D1F3C;")
        ),
        div(class = "text-center mt-2",
          tags$small("Credentials are stored 
          in-session only and never persisted.",
            class = "text-muted"
          )
        )
      )
    )
  )
}

# Kubernetes health page
k8s_ui <- function() {
  div(class = "p-4",

    div(class = "mb-4",
      h2("☸ Kubernetes Cluster Health", class = "fw-bold"),
      p("Real-time health monitoring 
      across all connected clusters.", class = "text-muted")
    ),

    # Cluster selector + controls
    layout_columns(col_widths = c(12),
      card(
        card_body(
          div(class = "d-flex align-items-center gap-3 flex-wrap",
            div(style = "flex: 1; min-width: 200px;",
              tags$label("Cluster", class = "form-label fw-bold small mb-1"),
              uiOutput("k8s_cluster_select_ui")
            ),
            div(style = "flex: 1; min-width: 150px;",
              tags$label("Namespace", class = "form-label fw-bold small mb-1"),
              selectInput(
                "k8s_namespace", NULL,
                choices = c(
                  "all" = "", "default", "kube-system", "prod", "staging"
                ),
                width = "100%"
              )
            ),
            div(style = "flex: 0;",
              tags$label(" ", class = "form-label fw-bold small mb-1 d-block"),
              actionButton("k8s_refresh", "↻ Refresh",
                class = "btn btn-outline-primary"
              )
            ),
            div(style = "flex: 0;",
              tags$label(" ", class = "form-label fw-bold small mb-1 d-block"),
              checkboxInput("k8s_auto_refresh", "Auto (30s)", value = FALSE)
            )
          )
        )
      )
    ),

    # Cluster summary KPIs
    uiOutput("k8s_kpi_cards"),

    # Metrics chart
    layout_columns(col_widths = c(8, 4),
      card(full_screen = TRUE,
        card_header(tags$span(
          "📈 Cluster Metrics (last hour)", class = "fw-bold"
        )),
        card_body(plotlyOutput(
          "k8s_metrics_plot", height = "280px"
        ) |> withSpinner())
      ),
      card(full_screen = TRUE,
        card_header(tags$span("🔔 Recent Events", class = "fw-bold")),
        card_body(
          div(style = "max-height: 300px; overflow-y: auto;",
            uiOutput("k8s_events_ui")
          )
        )
      )
    ),

    # Nodes / Pods / Deployments tabs
    layout_columns(col_widths = c(12),
      card(full_screen = TRUE,
        card_header(
          navset_tab(
            nav_panel("🖥 Nodes",
              div(class = "pt-3",
                DTOutput("k8s_nodes_table") |> withSpinner()
              )
            ),
            nav_panel("📦 Pods",
              div(class = "pt-3",
                div(class = "d-flex gap-2 mb-2",
                  div(style = "width: 160px;",
                    selectInput("k8s_pod_status_filter", NULL,
                      choices = c(
                        "All","Running","Pending","CrashLoopBackOff","Completed"
                      ),
                      width = "100%"
                    )
                  )
                ),
                DTOutput("k8s_pods_table") |> withSpinner())
            ),
            nav_panel("Deployments",
              div(class = "pt-3",
                DTOutput("k8s_deployments_table") |> withSpinner()
              )
            ),
            nav_panel("🗂 Namespaces",
              div(class = "pt-3",
                DTOutput("k8s_namespaces_table") |> withSpinner()
              )
            )
          )
        )
      )
    )
  )
}

# Multi-cloud overview page
multicloud_ui <- function() {
  div(class = "p-4",

    div(class = "mb-4",
      h2("🌐 Multi-Cloud Overview", class = "fw-bold"),
      p("Unified view of cost, usage, and health across all connected providers.",
        class = "text-muted")
    ),

    # Provider status strip
    uiOutput("multicloud_provider_strip"),

    # Aggregated cost comparison
    layout_columns(col_widths = c(7, 5),
      card(full_screen = TRUE,
        card_header(tags$span("💰 Cost by Provider", class = "fw-bold")),
        card_body(plotlyOutput("multicloud_cost_plot", height = "300px") |> withSpinner())
      ),
      card(full_screen = TRUE,
        card_header(tags$span("📊 Cost Breakdown", class = "fw-bold")),
        card_body(plotlyOutput("multicloud_cost_pie", height = "300px") |> withSpinner())
      )
    ),

    # Resource utilization
    layout_columns(col_widths = c(6, 6),
      card(full_screen = TRUE,
        card_header(tags$span("⚡ CPU Utilization by Provider", class = "fw-bold")),
        card_body(plotlyOutput("multicloud_cpu_plot", height = "260px") |> withSpinner())
      ),
      card(full_screen = TRUE,
        card_header(tags$span("☸ Kubernetes Clusters", class = "fw-bold")),
        card_body(uiOutput("multicloud_k8s_summary"))
      )
    ),

    # Combined resource table
    layout_columns(col_widths = c(12),
      card(full_screen = TRUE,
        card_header(tags$span("🗄 All Resources", class = "fw-bold")),
        card_body(DTOutput("multicloud_resources_table") |> withSpinner())
      )
    )
  )
}
developer_ui <- function() {
  div(
    class = "p-4",

    # Header
    div(class = "mb-4",
      h2("🛠 Developer Portal", class = "fw-bold"),
      p("Request test instances, manage schedules, 
      and configure environments for your organization.",
        class = "text-muted")
    ),

    # Request New Instance
    layout_columns(
      col_widths = c(6, 6),

      card(
        card_header(tags$span("Request Instances", class = "fw-bold")),
        card_body(
          div(class = "mb-3",
            tags$label("Organization / Team", class = "form-label fw-bold"),
            textInput("dev_org", NULL, placeholder = "e.g. Data Engineering", width = "100%")
          ),
          div(class = "mb-3",
            tags$label("Cloud Provider", class = "form-label fw-bold"),
            selectInput("dev_provider", NULL, choices = c("AWS","Azure","GCP"), width = "100%")
          ),
          div(class = "mb-3",
            tags$label("Instance Type", class = "form-label fw-bold"),
            selectInput("dev_instance_type", NULL,
              choices = c(
                "Small  (2 vCPU,  4GB RAM)"  = "small",
                "Medium (4 vCPU,  8GB RAM)"  = "medium",
                "Large  (8 vCPU, 16GB RAM)"  = "large",
                "XLarge (16 vCPU,32GB RAM)"  = "xlarge"
              ), width = "100%")
          ),
          div(class = "mb-3",
            tags$label("Region", class = "form-label fw-bold"),
            selectInput("dev_region", NULL,
              choices = c("us-east-1","us-west-2","eu-west-1","ap-southeast-1"),
              width = "100%")
          ),
          div(class = "mb-3",
            tags$label("Purpose / Notes", class = "form-label fw-bold"),
            textAreaInput("dev_notes", NULL,
              placeholder = "Describe the use case for this instance...",
              rows = 3, width = "100%")
          ),
          div(class = "mb-3",
            tags$label("Auto-shutdown after (hours)", class = "form-label fw-bold"),
            numericInput("dev_ttl", NULL, value = 8, min = 1, max = 168, width = "100%"),
            tags$small("Instance will be automatically stopped after this duration.", class = "text-muted")
          ),
          div(class = "d-grid",
            actionButton("dev_request_btn", "Submit Request",
              class = "btn btn-primary fw-bold", style = "border-radius: 8px;")
          )
        )
      ),

      # Active instances panel
      card(
        card_header(
          div(class = "d-flex justify-content-between align-items-center",
            tags$span("⚡ Active Test Instances", class = "fw-bold"),
            actionButton("dev_refresh_btn", icon("rotate"), class = "btn btn-sm btn-outline-secondary")
          )
        ),
        card_body(
          uiOutput("dev_instances_list")
        )
      )
    ),

    # Weekend / Scheduled Shutdown
    layout_columns(
      col_widths = c(12),
      card(
        card_header(tags$span("Automated Instance Shutdown", class = "fw-bold")),
        card_body(
          layout_columns(
            col_widths = c(4, 4, 4),

            div(
              h6("Weekend Shutdown", class = "fw-bold"),
              p("Automatically stop all non-critical instances on weekends to reduce costs.",
                class = "text-muted small"),
              div(class = "mb-2",
                checkboxInput("sched_weekend", "Enable weekend shutdown (Fri 6PM – Mon 8AM)", value = FALSE)
              ),
              conditionalPanel("input.sched_weekend == true",
                div(class = "alert alert-success p-2",
                  tags$small("✅ Weekend shutdown active. Estimated savings: ~28% monthly compute cost.")
                )
              )
            ),

            div(
              h6("Daily Off-Hours Shutdown", class = "fw-bold"),
              p("Stop instances outside business hours automatically.", class = "text-muted small"),
              div(class = "mb-2",
                checkboxInput("sched_offhours", "Enable off-hours shutdown (8PM – 7AM)", value = FALSE)
              ),
              conditionalPanel("input.sched_offhours == true",
                div(class = "mb-2",
                  tags$label("Business hours timezone", class = "form-label fw-bold small"),
                  selectInput("sched_tz", NULL,
                    choices = c("America/New_York","America/Chicago","America/Denver","America/Los_Angeles","UTC"),
                    width = "100%")
                )
              )
            ),

            div(
              h6("Custom Schedule", class = "fw-bold"),
              p("Set a specific shutdown time for selected instances.", class = "text-muted small"),
              div(class = "mb-2",
                tags$label("Shutdown date & time", class = "form-label fw-bold small"),
                textInput("sched_custom_dt", NULL,
                  placeholder = "YYYY-MM-DD HH:MM", width = "100%")
              ),
              div(class = "mb-2",
                tags$label("Target instances (comma-separated)", class = "form-label fw-bold small"),
                textInput("sched_targets", NULL,
                  placeholder = "instance-1, instance-2", width = "100%")
              ),
              div(class = "d-grid",
                actionButton("sched_apply_btn", "Apply Schedule",
                  class = "btn btn-outline-primary btn-sm fw-bold")
              )
            )
          ),

          hr(),

          # Schedule log
          div(
            h6("Schedule Activity Log", class = "fw-bold"),
            div(
              style = "max-height: 180px; overflow-y: auto; font-size: 0.85rem;",
              uiOutput("sched_log_ui")
            )
          )
        )
      )
    ),

    # Requests table
    layout_columns(
      col_widths = c(12),
      card(
        card_header(tags$span("📊 Request History", class = "fw-bold")),
        card_body(
          DTOutput("dev_requests_table") |> withSpinner()
        )
      )
    )
  )
}

# Dashboard UI with sidebar navigation and main content area that
# switches between analytics, multi-cloud overview, Kubernetes health,
# and developer portal pages.
dashboard_ui <- function() {
  page_sidebar(
    title = "FinOps Dashboard - CloudPulse",
    sidebar = sidebar(
      class = "bg-light",
      div(class = "d-flex align-items-center justify-content-between mb-4",
        div(
          h5("Dashboard", class = "fw-bold mb-0"),
          h6("Cloud Analytics", class = "text-muted")
        ),
        actionButton("logout_btn", icon("sign-out-alt"),
          class = "btn btn-sm btn-outline-secondary", title = "Logout")
      ),
      hr(),
      div(class = "mb-3",
        div(class = "d-grid gap-1",
          actionButton("nav_dashboard", "Analytics",
            class = "btn btn-sm btn-outline-primary", style = "border-radius: 6px; text-align:left;"),
          actionButton("nav_multicloud", "🌐 Multi-Cloud",
            class = "btn btn-sm btn-outline-primary", style = "border-radius: 6px; text-align:left;"),
          actionButton("nav_k8s", "☸  Kubernetes",
            class = "btn btn-sm btn-outline-primary", style = "border-radius: 6px; text-align:left;"),
          actionButton("nav_developer",  "🛠  Developer",
            class = "btn btn-sm btn-outline-primary", style = "border-radius: 6px; text-align:left;")
        )
      ),
      hr(),
      conditionalPanel("input.current_page_input === 'dashboard'",
        div(class = "mb-4",
          h6("Query Configuration",
            class = "fw-bold text-uppercase small text-muted"
          ),
          selectInput("provider","Cloud Provider", choices = c("AWS","Azure","GCP"), width = "100%"),
          selectInput("query_type","Query Type", choices = c("Metadata","Usage","Cost"), width = "100%"),
          checkboxInput("use_mock","Use mock data (local)", value = TRUE)
        ),
        conditionalPanel("input.query_type == 'Usage' || input.query_type == 'Cost'",
          div(class = "mb-4",
            h6("Time Period", class = "fw-bold text-uppercase small text-muted"),
            dateRangeInput("date_range", NULL,
              start = Sys.Date() - 30, end = Sys.Date(), width = "100%")
          )
        ),
        conditionalPanel("input.query_type == 'Usage'",
          div(class = "mb-4",
            h6("Instance", class = "fw-bold text-uppercase small text-muted"),
            selectInput("instance_usage", NULL, choices = NULL, width = "100%")
          )
        ),
        conditionalPanel("input.query_type == 'Cost'",
          div(class = "mb-4",
            h6("Instance", class = "fw-bold text-uppercase small text-muted"),
            selectInput("instance_cost", NULL, choices = NULL, width = "100%")
          )
        ),
        conditionalPanel("input.query_type == 'Metadata'",
          div(class = "mb-4",
            h6("Filter", class = "fw-bold text-uppercase small text-muted"),
            selectInput("instance_status","Instance Status",
              choices = c("All","Available","Stopped","Other"), width = "100%")
          )
        ),
        conditionalPanel("input.query_type == 'Usage'",
          div(class = "mb-4",
            h6("Forecast", class = "fw-bold text-uppercase small text-muted"),
            checkboxInput("enable_forecast","Enable forecast", value = FALSE),
            conditionalPanel("input.enable_forecast == true",
              numericInput("forecast_horizon","Horizon (days)", value=7, min=1, max=90, width="100%")
            )
          )
        ),
        div(class = "d-grid gap-2 mt-4",
          actionButton("query","🔍 Query Data", class = "btn btn-primary fw-bold",
            style = "padding: 0.75rem; border-radius: 8px;")
        )
      ),
      hr(),
      div(class = "d-flex align-items-center justify-content-between",
        tags$label("Dark Mode", class = "form-label mb-0"),
        input_dark_mode(id = "dark_mode")
      )
    ),

    # Main content — switches between analytics and developer page
    div(class = "p-4",
      uiOutput("page_content")
    )
  )
}

# Analytics content for the main dashboard page, including KPIs, data table, and visualizations.
analytics_ui <- function() {
  tagList(
    layout_columns(col_widths = c(12),
      card(
        class = "bg-gradient",
        style = "background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);",
        div(class = "text-white",
          h2("Cloud Analytics Dashboard", class = "fw-bold mb-2"),
          p("Real-time insights from your cloud infrastructure", class = "mb-0")
        )
      )
    ),
    layout_columns(col_widths = c(3,3,3,3),
      card(class = "text-center border-start border-5 border-primary p-3",
        h6("Provider", class = "text-muted small"),
        textOutput("kpi_provider", inline = TRUE) |> withSpinner()
      ),
      card(class = "text-center border-start border-5 border-success p-3",
        h6("Query Type", class = "text-muted small"),
        textOutput("kpi_query_type", inline = TRUE) |> withSpinner()
      ),
      card(class = "text-center border-start border-5 border-info p-3",
        h6("Records", class = "text-muted small"),
        textOutput("kpi_records", inline = TRUE) |> withSpinner()
      ),
      card(class = "text-center border-start border-5 border-warning p-3",
        h6("Last Query", class = "text-muted small"),
        textOutput("kpi_last_query", inline = TRUE) |> withSpinner()
      )
    ),
    layout_columns(col_widths = c(12),
      card(full_screen = TRUE,
        card_header("Query Results", class = "fw-bold"),
        DTOutput("cloud_table") |> withSpinner()
      )
    ),
    layout_columns(col_widths = c(12),
      card(full_screen = TRUE,
        card_header("Visualization", class = "fw-bold"),
        plotlyOutput("cloud_plot", height = "400px") |> withSpinner()
      )
    ),
    conditionalPanel(
      "input.enable_forecast == true && input.query_type == 'Usage'",
      layout_columns(col_widths = c(12),
        card(full_screen = TRUE,
          card_header("Forecast Projections", class = "fw-bold"),
          DTOutput("forecast_table") |> withSpinner()
        )
      )
    )
  )
}

# Main UI with navbar and dynamic content area.
# Also includes global JS listener for client message
# (e.g. notifications triggered from server). The navbar is hidden on the
# credentials page and shown on the dashboard. The main content switches
# between the analytics view and the developer portal based on navigation state.
ui <- function() {
  page_navbar(
    title = "CloudPulse FinOps",
    theme = modern_theme,
    nav_panel("App",
      tags$head(
        tags$style(app_css),
        tags$script(HTML("
          window.addEventListener('shiny:client-message', function(ev) {
            var detail = ev && ev.detail;
            if (!detail || typeof detail !== 'object') return;
            var headline = detail.headline, message = detail.message, status = detail.status;
            if (!message) return;
            if (typeof window.showShinyClientMessage === 'function') {
              window.showShinyClientMessage({ headline: headline, message: message, status: status });
            }
          });
        "))
      ),
      uiOutput("main_ui"),
      tags$head(tags$style("#current_page_input{display:none}")),
      textInput("current_page_input", NULL, value = "dashboard")
    )
  )
}

# Main server function handles authentication, navigation, and state management
server <- function(input, output, session) {

  user_authenticated     <- reactiveVal(FALSE)
  authenticated_provider <- reactiveVal(NULL)
  last_query_time        <- reactiveVal(NULL)
  current_page           <- reactiveVal("dashboard")

  # Security state
  login_attempts     <- reactiveVal(0L)
  last_attempt_time  <- reactiveVal(NULL)

  user_authenticated     <- reactiveVal(FALSE)
  connected_providers    <- reactiveVal(character(0))
  last_query_time        <- reactiveVal(NULL)
  current_page           <- reactiveVal("dashboard")
  login_attempts         <- reactiveVal(0L)
  last_attempt_time      <- reactiveVal(NULL)
  last_activity_time     <- reactiveVal(Sys.time())
  k8s_selected_cluster   <- reactiveVal(NULL)

  # Session timeout and auto-logout after inactivity
  session_timer <- reactiveTimer(60000)
  observe({
    session_timer()
    if (user_authenticated()) {
      idle <- as.numeric(difftime(
        Sys.time(), last_activity_time(),
        units = "secs"
      ))
      if (idle > session_timeout) {
        user_authenticated(FALSE)
        connected_providers(character(0))
        session$userData <- list()
        login_attempts(0L)
        showNotification("Session expired due to inactivity.",
          type = "warning", duration = 8
        )
      }
    }
  })

  observe({
    reactiveValuesToList(input)
    if (user_authenticated()) last_activity_time(Sys.time())
  })

  # K8s auto-refresh
  k8s_timer <- reactiveTimer(30000)
  k8s_refresh_trigger <- reactiveVal(0L)
  observe({
    k8s_timer()
    if (isTRUE(input$k8s_auto_refresh))
      isolate(k8s_refresh_trigger(isolate(k8s_refresh_trigger()) + 1L))
  })
  observeEvent(input$k8s_refresh, {
    k8s_refresh_trigger(k8s_refresh_trigger() + 1L)
  })

  # Instance requests / schedule log
  instance_requests <- reactiveVal(data.frame(
    ID=character(), Org=character(), Provider=character(), Type=character(),
    Region=character(), TTL_hrs=numeric(), Status=character(),
    Requested=character(), Notes=character(), stringsAsFactors=FALSE
  ))
  sched_log <- reactiveVal(character(0))

  # Nav
  observeEvent(input$nav_dashboard, {
    current_page("dashboard")
    updateTextInput(session, "current_page_input", value = "dashboard")
  })
  observeEvent(input$nav_multicloud, {
    current_page("multicloud")
    updateTextInput(session, "current_page_input", value = "multicloud")
  })
  observeEvent(input$nav_k8s, {
    current_page("k8s")
    updateTextInput(session, "current_page_input", value = "k8s")
  })
  observeEvent(input$nav_developer, {
    current_page("developer")
    updateTextInput(session, "current_page_input", value = "developer")
  })

  # Main UI switches between credentials page and dashboard
  output$main_ui <- renderUI({
    if (user_authenticated()) dashboard_ui() else credentials_ui()
  })

  output$page_content <- renderUI({
    switch(current_page(),
      "multicloud" = multicloud_ui(),
      "k8s"        = k8s_ui(),
      "developer"  = developer_ui(),
      analytics_ui()
    )
  })

  # Login handler with rate limiting and mock mode support
  observeEvent(input$login_btn, {
    rl <- check_rate_limit(login_attempts(), last_attempt_time())
    if (rl$reset) { login_attempts(0L); last_attempt_time(NULL) }
    if (rl$locked) {
      remaining <- ceiling(remaining_lockout(last_attempt_time()))
      showNotification(paste0("Too many failed attempts. 
      Try again in ", remaining, "s."),
        type = "error", duration = 8
      )
      return()
    }

    # Mock mode
    if (isTRUE(input$use_mock_all)) {
      session$userData$use_mock <- TRUE
      session$userData$mock_providers <- c("AWS", "Azure", "GCP")
      connected_providers(c("AWS", "Azure", "GCP"))
      login_attempts(0L); last_attempt_time(NULL)
      last_activity_time(Sys.time())
      user_authenticated(TRUE)
      showNotification("Connected with mock data for AWS, 
      Azure, and GCP.", type = "message", duration = 4)
      return()
    }

    providers_connected <- character(0)
    errors              <- character(0)
    session$userData$use_mock <- FALSE

    # AWS
    if (isTRUE(input$connect_aws)) {
      key    <- sanitize_aws_key(input$aws_access_key)
      secret <- sanitize_text(input$aws_secret_key, max_len = 128L)
      region <- sanitize_aws_region(input$aws_region)
      if (!nzchar(key)) errors <- c(errors, "AWS: invalid access key format.")
      else if (!nzchar(secret)) errors <- c(errors, "AWS: secret key required.")
      else {
        session$userData$aws_creds <- list(
          access_key = key,
          secret_key = secret,
          region = region,
          k8s_enabled = isTRUE(input$aws_k8s_enabled)
        )
        providers_connected <- c(providers_connected, "AWS")
      }
    }

    # Azure
    if (isTRUE(input$connect_azure)) {
      sub_id    <- sanitize_uuid(input$azure_subscription)
      tenant_id <- sanitize_uuid(input$azure_tenant)
      client_id <- sanitize_uuid(input$azure_client_id)
      secret    <- sanitize_text(input$azure_client_secret, max_len = 128L)
      if (!nzchar(sub_id))    errors <- c(errors, "Azure: invalid subscription ID.")
      else if (!nzchar(tenant_id)) errors <- c(errors, "Azure: invalid tenant ID.")
      else if (!nzchar(client_id)) errors <- c(errors, "Azure: invalid client ID.")
      else if (!nzchar(secret))    errors <- c(errors, "Azure: client secret required.")
      else {
        session$userData$azure_creds <- list(
          subscription = sub_id, tenant = tenant_id,
          client_id = client_id, client_secret = secret,
          k8s_enabled = isTRUE(input$azure_k8s_enabled))
        providers_connected <- c(providers_connected, "Azure")
      }
    }

    # GCP
    if (isTRUE(input$connect_gcp)) {
      project_id  <- sanitize_gcp_project(input$gcp_project_id)
      svc_account <- sanitize_gcp_json(input$gcp_service_account)
      if (!nzchar(project_id))  errors <- c(errors, "GCP: invalid project ID.")
      else if (!nzchar(svc_account)) errors <- c(errors, "GCP: invalid service account JSON.")
      else {
        session$userData$gcp_creds <- list(
          project_id = project_id, service_account = svc_account,
          k8s_enabled = isTRUE(input$gcp_k8s_enabled))
        providers_connected <- c(providers_connected, "GCP")
      }
    }

    if (length(errors) > 0) {
      login_attempts(login_attempts() + 1L)
      last_attempt_time(Sys.time())
      showNotification(paste(errors, collapse = " "), type = "warning", duration = 8)
    }
    if (length(providers_connected) == 0 && length(errors) == 0) {
      showNotification("Please connect at least one provider or enable mock data.",
        type = "warning", duration = 5)
      return()
    }
    if (length(providers_connected) > 0) {
      connected_providers(providers_connected)
      login_attempts(0L); last_attempt_time(NULL); last_activity_time(Sys.time())
      user_authenticated(TRUE)
      showNotification(
        paste0("Connected: ", paste(providers_connected, collapse = ", ")),
        type = "message", duration = 4)
    }

    attempts_now <- login_attempts()
    if (attempts_now > 0 && attempts_now < max_login_attempts) {
      showNotification(paste0("Warning: ", max_login_attempts - attempts_now,
        " attempt(s) remaining before lockout."), type = "warning", duration = 5)
    }
  })

  # Logout
  observeEvent(input$logout_btn, {
    user_authenticated(FALSE)
    connected_providers(character(0))
    current_page("dashboard")
    session$userData <- list()
    showNotification("Logged out.", type = "default", duration = 3)
  })

  # MULTI-CLOUD OUTPUTS
  # Provider status strip
  output$multicloud_provider_strip <- renderUI({
    providers <- connected_providers()
    use_mock  <- isTRUE(session$userData$use_mock)
    all_providers <- c("AWS","Azure","GCP")
    div(class = "mb-4",
      layout_columns(col_widths = rep(4L, 3L),
        lapply(all_providers, function(p) {
          connected <- p %in% providers
          color     <- if (connected) "#d1fae5" else "#f1f5f9"
          text_col  <- if (connected) "#065f46" else "#94a3b8"
          icon_sym  <- switch(p, AWS="☁", Azure="🔷", GCP="🟡", "?")
          card(
            style = paste0("background:", color, "; border: 2px solid ",
                           if (connected) "#10b981" else "#e2e8f0", ";"),
            card_body(
              div(class = "d-flex align-items-center justify-content-between",
                div(
                  tags$span(icon_sym, style = "font-size: 1.4em;"),
                  tags$span(p, class = "fw-bold ms-2",
                    style = paste0("color:", text_col)
                  )
                ),
                tags$span(
                  if (connected) "● Connected" else "○ Not connected",
                  style = paste0("font-size: 0.8em; color:", text_col)
                )
              )
            )
          )
        })
      )
    )
  })

  # Aggregated cost data across all providers
  multicloud_cost_data <- reactive({
    use_mock  <- isTRUE(session$userData$use_mock)
    providers <- connected_providers()
    if (length(providers) == 0) return(data.frame())
    do.call(rbind, lapply(providers, function(p) {
      tryCatch({
        df <- if (use_mock) {
          get_mock_cost(format(
            Sys.Date()-30, "%Y-%m-%d"
          ),
          format(Sys.Date(), "%Y-%m-%d"))
        } else {
          s <- format(
            Sys.Date()-30, "%Y-%m-%d"
          )
          e <- format(Sys.Date(), "%Y-%m-%d")
          if (p == "AWS")   aws_rds_cost_by_instance(s, e)
          else if (p == "Azure") azure_db_cost_by_instance(s, e)
          else if (p == "GCP")  gcp_db_cost_by_instance(s, e)
        }
        if (nrow(df) > 0) df$provider <- p
        df
      }, error = function(e) data.frame())
    }))
  })

  output$multicloud_cost_plot <- renderPlotly({
    df <- multicloud_cost_data()
    if (is.null(df) || nrow(df) == 0)
      return(plot_ly() |> add_annotations(text="No cost data", showarrow=FALSE))
    agg <- aggregate(cost ~ provider, data = df, FUN = sum, na.rm = TRUE)
    colors <- c(AWS = "#FF9900", Azure = "#0089D6", GCP = "#4285F4")
    plot_ly(agg, x = ~provider, y = ~cost, type = "bar",
            marker = list(color = unname(colors[agg$provider])),
            text = ~paste0("$", round(cost, 2)), textposition = "outside") |>
      layout(title = "", xaxis = list(title = ""),
             yaxis = list(title = "USD"),
             plot_bgcolor = "rgba(0,0,0,0)", paper_bgcolor = "rgba(0,0,0,0)")
  })

  output$multicloud_cost_pie <- renderPlotly({
    df <- multicloud_cost_data()
    if (is.null(df) || nrow(df) == 0)
      return(plot_ly() |> add_annotations(text="No data", showarrow=FALSE))
    agg    <- aggregate(cost ~ provider, data = df, FUN = sum, na.rm = TRUE)
    colors <- c("#FF9900","#0089D6","#4285F4","#34a853")
    plot_ly(agg, labels = ~provider, values = ~cost, type = "pie",
            marker = list(colors = colors),
            textinfo = "label+percent") |>
      layout(showlegend = TRUE,
             plot_bgcolor = "rgba(0,0,0,0)", paper_bgcolor = "rgba(0,0,0,0)")
  })

  output$multicloud_cpu_plot <- renderPlotly({
    providers <- connected_providers()
    use_mock  <- isTRUE(session$userData$use_mock)
    if (length(providers) == 0)
      return(plot_ly() |> add_annotations(text="No providers connected", showarrow=FALSE))
    p_obj <- plot_ly()
    colors <- c(AWS = "#FF9900", Azure = "#0089D6", GCP = "#4285F4")
    for (prov in providers) {
      tryCatch({
        df <- if (use_mock) get_mock_usage(prov, "") else {
          inst <- switch(prov,
            AWS   = tryCatch(aws_rds_instances_metadata()$identifier[[1]], error=function(e)""),
            Azure = tryCatch(azure_db_instances_metadata()$name[[1]], error=function(e)""),
            GCP   = tryCatch(gcp_db_instances_metadata()$name[[1]], error=function(e)"")
          )
          if (prov=="AWS")   aws_rds_instance_usage(inst)
          else if (prov=="Azure") azure_db_instance_usage(inst)
          else                    gcp_db_instance_usage(inst)
        }
        if (nrow(df) > 0)
          p_obj <- p_obj |> add_trace(x=df$timestamp, y=df$cpu_avg, type="scatter",
            mode="lines", name=prov, line=list(color=colors[[prov]], width=2))
      }, error=function(e) NULL)
    }
    p_obj |> layout(hovermode="x unified", xaxis=list(title=""),
                    yaxis=list(title="CPU %"),
                    plot_bgcolor="rgba(0,0,0,0)", paper_bgcolor="rgba(0,0,0,0)")
  })

  output$multicloud_k8s_summary <- renderUI({
    clusters <- get_mock_k8s_clusters()
    if (length(clusters) == 0)
      return(div(class="text-muted text-center py-3", "No clusters connected."))
    tagList(lapply(clusters, function(cl) {
      color <- switch(
        cl$status, Healthy="#d1fae5", Warning="#fef3c7",
        Error="#fee2e2", "#f1f5f9"
      )
      text  <- switch(
        cl$status, Healthy="#065f46", Warning="#92400e",
        Error="#991b1b", "#64748b"
      )
      div(class="d-flex justify-content-between align-items-center mb-2 p-2 rounded",
        style = paste0("background:", color),
        div(
          tags$strong(cl$name, style=paste0("font-size:0.85em; color:", text)),
          tags$br(),
          tags$small(paste0(
            cl$provider, " · ", cl$region, " · ", cl$nodes, " nodes"
          ),
          style = "color:#64748b")
        ),
        tags$span(cl$status,
          style = paste0("font-size:0.75em; font-weight:600; color:", text)
        )
      )
    }))
  })

  output$multicloud_resources_table <- renderDT({
    providers <- connected_providers()
    use_mock  <- isTRUE(session$userData$use_mock)
    if (length(providers) == 0)
      return(datatable(
        data.frame(Message="No providers connected"),
        options=list(dom="t")
      ))
    rows <- do.call(rbind, lapply(providers, function(p) {
      tryCatch({
        df <- if (use_mock) get_mock_metadata(p) else {
          if (p == "AWS")   aws_rds_instances_metadata()
          else if (p == "Azure") azure_db_instances_metadata()
          else                 gcp_db_instances_metadata()
        }
        if (nrow(df) > 0) df$Provider <- p
        df
      }, error=function(e) data.frame())
    }))
    if (is.null(rows) || nrow(rows) == 0)
      return(datatable(
        data.frame(Message = "No data"),
        options = list(dom = "t")
      ))
    datatable(
      rows, options=list(scrollX = TRUE, pageLength = 10, searching = TRUE),
      rownames = FALSE
    )
  })

  # KUBERNETES OUTPUTS
  k8s_clusters <- reactive({
    get_mock_k8s_clusters()
    # real: query EKS/AKS/GKE APIs based on connected providers
  })

  output$k8s_cluster_select_ui <- renderUI({
    clusters <- k8s_clusters()
    choices  <- setNames(
      sapply(clusters, function(c) c$name),
      sapply(clusters, function(c) paste0(c$name, " (", c$provider, ")"))
    )
    selectInput("k8s_cluster", NULL, choices = choices, width = "100%")
  })

  # Reactive cluster data — re-runs on refresh trigger
  k8s_nodes_data <- reactive({
    k8s_refresh_trigger()
    req(input$k8s_cluster)
    tryCatch(get_mock_k8s_nodes(input$k8s_cluster),
      error = function(e) data.frame(Error = .safe_k8s_error(e))
    )
  })

  k8s_pods_data <- reactive({
    k8s_refresh_trigger()
    req(input$k8s_cluster)
    tryCatch(get_mock_k8s_pods(input$k8s_cluster, input$k8s_namespace %||% ""),
      error = function(e) data.frame(Error = .safe_k8s_error(e))
    )
  })

  k8s_deployments_data <- reactive({
    k8s_refresh_trigger()
    req(input$k8s_cluster)
    tryCatch(get_mock_k8s_deployments(input$k8s_cluster),
      error = function(e) data.frame(Error = .safe_k8s_error(e))
    )
  })

  k8s_events_data <- reactive({
    k8s_refresh_trigger()
    req(input$k8s_cluster)
    tryCatch(get_mock_k8s_events(input$k8s_cluster),
      error = function(e) data.frame(Error = .safe_k8s_error(e))
    )
  })

  k8s_metrics_data <- reactive({
    k8s_refresh_trigger()
    req(input$k8s_cluster)
    tryCatch(get_mock_k8s_metrics(input$k8s_cluster),
      error = function(e) data.frame()
    )
  })

  # KPI cards
  output$k8s_kpi_cards <- renderUI({
    nodes   <- k8s_nodes_data()
    pods    <- k8s_pods_data()
    deploys <- k8s_deployments_data()
    clusters <- k8s_clusters()
    selected <- input$k8s_cluster

    n_nodes <- if ("Error" %in% colnames(nodes)) "?" else nrow(nodes)
    n_ready <- if ("Error" %in% colnames(nodes)) "?"
    else sum(nodes$status == "Ready")
    n_pods <- if ("Error" %in% colnames(pods))  "?" else nrow(pods)
    n_running <- if ("Error" %in% colnames(pods)) "?"
    else sum(pods$status == "Running")
    n_warn <- if ("Error" %in% colnames(pods))  "?"
    else sum(pods$status == "CrashLoopBackOff")

    cl_info <- Filter(function(c) c$name == selected, clusters)
    version <- if (length(cl_info) > 0) cl_info[[1]]$version else "?"
    layout_columns(col_widths = c(3,3,3,3),
      card(class = "text-center border-start border-5 border-primary p-3",
        h6("Nodes Ready", class = "text-muted small"),
        h3(paste0(n_ready, " / ", n_nodes), class = "fw-bold mb-0")
      ),
      card(class = "text-center border-start border-5 border-success p-3",
        h6("Pods Running", class = "text-muted small"),
        h3(paste0(n_running, " / ", n_pods), class = "fw-bold mb-0")
      ),
      card(class = paste0("text-center border-start border-5 p-3 ",
                          if (is.numeric(n_warn) && n_warn > 0)
                            "border-danger" else "border-info"),
        h6("CrashLoop Pods", class = "text-muted small"),
        h3(n_warn, class = paste0("fw-bold mb-0 ",
                                  if (is.numeric(n_warn) && n_warn > 0)
                                    "text-danger" else ""))
      ),
      card(class = "text-center border-start border-5 border-warning p-3",
        h6("K8s Version", class = "text-muted small"),
        h3(version, class = "fw-bold mb-0")
      )
    )
  })

  # Metrics plot
  output$k8s_metrics_plot <- renderPlotly({
    df <- k8s_metrics_data()
    if (is.null(df) || nrow(df) == 0)
      return(plot_ly() |> add_annotations(text="No metrics", showarrow=FALSE))
    plot_ly(df, x = ~timestamp) |>
      add_trace(y = ~cpu_pct, type = "scatter", mode = "lines",
                name = "CPU %", line = list(color="#667eea", width=2)) |>
      add_trace(y = ~mem_pct, type = "scatter", mode = "lines",
                name = "Memory %", line = list(color="#38BDF8", width=2)) |>
      layout(hovermode = "x unified", xaxis = list(title=""),
             yaxis = list(title = "%", range = c(0, 100)),
             legend = list(orientation = "h"),
             plot_bgcolor = "rgba(0,0,0,0)", paper_bgcolor = "rgba(0,0,0,0)")
  })

  # Events list
  output$k8s_events_ui <- renderUI({
    df <- k8s_events_data()
    if (is.null(df) || nrow(df) == 0)
      return(p("No recent events.", class = "text-muted"))
    if ("Error" %in% colnames(df))
      return(div(class="alert alert-danger", df$Error[[1]]))
    tagList(lapply(seq_len(min(nrow(df), 15L)), function(i) {
      row    <- df[i, ]
      is_warn <- row$type == "Warning"
      bg     <- if (is_warn) "#fee2e2" else "#f0fdf4"
      icon_s <- if (is_warn) "⚠️" else "✅"
      div(class = "mb-2 p-2 rounded",
        style = paste0("background:", bg, "; font-size:0.82em;"),
        div(class = "d-flex justify-content-between",
          tags$strong(paste(icon_s, row$reason)),
          tags$small(row$age, class = "text-muted")
        ),
        div(row$object, class = "text-muted", style = "font-size:0.9em;"),
        div(row$message)
      )
    }))
  })

  # Nodes table
  output$k8s_nodes_table <- renderDT({
    df <- k8s_nodes_data()
    if ("Error" %in% colnames(df))
      return(datatable(df, options = list(dom="t")))
    df$status <- ifelse(df$status == "Ready",
      '<span class="badge bg-success">Ready</span>',
      '<span class="badge bg-danger">NotReady</span>'
    )
    df$cpu_pct <- paste0(df$cpu_pct, "%")
    df$mem_pct <- paste0(df$mem_pct, "%")
    datatable(df, escape = FALSE, rownames = FALSE,
      options = list(scrollX = TRUE, pageLength = 10, searching = FALSE)
    )
  })

  # Pods table with filter
  output$k8s_pods_table <- renderDT({
    df <- k8s_pods_data()
    if ("Error" %in% colnames(df))
      return(datatable(df, options=list(dom="t")))
    filter_val <- input$k8s_pod_status_filter
    if (!is.null(filter_val) && filter_val != "All")
      df <- df[df$status == filter_val, ]
    df$status <- sapply(df$status, function(s) {
      cls <- switch(s,
        Running           = "bg-success",
        Completed         = "bg-info",
        Pending           = "bg-warning text-dark",
        CrashLoopBackOff  = "bg-danger",
        "bg-secondary"
      )
      paste0('<span class="badge ', cls, '">', s, "</span>")
    })
    datatable(df, escape = FALSE, rownames = FALSE,
      options = list(scrollX = TRUE, pageLength = 15, searching = TRUE)
    )
  })

  # Deployments table
  output$k8s_deployments_table <- renderDT({
    df <- k8s_deployments_data()
    if ("Error" %in% colnames(df))
      return(datatable(df, options = list(dom = "t")))
    datatable(df, rownames = FALSE,
      options = list(scrollX = TRUE, pageLength = 10, searching = TRUE)
    )
  })

  # Namespaces table
  output$k8s_namespaces_table <- renderDT({
    req(input$k8s_cluster)
    df <- tryCatch(
      get_mock_k8s_namespaces(input$k8s_cluster),
      error=function(e) data.frame()
    )
    if (nrow(df) == 0) return(datatable(data.frame(Message="No namespaces")))
    df$status <- sapply(df$status, function(s) {
      cls <- if (s == "Active") "bg-success" else "bg-secondary"
      paste0('<span class="badge ', cls, '">', s, '</span>')
    })
    datatable(df, escape=FALSE, rownames=FALSE,
      options=list(searching=FALSE, pageLength=15)
    )
  })

  instances <- reactive({
    if (!user_authenticated()) return(character(0))
    use_mock <- isTRUE(session$userData$use_mock)
    tryCatch({
      if (use_mock) get_mock_instances(input$provider)
      else
        if (input$provider == "AWS")   aws_rds_instances_metadata()$identifier
        else if (input$provider == "Azure") azure_db_instances_metadata()$name
        else if (input$provider == "GCP")   gcp_db_instances_metadata()$name
    }, error = function(e) character(0))
  })

  observe({
    updateSelectInput(session, "instance_usage", choices = instances())
    updateSelectInput(session, "instance_cost",  choices = instances())
    # Update provider selector to only show connected providers
    providers <- connected_providers()
    if (length(providers) > 0)
      updateSelectInput(session, "provider", choices = providers)
  })

  query_count      <- reactiveVal(0L)
  last_query_burst <- reactiveVal(NULL)

  cloud_data <- eventReactive(input$query, {
    if (!user_authenticated()) return(data.frame(Error = "Not authenticated"))
    now <- Sys.time()
    if (!is.null(last_query_burst())) {
      elapsed <- as.numeric(difftime(now, last_query_burst(), units = "secs"))
      if (elapsed < 60 && query_count() >= 20L) {
        showNotification("Query rate limit reached.",
          type = "warning", duration = 5
        )
        return(data.frame(Error = "Rate limit exceeded"))
      } else if (elapsed >= 60) {
        query_count(0L)
      }
    }
    query_count(query_count() + 1L)
    last_query_burst(now)
    last_activity_time(Sys.time())

    use_mock <- isTRUE(session$userData$use_mock) || isTRUE(input$use_mock)
    result <- tryCatch({
      if (use_mock) {
        if (input$query_type == "Metadata")
          get_mock_metadata(input$provider)
        else if (input$query_type == "Usage")
          get_mock_usage(input$provider, input$instance_usage)
        else get_mock_cost(
          format(input$date_range[1], "%Y-%m-%d"),
          format(input$date_range[2], "%Y-%m-%d")
        )
      } else {
        if (input$query_type == "Metadata") {
          if (input$provider == "AWS")   aws_rds_instances_metadata()
          else if (input$provider == "Azure") azure_db_instances_metadata()
          else gcp_db_instances_metadata()
        } else if (input$query_type == "Usage") {
          if (input$provider == "AWS")
            aws_rds_instance_usage(input$instance_usage)
          else if (input$provider == "Azure")
            azure_db_instance_usage(input$instance_usage)
          else  gcp_db_instance_usage(input$instance_usage)
        } else {
          s <- format(input$date_range[1], "%Y-%m-%d")
          e <- format(input$date_range[2], "%Y-%m-%d")
          if (input$provider == "AWS")   aws_rds_cost_by_instance(s, e)
          else if (input$provider == "Azure") azure_db_cost_by_instance(s, e)
          else                              gcp_db_cost_by_instance(s, e)
        }
      }
    }, error = function(e) data.frame(Error = safe_error(e)))
    last_query_time(Sys.time())
    result
  })

  output$kpi_provider   <- renderText(input$provider)
  output$kpi_query_type <- renderText(input$query_type)
  output$kpi_records    <- renderText({ nrow(cloud_data()) })
  output$kpi_last_query <- renderText({
    if (is.null(last_query_time()))
      "Never" else format(last_query_time(), "%H:%M:%S")
  })

  output$cloud_table <- renderDT({
    data <- cloud_data()
    if ("Error" %in% colnames(data)) return(datatable(data, options=list(dom="t")))
    datatable(data, options=list(autoWidth=FALSE, scrollX=TRUE, pageLength=10,
      lengthMenu=c(5,10,25,50), searching=TRUE, ordering=TRUE), filter="top")
  })

  output$cloud_plot <- renderPlotly({
    data <- cloud_data()
    if ("Error" %in% colnames(data))
      return(plot_ly() |> add_annotations(text="No data available", showarrow=FALSE))
    if (input$query_type=="Usage" && nrow(data)>0 && "timestamp" %in% colnames(data)) {
      p <- plot_ly(data, x=~timestamp, y=~cpu_avg, type="scatter", mode="lines",
                   name="Avg CPU", line=list(color="#667eea",width=2)) |>
        add_trace(y=~cpu_max, name="Max CPU", line=list(color="#764ba2",width=2))
      if (isTRUE(input$enable_forecast)) {
        fc_res <- tryCatch(train_forecast_usage(data, periods=as.integer(input$forecast_horizon)),
          error=function(e) list(forecast=data.frame()))
        if (!is.null(fc_res$forecast) && nrow(fc_res$forecast)>0) {
          fc_df <- fc_res$forecast |> transform(timestamp=as.POSIXct(date)+12*3600)
          p <- p |>
            add_lines(x=fc_df$timestamp, y=fc_df$yhat, name="Forecast",
              line=list(dash="dash",color="#FFC107",width=2)) |>
            add_ribbons(x=fc_df$timestamp, ymin=fc_df$lower80, ymax=fc_df$upper80,
              name="80% CI", fillcolor="rgba(255,193,7,0.2)",
              line=list(color="transparent"), showlegend=FALSE)
        }
      }
      p |> layout(hovermode="x unified",
                   plot_bgcolor="rgba(0,0,0,0)", paper_bgcolor="rgba(0,0,0,0)")
    } else if (input$query_type=="Cost" && nrow(data)>0 && "cost" %in% colnames(data)) {
      plot_ly(data, x=~start, y=~cost, type="bar", name="Cost",
              marker=list(color="#198754")) |>
        layout(hovermode="x unified",
               plot_bgcolor="rgba(0,0,0,0)", paper_bgcolor="rgba(0,0,0,0)")
    } else {
      plot_ly() |> add_annotations(text="No visualization available for this query.",
        showarrow=FALSE, font=list(color="#6c757d", size=14)) |>
        layout(xaxis=list(visible=FALSE), yaxis=list(visible=FALSE),
               plot_bgcolor="rgba(0,0,0,0)", paper_bgcolor="rgba(0,0,0,0)")
    }
  })

  output$forecast_table <- renderDT({
    if (isTRUE(input$enable_forecast) && input$query_type=="Usage") {
      data <- cloud_data()
      if (nrow(data)>0 && "Error" %notin% colnames(data)) {
        fc_res <- tryCatch(
          train_forecast_usage(data,
            periods=as.integer(input$forecast_horizon)
          ),
          error=function(e) NULL
        )
        if (!is.null(fc_res) && nrow(fc_res$forecast)>0)
          return(datatable(
            fc_res$forecast,
            options=list(autoWidth=FALSE,scrollX=TRUE,pageLength=10)
          ))
      }
      return(datatable(data.frame(Note="No forecast available")))
    }
    datatable(data.frame(
      Note="Enable forecast in the sidebar to view predictions"
    ))
  })

  # ══════════════════════════════════════════════════════════════════════════
  # DEVELOPER PAGE OUTPUTS
  # ══════════════════════════════════════════════════════════════════════════

  observeEvent(input$dev_request_btn, {
    org      <- sanitize_text(input$dev_org,   max_len=100L)
    notes    <- sanitize_text(input$dev_notes, max_len=max_note_chars)
    ttl      <- sanitize_numeric(input$dev_ttl, 1, 168, 8)
    if (!nzchar(org)) {
      showNotification("Organization name required.", type="warning", duration=4)
      return()
    }
    new_id  <- paste0(input$dev_provider, "-", format(Sys.time(), "%H%M%S"))
    new_row <- data.frame(ID=new_id, Org=org, Provider=input$dev_provider,
      Type=input$dev_instance_type, Region=input$dev_region, TTL_hrs=ttl,
      Status="Pending", Requested=format(Sys.time(),"%Y-%m-%d %H:%M"),
      Notes=notes, stringsAsFactors=FALSE)
    instance_requests(rbind(instance_requests(), new_row))
    showNotification(paste0("Request submitted: ", new_id), type="message", duration=4)
  })

  output$dev_instances_list <- renderUI({
    reqs <- instance_requests()
    if (nrow(reqs)==0)
      return(div(class="text-muted text-center py-4", "No active instances."))
    active <- reqs[reqs$Status %in% c("Pending","Running"),]
    if (nrow(active)==0) return(div(class="text-muted text-center py-4", "No active instances."))
    lapply(seq_len(nrow(active)), function(i) {
      row <- active[i,]
      sc  <- if (row$Status=="Running") "status-running" else "status-pending"
      div(class="card instance-card mb-2 p-3",
        div(class="d-flex justify-content-between align-items-start",
          div(tags$strong(row$ID), tags$br(),
            tags$small(paste(row$Org,"·",row$Provider,"·",row$Type), class="text-muted")),
          div(tags$span(row$Status, class=paste("status-badge",sc)), tags$br(),
            tags$small(paste("TTL:",row$TTL_hrs,"hrs"), class="text-muted"))
        ),
        if (nzchar(row$Notes)) tags$small(row$Notes, class="text-muted d-block mt-1"),
        div(class="mt-2",
          actionButton(paste0("stop_",i),"Stop",class="btn btn-sm btn-outline-danger me-1"),
          actionButton(paste0("extend_",i),"+2h",class="btn btn-sm btn-outline-secondary"))
      )
    })
  })

  output$dev_requests_table <- renderDT({
    reqs <- instance_requests()
    if (nrow(reqs)==0) return(datatable(data.frame(Message="No requests yet"),options=list(dom="t")))
    datatable(reqs, options=list(pageLength=10,scrollX=TRUE,searching=TRUE), rownames=FALSE)
  })

  observeEvent(input$sched_apply_btn, {
    dt      <- sanitize_datetime(input$sched_custom_dt)
    targets <- sanitize_instance_list(input$sched_targets)
    if (!nzchar(dt)) {
      showNotification("Invalid date/time. Use YYYY-MM-DD HH:MM (future).",
        type="warning", duration=5); return()
    }
    if (!nzchar(targets)) {
      showNotification("No valid instance identifiers.",
        type="warning", duration=5); return()
    }
    sched_log(c(sched_log(), paste0("[",format(Sys.time(),"%H:%M:%S"),
      "] Custom shutdown at ", dt, " for: ", targets)))
    showNotification("Schedule applied.", type="message", duration=3)
  })

  observeEvent(input$sched_weekend, {
    sched_log(c(sched_log(), paste0("[",format(Sys.time(),"%H:%M:%S"),
      "] Weekend shutdown ", if(input$sched_weekend) "ENABLED" else "DISABLED")))
  })

  observeEvent(input$sched_offhours, {
    tz <- if (isTRUE(input$sched_offhours) && !is.null(input$sched_tz)) input$sched_tz else ""
    sched_log(c(sched_log(), paste0("[",format(Sys.time(),"%H:%M:%S"),
      "] Off-hours shutdown ", if(input$sched_offhours) "ENABLED" else "DISABLED",
      if(nzchar(tz)) paste0(" (",tz,")") else "")))
  })

  output$sched_log_ui <- renderUI({
    logs <- sched_log()
    if (length(logs)==0) return(p("No schedule activity yet.", class="text-muted"))
    tagList(lapply(rev(logs), function(entry)
      tags$div(entry, style="font-family:monospace; padding:2px 0; border-bottom:1px solid rgba(0,0,0,0.05);")))
  })
}

shinyApp(ui, server)