# GCP data access and processing functions for Shiny app
# with security validation and error handling
# Functions to connect to Cloud SQL, retrieve metadata, usage,
# and cost data using GCP APIs and BigQuery

library(shiny)
library(DBI)
library(RPostgres)
# load Google libs only if available
if (requireNamespace("googleAuthR", quietly = TRUE)) {
  library(googleAuthR)
} else {
  message("googleAuthR not installed; GCP functions will be disabled or return informative errors.")
}
if (requireNamespace("googleCloudStorageR", quietly = TRUE)) {
  library(googleCloudStorageR)
} else {
  message("googleCloudStorageR not installed; GCP storage helpers will be disabled.")
}
if (requireNamespace("bigrquery", quietly = TRUE)) {
  library(bigrquery)
} else {
  message("bigrquery not installed; BigQuery helpers will be disabled.")
}
library(keyring)
library(httr)
library(jsonlite)

gcp_creds <- function() {
  creds <- list(
    project_id = key_get(service = "gcp", username = "project_id"),
    service_account_key = key_get(service = "gcp", username = "service_account_key"),
    db_instance = key_get(service = "gcp_db", username = "instance"),
    db_host = key_get(service = "gcp_db", username = "host"),
    db_port = tryCatch(as.integer(key_get(service = "gcp_db", username = "port")), error = function(e) 5432),
    db_name = key_get(service = "gcp_db", username = "name"),
    db_user = key_get(service = "gcp_db", username = "user"),
    db_password = key_get(service = "gcp_db", username = "password")
  )

  # Security validation: Ensure required credentials are present
  required_gcp <- c("project_id", "service_account_key")
  missing_gcp <- required_gcp[sapply(creds[required_gcp], function(x) is.null(x) || x == "")]
  if (length(missing_gcp) > 0) {
    stop("Missing required GCP credentials: ", paste(missing_gcp, collapse = ", "))
  }

  required_db <- c("db_host", "db_name", "db_user", "db_password")
  missing_db <- required_db[sapply(creds[required_db], function(x) is.null(x) || x == "")]
  if (length(missing_db) > 0) {
    stop("Missing required GCP DB credentials: ", paste(missing_db, collapse = ", "))
  }

  creds
}

gcp_db_conn <- function(creds = gcp_creds()) {
  dbConnect(
    RPostgres::Postgres(),
    host = creds$db_host,
    port = creds$db_port,
    dbname = creds$db_name,
    user = creds$db_user,
    password = creds$db_password
  )
}

gcp_db_query <- function(sql, creds = gcp_creds()) {
  conn <- gcp_db_conn(creds)
  on.exit(dbDisconnect(conn), add = TRUE)
  dbGetQuery(conn, sql)
}

gcp_data_server <- function(id, sql) {
  moduleServer(id, function(input, output, session) {
    data <- reactive({
      gcp_db_query(sql)
    })
    data
  })
}

gcp_db_instances_metadata <- function(creds = gcp_creds()) {
  if (!requireNamespace("googleAuthR", quietly = TRUE)) {
    return(data.frame(Error = "googleAuthR not installed; install googleAuthR to fetch GCP metadata", stringsAsFactors = FALSE))
  }
  # Authenticate with GCP
  googleAuthR::gar_auth_service(json_file = creds$service_account_key)

  # Cloud SQL Admin API endpoint
  url <- sprintf("https://sqladmin.googleapis.com/v1/projects/%s/instances", creds$project_id)

  response <- httr::GET(url, googleAuthR::gar_api_headers())

  if (httr::status_code(response) != 200) {
    stop("Failed to retrieve GCP instances: ", httr::content(response, "text"))
  }

  instances <- jsonlite::fromJSON(httr::content(response, "text"))$items

  if (is.null(instances) || length(instances) == 0) {
    return(data.frame())
  }

  metadata <- do.call(rbind, lapply(instances, function(inst) {
    data.frame(
      name = inst$name,
      database_version = inst$databaseVersion,
      region = inst$region,
      tier = inst$settings$tier,
      data_disk_size_gb = inst$settings$dataDiskSizeGb,
      state = inst$state,
      connection_name = inst$connectionName
    )
  }))
  metadata
}

