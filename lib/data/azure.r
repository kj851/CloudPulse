# Azure data access and processing functions for Shiny app
# with security validation and error handling
# Connect to Azure SQL Database, retrieve metadata, usage, and cost data.
# Author: Keaton Szantho

library(shiny)
library(DBI)
library(RPostgres)
library(AzureRMR)
library(AzureAuth)
library(AzureStor)
library(keyring)
library(httr)
library(jsonlite)

`%notin%` <- function(x, y) !(x %in% y)
`%||%`    <- function(a, b) if (!is.null(a)) a else b

azure_creds <- function() {
  creds <- list(
    tenant_id       = key_get(service = "azure", username = "tenant_id"),
    client_id       = key_get(service = "azure", username = "client_id"),
    client_secret   = key_get(service = "azure", username = "client_secret"),
    subscription_id = key_get(service = "azure", username = "subscription_id"),
    resource_group  = key_get(service = "azure", username = "resource_group"),
    db_host         = key_get(service = "azure_db", username = "host"),
    db_port         = tryCatch(as.integer(key_get(service = "azure_db", username = "port")),
                       error = function(e) 5432L),
    db_name         = key_get(service = "azure_db", username = "name"),
    db_user         = key_get(service = "azure_db", username = "user"),
    db_password     = key_get(service = "azure_db", username = "password")
  )

  # PATCH: validate UUID format for all ID fields
  uuid_pattern <- "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
  for (field in c("tenant_id","client_id","subscription_id")) {
    val <- trimws(creds[[field]] %||% "")
    if (!grepl(uuid_pattern, val, perl = TRUE))
      stop(sprintf("Invalid Azure %s format (must be a UUID).", field))
  }

  # Validate port
  if (is.na(creds$db_port) || creds$db_port < 1L || creds$db_port > 65535L)
    creds$db_port <- 5432L

  required_azure <- c("tenant_id","client_id","client_secret","subscription_id")
  missing_azure  <- required_azure[sapply(creds[required_azure], function(x) is.null(x) || !nzchar(x))]
  if (length(missing_azure) > 0)
    stop("Missing required Azure credentials: ", paste(missing_azure, collapse = ", "))

  required_db <- c("db_host","db_name","db_user","db_password")
  missing_db  <- required_db[sapply(creds[required_db], function(x) is.null(x) || !nzchar(x))]
  if (length(missing_db) > 0)
    stop("Missing required Azure DB credentials: ", paste(missing_db, collapse = ", "))

  creds
}

azure_db_conn <- function(creds = azure_creds()) {
  dbConnect(
    RPostgres::Postgres(),
    host            = creds$db_host,
    port            = creds$db_port,
    dbname          = creds$db_name,
    user            = creds$db_user,
    password        = creds$db_password,
    connect_timeout = 10L
  )
}

# Parameterized query — prevents SQL injection
azure_db_query <- function(sql, params = list(), creds = azure_creds()) {
  if (!is.character(sql) || length(sql) != 1L || nchar(sql) > 10000L)
    stop("Invalid SQL argument.")
  if (grepl("(--|;\\s*DROP|;\\s*DELETE|;\\s*INSERT|;\\s*UPDATE|EXEC\\s*\\(|xp_cmdshell)",
            sql, ignore.case = TRUE, perl = TRUE))
    stop("SQL contains disallowed patterns.")

  conn <- azure_db_conn(creds)
  on.exit(dbDisconnect(conn), add = TRUE)
  if (length(params) > 0) dbGetQuery(conn, sql, params = params)
  else                     dbGetQuery(conn, sql)
}

azure_data_server <- function(id, sql) {
  moduleServer(id, function(input, output, session) {
    data <- reactive({ azure_db_query(sql) })
    data
  })
}

