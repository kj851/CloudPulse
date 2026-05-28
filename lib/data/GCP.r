# GCP data access and processing functions for Shiny app
# with security validation and error handling
# Functions to connect to Cloud SQL, retrieve metadata, usage,
# and cost data using GCP APIs and BigQuery.
# Copyright (c) 2026, Keaton Szantho

library(shiny)
library(DBI)
library(RPostgres)
library(keyring)
library(httr)
library(jsonlite)

if (requireNamespace("googleAuthR", quietly = TRUE))
  library(googleAuthR)
if (requireNamespace("googleCloudStorageR", quietly = TRUE))
  library(googleCloudStorageR)
if (requireNamespace("bigrquery", quietly = TRUE))
  library(bigrquery)

`%notin%` <- function(x, y) !(x %in% y)
`%||%`    <- function(a, b) if (!is.null(a)) a else b

gcp_creds <- function() {
  creds <- list(
    project_id          = key_get(service = "gcp",    username = "project_id"),
    service_account_key = key_get(
      service = "gcp",
      username = "service_account_key"
    ),
    db_instance         = key_get(service = "gcp_db", username = "instance"),
    db_host             = key_get(service = "gcp_db", username = "host"),
    db_port = tryCatch(as.integer(
      key_get(service = "gcp_db",
        username = "port"
      )
    ),
    error = function(e) 5432L),
    db_name             = key_get(service = "gcp_db", username = "name"),
    db_user             = key_get(service = "gcp_db", username = "user"),
    db_password         = key_get(service = "gcp_db", username = "password")
  )

  # PATCH: validate GCP project ID format
  proj <- trimws(creds$project_id %||% "")
  if (!grepl("^[a-z][a-z0-9\\-]{4,28}[a-z0-9]$", proj, perl = TRUE))
    stop("Invalid GCP Project ID format.")

  # Validate port
  if (is.na(creds$db_port) || creds$db_port < 1L || creds$db_port > 65535L)
    creds$db_port <- 5432L

  required_gcp <- c("project_id","service_account_key")
  missing_gcp  <- required_gcp[sapply(
    creds[required_gcp], function(x) is.null(x) || !nzchar(x)
  )]
  if (length(missing_gcp) > 0)
    stop("Missing required GCP 
    credentials: ", paste(missing_gcp, collapse = ", "))

  required_db <- c("db_host","db_name","db_user","db_password")
  missing_db  <- required_db[sapply(
    creds[required_db], function(x) is.null(x) || !nzchar(x)
  )]
  if (length(missing_db) > 0)
    stop("Missing required GCP 
    DB credentials: ", paste(missing_db, collapse = ", "))

  creds
}

gcp_db_conn <- function(creds = gcp_creds()) {
  dbConnect(
    RPostgres::Postgres(),
    host            = creds$db_host,
    port            = creds$db_port,
    dbname          = creds$db_name,
    user            = creds$db_user,
    password        = creds$db_password,
    connect_timeout = 10L  # PATCH: prevent indefinite hangs
  )
}

gcp_db_query <- function(sql, params = list(), creds = gcp_creds()) {
  if (!is.character(sql) || length(sql) != 1L || nchar(sql) > 10000L)
    stop("Invalid SQL argument.")
  if (
      grepl(
            "(--|;\\s*DROP|;\\s*DELETE|;\\s*INSERT|;\\s*UPDATE|EXEC\\s*\\(|xp_cmdshell)",
            sql, ignore.case = TRUE, perl = TRUE))
    stop("SQL contains disallowed patterns.")

  conn <- gcp_db_conn(creds)
  on.exit(dbDisconnect(conn), add = TRUE)
  if (length(params) > 0) dbGetQuery(conn, sql, params = params)
  else                     dbGetQuery(conn, sql)
}

gcp_data_server <- function(id, sql) {
  moduleServer(id, function(input, output, session) {
    data <- reactive({
      gcp_db_query(sql)
    })
    data
  })
}

.validate_gcp_instance <- function(name) {
  name <- trimws(name %||% "")
  if (!grepl("^[a-z][a-z0-9\\-]{0,61}[a-z0-9]$", name, perl = TRUE))
    stop("Invalid GCP instance name.")
  name
}

.validate_date_range <- function(start_date, end_date) {
  sd <- tryCatch(as.Date(start_date, "%Y-%m-%d"), error = function(e) NA)
  ed <- tryCatch(as.Date(end_date,   "%Y-%m-%d"), error = function(e) NA)
  if (is.na(sd) || is.na(ed))    stop("Invalid date format. Use YYYY-MM-DD.")
  if (sd >= ed)                  stop("start_date must be before end_date.")
  if (as.numeric(ed - sd) > 366) stop("Date range must not exceed 366 days.")
  list(sd = sd, ed = ed)
}

# VULNERABILITY FIXED: original called stop() with raw API response text
# (httr::content(response, "text")), leaking full API error bodies to the UI.
.safe_gcp_response <- function(response, context = "GCP API") {
  code <- httr::status_code(response)
  if (code == 401L) stop(context, ": authentication failed.")
  if (code == 403L) stop(context, ": permission denied.")
  if (code == 404L) stop(context, ": resource not found.")
  if (code >= 400L) stop(context, ": request failed (HTTP ", code, ").")
  httr::content(response, "text", encoding = "UTF-8")
}

gcp_db_instances_metadata <- function(creds = gcp_creds()) {
  if (!requireNamespace("googleAuthR", quietly = TRUE))
    return(data.frame(
      Error = "googleAuthR not installed.", stringsAsFactors = FALSE
    ))

  googleAuthR::gar_auth_service(json_file = creds$service_account_key)
  url <- sprintf("https://sqladmin.googleapis.com/v1/projects/%s/instances",
    creds$project_id
  )
  response <- httr::GET(url, googleAuthR::gar_api_headers())
  body <- .safe_gcp_response(response, "Cloud SQL")
  instances <- jsonlite::fromJSON(body)$items

  if (is.null(instances) || length(instances) == 0) return(data.frame())

  do.call(rbind, lapply(instances, function(inst) {
    data.frame(
      name              = inst$name,
      database_version  = inst$databaseVersion,
      region            = inst$region,
      tier              = inst$settings$tier,
      data_disk_size_gb = inst$settings$dataDiskSizeGb,
      state             = inst$state,
      connection_name   = inst$connectionName,
      stringsAsFactors = FALSE
    )
  }))
}

gcp_db_instance_usage <- function(instance_name, creds = gcp_creds()) {
  if (!requireNamespace("googleAuthR", quietly = TRUE))
    return(data.frame(timestamp = as.POSIXct(character(0)),
                      cpu_avg = numeric(0), cpu_max = numeric(0),
                      stringsAsFactors = FALSE))

  instance_name <- .validate_gcp_instance(instance_name)
  googleAuthR::gar_auth_service(json_file = creds$service_account_key)

  filter <- sprintf(
    'resource.type="cloudsql_database" AND resource.labels.database_id="%s:%s"',
    creds$project_id, instance_name
  )
  url  <- sprintf("https://monitoring.googleapis.com/v3/projects/%s/timeSeries",
    creds$project_id
  )
  body <- list(
    filter    = filter,
    interval  = list(
      startTime = format(Sys.time() - 7 * 86400, "%Y-%m-%dT%H:%M:%SZ"),
      endTime   = format(Sys.time(),             "%Y-%m-%dT%H:%M:%SZ")
    ),
    aggregation = list(
      alignmentPeriod  = "3600s",
      perSeriesAligner = "ALIGN_MEAN",
      crossSeriesReducer = "REDUCE_NONE",
      groupByFields    = list()
    )
  )
  response <- httr::POST(url, googleAuthR::gar_api_headers(),
    body = jsonlite::toJSON(
      body, auto_unbox = TRUE
    ), encode = "json"
  )
  content <- .safe_gcp_response(response, "Cloud Monitoring")
  data <- jsonlite::fromJSON(content)

  if (is.null(data$timeSeries) ||
        length(data$timeSeries) == 0) return(data.frame())

  usage <- do.call(rbind, lapply(data$timeSeries[[1]]$points, function(p) {
    data.frame(timestamp = as.POSIXct(p$interval$startTime),
               cpu_avg   = p$value$doubleValue,
               stringsAsFactors = FALSE)
  }))
  usage$cpu_max <- usage$cpu_avg
  usage[order(usage$timestamp), ]
}

gcp_db_cost_by_instance <- function(start_date, end_date, creds = gcp_creds()) {
  if (!requireNamespace("googleAuthR", quietly = TRUE))
    return(data.frame(start = start_date, end = end_date,
                      instance_name = creds$db_instance,
                      cost = numeric(0), currency = character(0),
                      stringsAsFactors = FALSE))

  dates <- .validate_date_range(start_date, end_date)
  googleAuthR::gar_auth_service(json_file = creds$service_account_key)

  # PATCH: billing_account now validated as non-empty before use
  billing_account <- tryCatch(
    key_get(service = "gcp", username = "billing_account"),
    error = function(e) ""
  )
  if (!nzchar(billing_account)) stop("GCP billing account not configured.")
  if (!grepl("^billingAccounts/[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$",
             billing_account, perl = TRUE))
    stop("Invalid GCP billing account format.")

  url <- sprintf("https://cloudbilling.googleapis.com/v1/%s:getCost",
    billing_account
  )
  body <- list(
    filter      = sprintf('resource.labels.
    instance_name="%s"', creds$db_instance),
    granularity = "MONTHLY",
    dateRange   = list(
      startDate = list(year  = as.integer(format(dates$sd, "%Y")),
                       month = as.integer(format(dates$sd, "%m")),
                       day   = as.integer(format(dates$sd, "%d"))),
      endDate   = list(year  = as.integer(format(dates$ed, "%Y")),
                       month = as.integer(format(dates$ed, "%m")),
                       day   = as.integer(format(dates$ed, "%d")))
    )
  )
  response <- httr::POST(url, googleAuthR::gar_api_headers(),
    body = jsonlite::toJSON(
      body, auto_unbox = TRUE
    ), encode = "json"
  )
  content   <- .safe_gcp_response(response, "Cloud Billing")
  cost_data <- jsonlite::fromJSON(content)

  if (is.null(cost_data$costs) ||
        length(cost_data$costs) == 0) return(data.frame())

  do.call(rbind, lapply(cost_data$costs, function(c) {
    data.frame(start = format(dates$sd), end = format(dates$ed),
               instance_name = creds$db_instance,
               cost = c$cost, currency = c$currency,
               stringsAsFactors = FALSE)
  }))
}
