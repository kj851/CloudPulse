# CloudPulse FinOps Dashboard - Main Shiny App
# This app provides an interface for querying and visualizing
# cloud cost and usage data across multiple CSPs AWS, Azure, and GCP.
# It includes a credential entry page, dynamic query configuration,
# and interactive visualizations with forecasting capabilities.
# Sercure credential handling and error management are implemented.
# Author: Keaton Szantho

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

if (!requireNamespace("shinycssloaders", quietly = TRUE)) {
  spinner <- function(expr, ...) expr
}

# ══════════════════════════════════════════════════════════════════════════════
# SECURITY MODULE
# ══════════════════════════════════════════════════════════════════════════════

# Constants and configuration for security and input validation
max_login_attempts  <- 5L        # lock out after this many failures
lockout_seconds     <- 300L      # 5-minute lockout window
session_timeout_s   <- 3600L     # auto-logout after 1 hour of inactivity
max_input_length    <- 500L      # max chars for free-text fields
max_notes_length    <- 1000L     # max chars for notes/textarea fields

# Input sanitization functions to prevent
# injection attacks and ensure data integrity
sanitize_text <- function(x, max_len = max_input_length) {
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
  if (!grepl("^(AKIA|ASIA|AROA|AGPA|AIDA|AIPA
  |ANPA|ANVA|APKA)[A-Z0-9]{16}$", x, perl = TRUE)) return("")
  x
}

sanitize_aws_region <- function(x) {
  x <- trimws(x %||% "")
  valid_regions <- c(
    "us-east-1", "us-east-2", "us-west-1", "us-west-2",
    "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1", "eu-north-1",
    "ap-southeast-1","ap-southeast-2","ap-northeast-1","ap-northeast-2",
    "ap-south-1","sa-east-1","ca-central-1","me-south-1","af-south-1",
    "us-gov-west-1","us-gov-east-1","cn-north-1","cn-northwest-1",
    "af-south-1","ap-east-1","ap-southeast-3","eu-south-1"
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
  dt <- tryCatch(as.POSIXct(x, format = "%Y-
  %m-%d %H:%M"), error = function(e) NA)
  if (is.na(dt)) return("")
  if (dt <= Sys.time()) return("")  # must be in the future
  x
}

sanitize_instance_list <- function(x) {
  x <- trimws(x %||% "")
  # Comma-separated alphanumeric + hyphen identifiers only
  parts <- trimws(strsplit(x, ",")[[1]])
  parts <- parts[grepl("^[a-zA-Z0-9][a-zA-Z0-9\\-_]
  {0,62}$", parts, perl = TRUE)]
  paste(parts, collapse = ", ")
}

sanitize_numeric <- function(x, min_val, max_val, default_val) {
  x <- suppressWarnings(as.numeric(x))
  if (is.na(x) || x < min_val || x > max_val) return(default_val)
  floor(x)
}

`%||%` <- function(a, b) if (!is.null(a)) a else b
# Per-session login attempt tracking
check_rate_limit <- function(attempts, last_attempt_time) {
  now <- Sys.time()
  # Reset counter if lockout window has passed
  if (!is.null(last_attempt_time) &&
      as.numeric(difftime(now, last_attempt_time, units = "
      secs")) > lockout_seconds
  ) {
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

safe_error <- function(e) {
  # Map known error types to user-friendly messages
  msg <- conditionMessage(e)
  if (grepl("credentials|auth|permission|
  access denied", msg, ignore.case = TRUE))
    return("Authentication failed. Please check your credentials.")
  if (grepl("network|connection|timeout|refused", msg, ignore.case = TRUE))
    return("Connection error. Please check your network and try again.")
  if (grepl("not found|no such", msg, ignore.case = TRUE))
    return("Resource not found. Please verify your configuration.")
  # Generic fallback — never expose raw error text
  "An unexpected error occurred. Please try again."
}

source("data/aws.r")
source("data/azure.r")
source("data/GCP.r")
source("data/mock.r")
source("data/forecast.r")

# Theme and custom CSS for dark mode support and polished UI
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

# Custom CSS overrides for better dark mode support and visual polish
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
  [data-bs-theme='dark'] .status-running  
  { background-color: #065f46; color: #d1fae5; }
  [data-bs-theme='dark'] .status-stopped  
  { background-color: #991b1b; color: #fee2e2; }
  [data-bs-theme='dark'] .status-pending  
  { background-color: #92400e; color: #fef3c7; }
")

# Credentials UI
credentials_ui <- function() {
  div(
    class = "d-flex align-items-center justify-content-center vh-100",
    style = "background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);",
    div(
      class = "card shadow-lg p-5",
      style = "width: 100%; max-width: 
      450px; border: none; border-radius: 15px;",
      div(
        class = "text-center mb-4",
        h1(
          "CloudPulse FinOps",
          class = "fw-bold",
          style = "color: #333; font-size: 2em;"
        ),
        p(
          "Cloud Cost Intelligence Platform",
          class = "text-muted mb-0",
          style = "font-size: 1.1em;"
        )
      ),
      div(
        id = "credential_form", class = "mb-3",
        h5("Enter Cloud Credentials", class = "fw-bold mb-4"),
        div(class = "mb-3",
          tags$label("Cloud Provider", class = "form-label fw-bold"),
          selectInput(
            "cred_provider",
            NULL,
            choices = c(
              "AWS", "Azure", "GCP", "Use Mock Data"
            ), width = "100%"
          )
        ),
        conditionalPanel("input.cred_provider == 'AWS'",
          div(class="mb-3", textInput("aws_access_key","AWS 
          Access Key ID", placeholder="AKIA...", width="100%")),
          div(class="mb-3", passwordInput("aws_secret_key","AWS 
          Secret Access Key", placeholder="Enter your 
          secret key", width="100%")),
          div(class="mb-3", textInput("aws_region","AWS 
          Region", value="us-east-1", width="100%"))
        ),
        conditionalPanel("input.cred_provider == 'Azure'",
          div(class="mb-3", textInput("azure_subscription","Subscription 
          ID", placeholder="UUID", width="100%")),
          div(class="mb-3", textInput("azure_tenant","Tenant 
          ID", placeholder="UUID", width="100%")),
          div(class="mb-3", textInput("azure_client_id","Client 
          ID", placeholder="UUID", width="100%")),
          div(class="mb-3", passwordInput("azure_client_secret","Client 
          Secret", placeholder="Enter your secret", width="100%"))
        ),
        conditionalPanel("input.cred_provider == 'GCP'",
          div(class="mb-3", textInput("gcp_project_id", "Project 
          ID", placeholder="my-project", width="100%")),
          div(class = "mb-3", textAreaInput("gcp_service_account","Service 
          Account JSON", placeholder="Paste your 
          service account key", rows=5, width="100%"))
        ),
        conditionalPanel("input.cred_provider == 'Use Mock Data'",
          div(class="alert alert-info", icon("info-circle"), " Using 
          demo data for testing purposes")
        )
      ),
      div(class = "d-grid gap-2",
        actionButton("login_btn", "Connect & 
        Continue", class = "btn btn-primary btn-lg fw-bold",
          style = "border-radius: 10px; padding: 0.75rem 1.5rem;"
        )
      ),
      div(class = "text-center mt-3",
        h6("Your credentials are secure and never stored", class = "text-muted")
      )
    )
  )
}
 
# Developer Page UI
developer_ui <- function() {
  div(
    class = "p-4",
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
        card_header(tags$span("Request Test Instance", class = "fw-bold")),
        card_body(
          div(class = "mb-3",
            tags$label("Organization / Team", class = "form-label fw-bold"),
            textInput("dev_org", NULL, placeholder = "e.g. 
            Data Engineering", width = "100%")
          ),
          div(class = "mb-3",
            tags$label("Cloud Provider", class = "form-label fw-bold"),
            selectInput("dev_provider", NULL, choices = c("AWS", "
            Azure", "GCP"), width = "100%")
          ),
          div(class = "mb-3",
            tags$label("Instance Type", class = "form-label fw-bold"),
            selectInput("dev_instance_type", NULL,
              choices = c(
                "Small  (2 vCPU,  4GB RAM)"  = "small",
                "Medium (4 vCPU,  8GB RAM)"  = "medium",
                "Large  (8 vCPU, 16GB RAM)"  = "large",
                "XLarge (16 vCPU,32GB RAM)"  = "xlarge"
              ), width = "100%"
            )
          ),
          div(class = "mb-3",
            tags$label("Region", class = "form-label fw-bold"),
            selectInput("dev_region", NULL,
              choices = c(
                "us-east-1", "us-west-2",
                "eu-west-1", "ap-southeast-1"
              ),
              width = "100%"
            )
          ),
          div(class = "mb-3",
            tags$label("Purpose / Notes", class = "form-label fw-bold"),
            textAreaInput("dev_notes", NULL,
              placeholder = "Describe the use case for this instance...",
              rows = 3, width = "100%"
            )
          ),
          div(class = "mb-3",
            tags$label("Auto-shutdown after 
            (hours)", class = "form-label fw-bold"),
            numericInput(
              "dev_ttl", NULL, value = 8, min = 1, max = 168, width = "100%"
            ),
            tags$small("Instance will be automatically 
            stopped after this duration.", class = "text-muted")
          ),
          div(class = "d-grid",
            actionButton("dev_request_btn", "Submit Request",
              class = "btn btn-primary fw-bold", style = "border-radius: 8px;"
            )
          )
        )
      ),

      # Active instances panel
      card(
        card_header(
          div(class = "d-flex justify-content-between align-items-center",
            tags$span("⚡ Active Test Instances", class = "fw-bold"),
            actionButton("dev_refresh_btn", icon("rotate"), class = "btn 
            btn-sm btn-outline-secondary")
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
        card_header(tags$span("Automated 
        Instance Shutdown", class = "fw-bold")),
        card_body(
          layout_columns(
            col_widths = c(4, 4, 4),

            div(
              h6("Weekend Shutdown", class = "fw-bold"),
              p("Automatically stop all non-critical 
              instances on weekends to reduce costs.",
                class = "text-muted small"),
              div(class = "mb-2",
                checkboxInput("sched_weekend", "Enable weekend 
                shutdown (Fri 6PM – Mon 8AM)", value = FALSE)
              ),
              conditionalPanel("input.sched_weekend == true",
                div(class = "alert alert-success p-2",
                  tags$small("Weekend shutdown active. 
                  Estimated savings: ~28% monthly compute cost.")
                )
              )
            ),

            div(
              h6("Daily Off-Hours Shutdown", class = "fw-bold"),
              p("Stop instances outside business 
              hours automatically.", class = "text-muted small"),
              div(class = "mb-2",
                checkboxInput("sched_offhours", "Enable 
                off-hours shutdown (8PM – 7AM)", value = FALSE)
              ),
              conditionalPanel("input.sched_offhours == true",
                div(class = "mb-2",
                  tags$label("Business hours 
                  timezone", class = "form-label fw-bold small"),
                  selectInput("sched_tz", NULL,
                    choices = c("America/New_York", "
                    America/Chicago", "America/Denver", "
                    America/Los_Angeles", "UTC"),
                    width = "100%"
                  )
                )
              )
            ),

            div(
              h6("Custom Schedule", class = "fw-bold"),
              p("Set a specific shutdown time for selected 
              instances.", class = "text-muted small"),

              div(class = "mb-2",
                tags$label("Shutdown date & 
                time", class = "form-label fw-bold small"),
                textInput("sched_custom_dt", NULL,
                  placeholder = "YYYY-MM-DD HH:MM", width = "100%"
                )
              ),
              div(class = "mb-2",
                tags$label("Target instances 
                (comma-separated)", class = "form-label fw-bold small"),
                textInput("sched_targets", NULL,
                  placeholder = "instance-1, instance-2", width = "100%"
                )
              ),
              div(class = "d-grid",
                actionButton("sched_apply_btn", "Apply Schedule",
                  class = "btn btn-outline-primary btn-sm fw-bold"
                )
              )
            )
          ),

          hr(),

          # Schedule log
          div(
            h6("Schedule Activity Log", class = "fw-bold"),
            div(
              style = "max-height: 180px; overflow-y: 
              auto; font-size: 0.85rem;",
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
        card_header(tags$span("Request History", class = "fw-bold")),
        card_body(
          DTOutput("dev_requests_table") |> spinner()
        )
      )
    )
  )
}

# Dashboard UI with sidebar navigation and dynamic content area
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
          class = "btn btn-sm btn-outline-secondary", title = "Logout"
        )
      ),
      hr(),
      div(class = "mb-3",
        div(class = "btn-group w-100",
          actionButton("nav_dashboard", "Analytics",
            class = "btn btn-sm 
            btn-outline-primary active", style = "border-radius: 6px 0 0 6px;"
          ),
          actionButton("nav_developer", "🛠 Developer",
            class = "btn btn-sm 
            btn-outline-primary", style = "border-radius: 0 6px 6px 0;"
          )
        )
      ),
      hr(),
      conditionalPanel("input.nav_developer % 2 == 0",
        div(class = "mb-4",
          h6("Query Configuration", class = "fw-bold 
          text-uppercase small text-muted"),
          selectInput(
            "provider","Cloud Provider", 
            choices = c("AWS", "Azure", "GCP"), width = "100%"
          ),
          selectInput(
            "query_type","Query Type",
            choices = c("Metadata", "Usage", "Cost"), width = "100%"
          ),
          checkboxInput("use_mock", "Use mock data (local)", value = TRUE)
        ),
        conditionalPanel("input.query_type == 
        'Usage' || input.query_type == 'Cost'",
          div(class = "mb-4",
            h6("Time Period", class = "fw-bold 
            text-uppercase small text-muted"),
            dateRangeInput("date_range", NULL,
              start = Sys.Date() - 30,
              end = Sys.Date(),
              width = "100%"
            )
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
            selectInput("instance_status", "Instance Status",
              choices = c(
                "All",
                "Available",
                "Stopped",
                "Other"
              ), width = "100%"
            )
          )
        ),
        conditionalPanel("input.query_type == 'Usage'",
          div(class = "mb-4",
            h6("Forecast", class = "fw-bold text-uppercase small text-muted"),
            checkboxInput("enable_forecast","Enable forecast", value = FALSE),
            conditionalPanel("input.enable_forecast == true",
              numericInput("forecast_horizon","Horizon 
              (days)", value=7, min=1, max=90, width="100%")
            )
          )
        ),
        div(class = "d-grid gap-2 mt-4",
          actionButton("query","Query Data", class = "btn btn-primary fw-bold",
            style = "padding: 0.75rem; border-radius: 8px; font-size: 1.1em;"
          )
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

# Analytics content
analytics_ui <- function() {
  tagList(
    layout_columns(col_widths = c(12),
      card(
        class = "bg-gradient",
        style = "background: 
        linear-gradient(135deg, #667eea 0%, #764ba2 100%);",
        div(class = "text-white",
          h2("Cloud Analytics Dashboard", class = "fw-bold mb-2"),
          p("Real-time insights from your cloud infrastructure", class = "mb-0")
        )
      )
    ),
    layout_columns(col_widths = c(3,3,3,3),
      card(class = "text-center border-start border-5 border-primary p-3",
        h6("Provider", class = "text-muted small"),
        textOutput("kpi_provider", inline = TRUE) |> spinner()
      ),
      card(class = "text-center border-start border-5 border-success p-3",
        h6("Query Type", class = "text-muted small"),
        textOutput("kpi_query_type", inline = TRUE) |> spinner()
      ),
      card(class = "text-center border-start border-5 border-info p-3",
        h6("Records", class = "text-muted small"),
        textOutput("kpi_records", inline = TRUE) |> spinner()
      ),
      card(class = "text-center border-start border-5 border-warning p-3",
        h6("Last Query", class = "text-muted small"),
        textOutput("kpi_last_query", inline = TRUE) |> spinner()
      )
    ),
    layout_columns(col_widths = c(12),
      card(full_screen = TRUE,
        card_header("Query Results", class = "fw-bold"),
        DTOutput("cloud_table") |> spinner()
      )
    ),
    layout_columns(col_widths = c(12),
      card(full_screen = TRUE,
        card_header("Visualization", class = "fw-bold"),
        plotlyOutput("cloud_plot", height = "400px") |> spinner()
      )
    ),
    conditionalPanel("input.enable_forecast == 
    true && input.query_type == 'Usage'",
      layout_columns(col_widths = c(12),
        card(full_screen = TRUE,
          card_header("Forecast Projections", class = "fw-bold"),
          DTOutput("forecast_table") |> spinner()
        )
      )
    )
  )
}

# Main UI with navbar and dynamic content area
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
            var headline = detail.headline, 
            message = detail.message, status = detail.status;
            if (!message) return;
            if (typeof window.showShinyClientMessage === 'function') {
              window.showShinyClientMessage({ headline: headline, 
              message: message, status: status });
            }
          });
        "))
      ),
      uiOutput("main_ui")
    )
  )
}

# Server logic with authentication, query handling, and state management
server <- function(input, output, session) {

  user_authenticated     <- reactiveVal(FALSE)
  authenticated_provider <- reactiveVal(NULL)
  last_query_time        <- reactiveVal(NULL)
  current_page           <- reactiveVal("dashboard")

  # Security state and session management
  last_attempt_time  <- reactiveVal(NULL)
  last_activity_time <- reactiveVal(Sys.time())

  # Session timeout — check every 60 seconds
  session_timer <- reactiveTimer(60000)
  observe({
    session_timer()
    if (user_authenticated()) {
      idle_secs <- as.numeric(difftime(Sys.time(),
                                       last_activity_time(), units = "secs"))
      if (idle_secs > session_timeout_s) {
        user_authenticated(FALSE)
        authenticated_provider(NULL)
        session$userData$aws_creds   <- NULL
        session$userData$azure_creds <- NULL
        session$userData$gcp_creds   <- NULL
        login_attempts(0L)
        showNotification("Session expired due 
          to inactivity. Please log in again.",
          type = "warning", duration = 8
        )
      }
    }
  })

  # Reset activity timer on any input
  observe({
    reactiveValuesToList(input)
    if (user_authenticated()) last_activity_time(Sys.time())
  })

  # Instance requests
  instance_requests <- reactiveVal(data.frame(
    ID        = character(),
    Org       = character(),
    Provider  = character(),
    Type      = character(),
    Region    = character(),
    TTL_hrs   = numeric(),
    Status    = character(),
    Requested = character(),
    Notes     = character(),
    stringsAsFactors = FALSE
  ))

  # Schedule activity log
  sched_log <- reactiveVal(character(0))

  observeEvent(input$nav_dashboard, { current_page("dashboard") })
  observeEvent(input$nav_developer, { current_page("developer") })

  output$main_ui <- renderUI({
    if (user_authenticated()) dashboard_ui() else credentials_ui()
  })

  output$page_content <- renderUI({
    if (current_page() == "developer") developer_ui() else analytics_ui()
  })

  observeEvent(input$login_btn, {
    rl <- check_rate_limit(login_attempts(), last_attempt_time())
    if (rl$reset) {
      login_attempts(0L)
      last_attempt_time(NULL)
    }
    if (rl$locked) {
      remaining <- ceiling(remaining_lockout(last_attempt_time()))
      showNotification(
        paste0(
          "Too many failed attempts. 
          Try again in ", remaining, " seconds."
        ),
        type = "error", duration = 8
      )
      return()
    }

    provider <- input$cred_provider

    if (provider == "Use Mock Data") {
      login_attempts(0L)
      last_attempt_time(NULL)
      last_activity_time(Sys.time())
      user_authenticated(TRUE)
      authenticated_provider("Mock")
      showNotification("Connected with 
      mock data.", type = "message", duration = 3)

    } else if (provider == "AWS") {
      # Validate and sanitize
      key    <- sanitize_aws_key(input$aws_access_key)
      secret <- sanitize_text(input$aws_secret_key, max_len = 128L)
      region <- sanitize_aws_region(input$aws_region)

      errors <- character(0)
      if (!nzchar(key))    errors <- c(errors, "Invalid AWS Access 
      Key format (must start with AKIA/ASIA and be 20 characters).")
      if (!nzchar(secret)) errors <- c(errors, "AWS Secret Key is required.")

      if (length(errors) > 0) {
        login_attempts(login_attempts() + 1L)
        last_attempt_time(Sys.time())
        showNotification(
          paste(errors, collapse = " "), type = "warning", duration = 6
        )
      } else {
        tryCatch({
          session$userData$aws_creds <- list(
            access_key = key,
            secret_key = secret,
            region     = region
          )
          login_attempts(0L)
          last_attempt_time(NULL)
          last_activity_time(Sys.time())
          user_authenticated(TRUE)
          authenticated_provider("AWS")
          showNotification("AWS connected 
          successfully.", type = "message", duration = 3)
        }, error = function(e) {
          login_attempts(login_attempts() + 1L)
          last_attempt_time(Sys.time())
          showNotification(safe_error(e), type = "error", duration = 5)
        })
      }

    } else if (provider == "Azure") {
      sub_id    <- sanitize_uuid(input$azure_subscription)
      tenant_id <- sanitize_uuid(input$azure_tenant)
      client_id <- sanitize_uuid(input$azure_client_id)
      secret    <- sanitize_text(input$azure_client_secret, max_len = 128L)

      errors <- character(0)
      if (!nzchar(sub_id))    errors <- c(errors, "Invalid 
      Subscription ID (must be a valid UUID).")
      if (!nzchar(tenant_id)) errors <- c(errors, "Invalid 
      Tenant ID (must be a valid UUID).")
      if (!nzchar(client_id)) errors <- c(errors, "Invalid 
      Client ID (must be a valid UUID).")
      if (!nzchar(secret))    errors <- c(errors, "Client Secret is required.")

      if (length(errors) > 0) {
        login_attempts(login_attempts() + 1L)
        last_attempt_time(Sys.time())
        showNotification(
          paste(errors, collapse = " "), type = "warning", duration = 6
        )
      } else {
        tryCatch({
          session$userData$azure_creds <- list(
            subscription  = sub_id,
            tenant        = tenant_id,
            client_id     = client_id,
            client_secret = secret
          )
          login_attempts(0L)
          last_attempt_time(NULL)
          last_activity_time(Sys.time())
          user_authenticated(TRUE)
          authenticated_provider("Azure")
          showNotification("Azure connected 
          successfully.", type = "message", duration = 3)
        }, error = function(e) {
          login_attempts(login_attempts() + 1L)
          last_attempt_time(Sys.time())
          showNotification(safe_error(e), type = "error", duration = 5)
        })
      }

    } else if (provider == "GCP") {
      project_id   <- sanitize_gcp_project(input$gcp_project_id)
      svc_account  <- sanitize_gcp_json(input$gcp_service_account)

      errors <- character(0)
      if (!nzchar(project_id))  errors <- c(errors, "Invalid 
      GCP Project ID (lowercase letters, digits, hyphens, 6-30 chars).")
      if (!nzchar(svc_account)) errors <- c(errors, "Invalid 
      Service Account JSON. Must be a valid service_account key file.")

      if (length(errors) > 0) {
        login_attempts(login_attempts() + 1L)
        last_attempt_time(Sys.time())
        showNotification(
          paste(errors, collapse = " "), type = "warning", duration = 6
        )
      } else {
        tryCatch({
          session$userData$gcp_creds <- list(
            project_id      = project_id,
            service_account = svc_account
          )
          login_attempts(0L)
          last_attempt_time(NULL)
          last_activity_time(Sys.time())
          user_authenticated(TRUE)
          authenticated_provider("GCP")
          showNotification("GCP 
          connected successfully.", type = "message", duration = 3)
        }, error = function(e) {
          login_attempts(login_attempts() + 1L)
          last_attempt_time(Sys.time())
          showNotification(safe_error(e), type = "error", duration = 5)
        })
      }
    }

    # Show remaining attempts warning
    attempts_now <- login_attempts()
    if (attempts_now > 0 && attempts_now < max_login_attempts) {
      remaining_attempts <- max_login_attempts - attempts_now
      showNotification(
        paste0("Warning: ", remaining_attempts, " login attempt(s) 
        remaining before lockout."),
        type = "warning", duration = 5
      )
    }
  })

  # Logout handler — clear all session data and reset state
  observeEvent(input$logout_btn, {
    user_authenticated(FALSE)
    authenticated_provider(NULL)
    current_page("dashboard")
    session$userData$aws_creds   <- NULL
    session$userData$azure_creds <- NULL
    session$userData$gcp_creds   <- NULL
    showNotification("Logged out successfully", type = "default", duration = 3)
  })

  # Developer: Submit instance request
  observeEvent(input$dev_request_btn, {
    # Sanitize all developer form inputs
    org      <- sanitize_text(input$dev_org,   max_len = 100L)
    notes    <- sanitize_text(input$dev_notes, max_len = MAX_NOTES_LENGTH)
    ttl      <- sanitize_numeric(input$dev_ttl, 1, 168, 8)
    provider <- input$dev_provider  # selectInput — constrained to valid choices
    inst_type <- input$dev_instance_type
    region   <- input$dev_region

    if (!nzchar(org)) {
      showNotification("Organization name is 
      required and must not contain special characters.",
        type = "warning", duration = 4
      )
      return()
    }

    new_id <- paste0(provider, "-", format(Sys.time(), "%H%M%S"))
    new_row <- data.frame(
      ID        = new_id,
      Org       = org,
      Provider  = provider,
      Type      = inst_type,
      Region    = region,
      TTL_hrs   = ttl,
      Status    = "Pending",
      Requested = format(Sys.time(), "%Y-%m-%d %H:%M"),
      Notes     = notes,
      stringsAsFactors = FALSE
    )
    instance_requests(rbind(instance_requests(), new_row))
    showNotification(
      paste0("Instance request submitted: ", new_id),
      type = "message", duration = 4
    )
  })

  # Developer: Active instances list
  output$dev_instances_list <- renderUI({
    reqs <- instance_requests()
    if (nrow(reqs) == 0) {
      return(
        div(class = "text-muted text-center py-4",
          icon("server"), " No active test 
          instances. Submit a request to get started."
        )
      )
    }
    active <- reqs[reqs$Status %in% c("Pending","Running"), ]
    if (nrow(active) == 0) {
      return(
        div(
          class = "text-muted text-center py-4", "No active instances."
        )
      )
    }
    lapply(seq_len(nrow(active)), function(i) {
      row <- active[i, ]
      status_class <- if (row$Status == "Running") "
      status-running" else "status-pending"
      div(class = "card instance-card mb-2 p-3",
        div(class = "d-flex justify-content-between align-items-start",
          div(
            tags$strong(row$ID),
            tags$br(),
            tags$small(paste(row$Org, "·", row$Provider, "·
            ", row$Type), class = "text-muted")
          ),
          div(
            tags$span(row$Status, class = paste("status-badge", status_class)),
            tags$br(),
            tags$small(paste("TTL:", row$TTL_hrs, "hrs"), class = "text-muted")
          )
        ),
        if (nzchar(row$Notes)) tags$small(row$Notes, class = "text-muted 
        d-block mt-1"),
        div(class = "mt-2",
          actionButton(paste0("stop_", i), "Stop", class = "btn 
          btn-sm btn-outline-danger me-1"),
          actionButton(paste0("extend_", i), "+2h", class = "btn 
          btn-sm btn-outline-secondary")
        )
      )
    })
  })

  # Developer: Request history table
  output$dev_requests_table <- renderDT({
    reqs <- instance_requests()
    if (nrow(reqs) == 0) {
      return(datatable(data.frame(Message = "No 
      requests yet"), options = list(dom = "t")))
    }
    datatable(reqs,
      options = list(pageLength = 10, scrollX = TRUE, searching = TRUE),
      rownames = FALSE
    )
  })

  # Scheduling: apply custom schedule
  observeEvent(input$sched_apply_btn, {
    dt      <- sanitize_datetime(input$sched_custom_dt)
    targets <- sanitize_instance_list(input$sched_targets)

    if (!nzchar(dt)) {
      showNotification(
        "Invalid date/time. 
        Use format YYYY-MM-DD HH:MM and ensure it is in the future.",
        type = "warning", duration = 5
      )
      return()
    }
    if (!nzchar(targets)) {
      showNotification(
        "No valid instance identifiers found. 
        Use alphanumeric names separated by commas.",
        type = "warning", duration = 5
      )
      return()
    }
    entry <- paste0(
      "[", format(
        Sys.time(), "%H:%M:%S"
      ), "] 
      Custom shutdown scheduled at ",
      dt, " for: ", targets
    )
    sched_log(c(sched_log(), entry))
    showNotification("Custom schedule applied.", type = "message", duration = 3)
  })

  # Weekend shutdown log entry
  observeEvent(input$sched_weekend, {
    status <- if (input$sched_weekend) "ENABLED" else "DISABLED"
    entry  <- paste0("[", format(Sys.time(), "%H:%M:%S"), "] 
    Weekend shutdown ", status)
    sched_log(c(sched_log(), entry))
  })

  observeEvent(input$sched_offhours, {
    status <- if (input$sched_offhours) "ENABLED" else "DISABLED"
    tz     <- if (
      input$sched_offhours && !is.null(input$sched_tz)
    ) input$sched_tz else ""
    entry  <- paste0("[", format(Sys.time(), "%H:%M:%S"), "] 
    Off-hours shutdown ", status,
      if (nzchar(tz)) paste0(" (", tz, ")") else ""
    )
    sched_log(c(sched_log(), entry))
  })

  # Render schedule log
  output$sched_log_ui <- renderUI({
    logs <- sched_log()
    if (length(logs) == 0) {
      return(p("No schedule activity yet.", class = "text-muted"))
    }
    tagList(lapply(rev(logs), function(entry) {
      tags$div(entry, style = "font-family: monospace; padding: 
      2px 0; border-bottom: 1px solid rgba(0,0,0,0.05);")
    }))
  })

  # Analytics instances reactive
  instances <- reactive({
    if (!user_authenticated()) return(character(0))
    tryCatch({
      if (isTRUE(input$use_mock)) {
        get_mock_instances(input$provider)
      } else {
        if (input$provider == "AWS") aws_rds_instances_metadata()$identifier
        else if (input$provider == "Azure") azure_db_instances_metadata()$name
        else if (input$provider == "GCP") gcp_db_instances_metadata()$name
      }
    }, error = function(e) character(0))
  })

  observe({
    updateSelectInput(session, "instance_usage", choices = instances())
    updateSelectInput(session, "instance_cost",  choices = instances())
  })

  # Analytics: Query handling with rate limiting and error management
  query_count      <- reactiveVal(0L)
  last_query_burst <- reactiveVal(NULL)

  cloud_data <- eventReactive(input$query, {
    if (!user_authenticated()) return(data.frame(Error = "Not authenticated"))

    # Query rate limiting — max 20 queries per minute
    now <- Sys.time()
    if (!is.null(last_query_burst())) {
      elapsed <- as.numeric(difftime(now, last_query_burst(), units = "secs"))
      if (elapsed < 60) {
        if (query_count() >= 20L) {
          showNotification("Query rate limit reached. 
            Please wait before querying again.",
            type = "warning", duration = 5
          )
          return(data.frame(Error = "Rate limit exceeded"))
        }
      } else {
        query_count(0L)
      }
    }
    query_count(query_count() + 1L)
    last_query_burst(now)
    last_activity_time(Sys.time())
    result <- tryCatch({
      if (isTRUE(input$use_mock)) {
        if (input$query_type == "Metadata") get_mock_metadata(input$provider)
        else if (input$query_type == "
        Usage")  get_mock_usage(input$provider, input$instance_usage)
        else if (input$query_type == "Cost") {
          get_mock_cost(format(input$date_range[1], "%Y-%m-%d"),
                        format(input$date_range[2], "%Y-%m-%d"))
        }
      } else {
        if (input$query_type == "Metadata") {
          if (input$provider == "AWS") aws_rds_instances_metadata()
          else if (input$provider == "Azure") azure_db_instances_metadata()
          else if (input$provider == "GCP") gcp_db_instances_metadata()
        } else if (input$query_type == "Usage") {
          if (input$provider == "
          AWS") aws_rds_instance_usage(input$instance_usage)
          else if (input$provider == "
          Azure") azure_db_instance_usage(input$instance_usage)
          else if (input$provider == "
          GCP") gcp_db_instance_usage(input$instance_usage)
        } else if (input$query_type == "Cost") {
          s <- format(input$date_range[1], "%Y-%m-%d")
          e <- format(input$date_range[2], "%Y-%m-%d")
          if (input$provider == "AWS") aws_rds_cost_by_instance(s, e)
          else if (input$provider == "Azure") azure_db_cost_by_instance(s, e)
          else if (input$provider == "GCP") gcp_db_cost_by_instance(s, e)
        }
      }
    }, error = function(e) data.frame(Error = e$message))
    last_query_time(Sys.time())
    result
  })

  # KPI outputs
  output$kpi_provider   <- renderText(input$provider)
  output$kpi_query_type <- renderText(input$query_type)
  output$kpi_records    <- renderText({ data <- cloud_data()
                                       nrow(data) })
  output$kpi_last_query <- renderText({
    if (is.null(last_query_time())) "
    Never" else format(last_query_time(), "%H:%M:%S")
  })

  # Data table
  output$cloud_table <- renderDT({
    data <- cloud_data()
    if ("Error" %in% colnames(data)) {
      datatable(data, options = list(dom = "t"))
    } else {
      datatable(
        data, options = list(
          autoWidth = FALSE, scrollX = TRUE, pageLength = 10,
          lengthMenu = c(5, 10, 25, 50), searching = TRUE, ordering = TRUE
        ), filter = "top"
      )
    }
  })

  output$cloud_plot <- renderPlotly({
    data <- cloud_data()
    if ("Error" %in% colnames(data)) {
      return(plot_ly() |> add_annotations(text="No 
      data available", showarrow=FALSE))
    }
    if (input$query_type == "Usage" && nrow(data) > 0 && "
    timestamp" %in% colnames(data)) {
      p <- plot_ly(data, x = ~timestamp, y = ~cpu_avg, type = "
      scatter", mode = "lines", name = "Avg CPU",
                   line=list(color = "#667eea", width=2)) |>
        add_trace(y=~cpu_max, name = "Max 
        CPU", line=list(color = "#764ba2", width=2))
      if (isTRUE(input$enable_forecast)) {
        fc_res <- tryCatch(
          train_forecast_usage(
            data, periods = as.integer(input$forecast_horizon)
          ),
          error = function(e) list(forecast = data.frame())
        )
        if (!is.null(fc_res$forecast) && nrow(fc_res$forecast) > 0) {
          fc_df <- fc_res$forecast |> transform(
            timestamp = as.POSIXct(date) + 12 * 3600
          )
          p <- p |>
            add_lines(x=fc_df$timestamp, y=fc_df$yhat, name="Forecast",
              line=list(dash="dash", color="#FFC107", width=2)
            ) |>
            add_ribbons(
              x=fc_df$timestamp, ymin=fc_df$lower80, ymax=fc_df$upper80,
              name="80% CI", fillcolor="rgba(255,193,7,0.2)",
              line=list(color="transparent"), showlegend=FALSE
            )
        }
      }
      p |> layout(hovermode = "x 
      unified", plot_bgcolor = "#f8f9fa", paper_bgcolor = "#ffffff")
    } else if (
      input$query_type == "Cost" && nrow(data) > 0 && "cost" %in% colnames(data)
    ) {
      plot_ly(data, x = ~start, y = ~cost, type = "bar", name = "Cost",
              marker = list(color = "#198754")) |>
        layout(hovermode = "x 
        unified", plot_bgcolor = "#f8f9fa", paper_bgcolor = "#ffffff")
    } else {
      plot_ly() |> add_annotations(
        text = "No visualization available for this query type or empty data.",
        showarrow = FALSE, font = list(color = "#6c757d", size = 14)
      ) |>
        layout(xaxis = list(visible = FALSE),
               yaxis = list(visible = FALSE),
               plot_bgcolor = "#f8f9fa", paper_bgcolor = "#ffffff")
    }
  })

  # Forecast table
  output$forecast_table <- renderDT({
    if (isTRUE(input$enable_forecast) && input$query_type == "Usage") {
      data <- cloud_data()
      if (nrow(data) > 0 && "Error" %notin% colnames(data)) {
        fc_res <- tryCatch(
          train_forecast_usage(
            data, periods=as.integer(input$forecast_horizon)
          ),
          error = function(e) NULL)
        if (!is.null(fc_res) && nrow(fc_res$forecast) > 0) {
          datatable(fc_res$forecast,
            options=list(autoWidth=FALSE, scrollX=TRUE, pageLength=10)
          )
        } else {
          datatable(data.frame(Note="No forecast available"))
        }
      } else {
        datatable(data.frame(Note="No historical usage data"))
      }
    } else {
      datatable(data.frame(Note="Enable forecast in 
    the sidebar to view predictions"))
    }
  })
}

shinyApp(ui, server)