gcp_db_instance_usage <- function(instance_name, creds = gcp_creds()) {
  if (!requireNamespace("googleAuthR", quietly = TRUE)) {
    return(data.frame(
      timestamp = as.POSIXct(character(0)),
      cpu_avg = numeric(0),
      cpu_max = numeric(0),
      note = "googleAuthR not installed; cannot fetch GCP usage",
      stringsAsFactors = FALSE
    ))
  }
  # Authenticate with GCP
  googleAuthR::gar_auth_service(json_file = creds$service_account_key)

  # Cloud Monitoring API for CPU utilization
  project <- creds$project_id
  metric_type <- "cloudsql.googleapis.com/database/cpu/utilization"
  filter <- sprintf('resource.type="cloudsql_database" AND resource.labels.database_id="%s"', instance_name)

  url <- sprintf("https://monitoring.googleapis.com/v3/projects/%s/timeSeries", project)

  body <- list(
    filter = filter,
    interval = list(
      startTime = format(Sys.time() - 7 * 86400, "%Y-%m-%dT%H:%M:%SZ"),
      endTime = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
    ),
    aggregation = list(
      alignmentPeriod = "3600s",
      perSeriesAligner = "ALIGN_MEAN",
      crossSeriesReducer = "REDUCE_NONE",
      groupByFields = c()
    )
  )

  response <- httr::POST(url,
    googleAuthR::gar_api_headers(),
    body = jsonlite::toJSON(body, auto_unbox = TRUE),
    encode = "json"
  )

  if (httr::status_code(response) != 200) {
    stop("Failed to retrieve GCP metrics: ", httr::content(response, "text"))
  }

  data <- jsonlite::fromJSON(httr::content(response, "text"))

  if (is.null(data$timeSeries) || length(data$timeSeries) == 0) {
    return(data.frame())
  }

  usage <- do.call(rbind, lapply(data$timeSeries[[1]]$points, function(point) {
    data.frame(
      timestamp = as.POSIXct(point$interval$startTime),
      cpu_avg = point$value$doubleValue
    )
  }))

  # For maximum, we might need another query or calculate from data
  usage$cpu_max <- usage$cpu_avg # Placeholder, adjust if needed
  usage <- usage[order(usage$timestamp), ]
  usage
}

gcp_db_cost_by_instance <- function(start_date, end_date, creds = gcp_creds()) {
  if (!requireNamespace("googleAuthR", quietly = TRUE)) {
    return(data.frame(
      start = start_date,
      end = end_date,
      instance_name = creds$db_instance,
      cost = numeric(0),
      currency = character(0),
      note = "googleAuthR not installed; cannot fetch GCP cost data",
      stringsAsFactors = FALSE
    ))
  }
  # Authenticate with GCP
  googleAuthR::gar_auth_service(json_file = creds$service_account_key)

  # Cloud Billing API
  billing_account <- key_get(service = "gcp", username = "billing_account") # Assuming stored separately

  url <- sprintf("https://cloudbilling.googleapis.com/v1/%s:getCost", billing_account)

  body <- list(
    filter = sprintf('resource.labels.instance_name="%s"', creds$db_instance),
    granularity = "MONTHLY",
    dateRange = list(
      startDate = list(year = as.integer(format(as.Date(start_date), "%Y")), month = as.integer(format(as.Date(start_date), "%m")), day = as.integer(format(as.Date(start_date), "%d"))),
      endDate = list(year = as.integer(format(as.Date(end_date), "%Y")), month = as.integer(format(as.Date(end_date), "%m")), day = as.integer(format(as.Date(end_date), "%d")))
    )
  )

  response <- httr::POST(url,
    googleAuthR::gar_api_headers(),
    body = jsonlite::toJSON(body, auto_unbox = TRUE),
    encode = "json"
  )

  if (httr::status_code(response) != 200) {
    stop("Failed to retrieve GCP costs: ", httr::content(response, "text"))
  }

  cost_data <- jsonlite::fromJSON(httr::content(response, "text"))

  if (is.null(cost_data$costs) || length(cost_data$costs) == 0) {
    return(data.frame())
  }

  results <- do.call(rbind, lapply(cost_data$costs, function(cost) {
    data.frame(
      start = start_date,
      end = end_date,
      instance_name = creds$db_instance,
      cost = cost$cost,
      currency = cost$currency
    )
  }))
  results
}