# VULNERABILITY FIXED: original passed server_name directly into resource
# ID strings and API URLs without sanitization — could manipulate API paths.
.validate_azure_server_name <- function(name) {
  name <- trimws(name %||% "")
  if (!grepl("^[a-zA-Z0-9][a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9]$", name, perl = TRUE))
    stop("Invalid Azure server name.")
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

azure_db_instances_metadata <- function(creds = azure_creds()) {
  az  <- az_rm$new(tenant = creds$tenant_id, app = creds$client_id,
                   password = creds$client_secret)
  sub <- az$get_subscription(creds$subscription_id)
  servers <- sub$list_resources(
    filter = "resourceType eq 'Microsoft.DBforPostgreSQL/flexibleServers'"
  )
  if (length(servers) == 0) return(data.frame())
  do.call(rbind, lapply(servers, function(s) {
    data.frame(
      name                       = s$name,
      location                   = s$location,
      sku_name                   = s$sku$name,
      sku_tier                   = s$sku$tier,
      storage_mb                 = s$properties$storage$storageSizeMB,
      version                    = s$properties$version,
      state                      = s$properties$state,
      fully_qualified_domain_name = s$properties$fullyQualifiedDomainName,
      stringsAsFactors = FALSE
    )
  }))
}

azure_db_instance_usage <- function(server_name, creds = azure_creds()) {
  server_name <- .validate_azure_server_name(server_name)
  az  <- az_rm$new(tenant = creds$tenant_id, app = creds$client_id,
                   password = creds$client_secret)
  sub <- az$get_subscription(creds$subscription_id)
  mon <- sub$get_monitor_client()
  resource_id <- sprintf(
    "/subscriptions/%s/resourceGroups/%s/providers/Microsoft.DBforPostgreSQL/flexibleServers/%s",
    creds$subscription_id, creds$resource_group, server_name
  )
  metrics <- mon$get_metrics(
    resource_id  = resource_id,
    metricnames  = "cpu_percent",
    aggregation  = "Average,Maximum",
    interval     = "PT1H",
    timespan     = paste0(
      format(Sys.time() - 7 * 86400, "%Y-%m-%dT%H:%M:%SZ"), "/",
      format(Sys.time(),             "%Y-%m-%dT%H:%M:%SZ"))
  )
  if (length(metrics$value) == 0 || length(metrics$value[[1]]$timeseries) == 0)
    return(data.frame())
  usage <- do.call(rbind, lapply(metrics$value[[1]]$timeseries[[1]]$data, function(dp) {
    data.frame(timestamp = as.POSIXct(dp$timeStamp),
               cpu_avg   = dp$average,
               cpu_max   = dp$maximum)
  }))
  usage[order(usage$timestamp), ]
}

azure_db_cost_by_instance <- function(start_date, end_date, creds = azure_creds()) {
  dates <- .validate_date_range(start_date, end_date)
  az    <- az_rm$new(tenant = creds$tenant_id, app = creds$client_id,
                     password = creds$client_secret)
  sub   <- az$get_subscription(creds$subscription_id)
  cost  <- sub$get_cost_management_client()
  query <- list(
    type       = "ActualCost",
    timeframe  = "Custom",
    timePeriod = list(from = format(dates$sd), to = format(dates$ed)),
    dataset    = list(
      granularity = "Monthly",
      aggregation = list(totalCost = list(name = "Cost", `function` = "Sum")),
      grouping    = list(list(type = "Dimension", name = "ResourceId")),
      filter      = list(dimensions = list(
        name     = "ResourceType",
        operator = "In",
        values   = list("microsoft.dbforpostgresql/flexibleservers")
      ))
    )
  )
  cost_data <- cost$query_usage(query)
  if (is.null(cost_data$properties$rows) || length(cost_data$properties$rows) == 0)
    return(data.frame())
  cols <- length(cost_data$properties$columns)
  results <- do.call(rbind, lapply(cost_data$properties$rows, function(row) {
    data.frame(
      start       = format(dates$sd),
      end         = format(dates$ed),
      resource_id = row[[1]],
      cost        = as.numeric(row[[cols]]),
      currency    = cost_data$properties$columns[[cols]]$name,
      stringsAsFactors = FALSE
    )
  }))
  results$instance_name <- sapply(strsplit(results$resource_id, "/"), function(x) x[length(x)])
  results[, c("start","end","instance_name","cost","currency")]
}
