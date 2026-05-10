# Azure data access and processing functions for Shiny app
# with security validation and error handling
# Connect to Azure SQL Database, retrieve metadata, usage, and cost data

library(shiny)
library(DBI)
library(RPostgres)
library(AzureRMR)
library(AzureAuth)
library(AzureStor)
library(keyring)
library(httr)
library(jsonlite)

azure_creds <- function() {
  creds <- list(
    tenant_id = key_get(service = "azure", username = "tenant_id"),
    client_id = key_get(service = "azure", username = "client_id"),
    client_secret = key_get(service = "azure", username = "client_secret"),
    subscription_id = key_get(service = "azure", username = "subscription_id"),
    resource_group = key_get(service = "azure", username = "resource_group"),
    db_host = key_get(service = "azure_db", username = "host"),
    db_port = tryCatch(as.integer(key_get(service = "azure_db", username = "port")), error = function(e) 5432),
    db_name = key_get(service = "azure_db", username = "name"),
    db_user = key_get(service = "azure_db", username = "user"),
    db_password = key_get(service = "azure_db", username = "password")
  )

  required_azure <- c("tenant_id", "client_id", "client_secret", "subscription_id")
  missing_azure <- required_azure[sapply(creds[required_azure], function(x) is.null(x) || x == "")]
  if (length(missing_azure) > 0) {
    stop("Missing required Azure credentials: ", paste(missing_azure, collapse = ", "))
  }

  required_db <- c("db_host", "db_name", "db_user", "db_password")
  missing_db <- required_db[sapply(creds[required_db], function(x) is.null(x) || x == "")]
  if (length(missing_db) > 0) {
    stop("Missing required Azure DB credentials: ", paste(missing_db, collapse = ", "))
  }

  creds
}

azure_db_conn <- function(creds = azure_creds()) {
  dbConnect(
    RPostgres::Postgres(),
    host = creds$db_host,
    port = creds$db_port,
    dbname = creds$db_name,
    user = creds$db_user,
    password = creds$db_password
  )
}

azure_db_query <- function(sql, creds = azure_creds()) {
  conn <- azure_db_conn(creds)
  on.exit(dbDisconnect(conn), add = TRUE)
  dbGetQuery(conn, sql)
}

azure_data_server <- function(id, sql) {
  moduleServer(id, function(input, output, session) {
    data <- reactive({
      azure_db_query(sql)
    })
    data
  })
}

azure_db_instances_metadata <- function(creds = azure_creds()) {
  az <- az_rm$new(
    tenant = creds$tenant_id,
    app = creds$client_id,
    password = creds$client_secret
  )
  sub <- az$get_subscription(creds$subscription_id)

  # List PostgreSQL servers (assuming flexible servers)
  servers <- sub$list_resources(
    filter = "resourceType eq 'Microsoft.DBforPostgreSQL/flexibleServers'"
  )

  if (length(servers) == 0) {
    return(data.frame())
  }

  metadata <- do.call(rbind, lapply(servers, function(server) {
    data.frame(
      name = server$name,
      location = server$location,
      sku_name = server$sku$name,
      sku_tier = server$sku$tier,
      storage_mb = server$properties$storage$storageSizeMB,
      version = server$properties$version,
      state = server$properties$state,
      fully_qualified_domain_name = server$properties$fullyQualifiedDomainName
    )
  }))
  metadata
}

azure_db_instance_usage <- function(server_name, creds = azure_creds()) {
  az <- az_rm$new(
    tenant = creds$tenant_id,
    app = creds$client_id,
    password = creds$client_secret
  )
  sub <- az$get_subscription(creds$subscription_id)

  # Get monitor client
  mon <- sub$get_monitor_client()

  query <- list(
    metricnames = "cpu_percent",
    aggregation = "Average,Maximum",
    interval = "PT1H",
    timespan = paste0(format(Sys.time() - 7 * 86400, "%Y-%m-%dT%H:%M:%SZ"), "/", format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")),
    filter = paste0("Microsoft.DBforPostgreSQL/flexibleServers/", server_name)
  )

  metrics <- mon$get_metrics(
    resource_id = paste0("/subscriptions/", creds$subscription_id, "/resourceGroups/", creds$resource_group, "/providers/Microsoft.DBforPostgreSQL/flexibleServers/", server_name),
    metricnames = "cpu_percent",
    aggregation = "Average,Maximum",
    interval = "PT1H",
    timespan = paste0(format(Sys.time() - 7 * 86400, "%Y-%m-%dT%H:%M:%SZ"), "/", format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ"))
  )

  if (length(metrics$value) == 0 || length(metrics$value[[1]]$timeseries) == 0) {
    return(data.frame())
  }

  usage <- do.call(rbind, lapply(metrics$value[[1]]$timeseries[[1]]$data, function(dp) {
    data.frame(
      timestamp = as.POSIXct(dp$timeStamp),
      cpu_avg = dp$average,
      cpu_max = dp$maximum
    )
  }))
  usage <- usage[order(usage$timestamp), ]
  usage
}

azure_db_cost_by_instance <- function(start_date, end_date, creds = azure_creds()) {
  az <- az_rm$new(
    tenant = creds$tenant_id,
    app = creds$client_id,
    password = creds$client_secret
  )
  sub <- az$get_subscription(creds$subscription_id)

  # Get cost management client
  cost <- sub$get_cost_management_client()

  # Query cost
  query <- list(
    type = "ActualCost",
    timeframe = "Custom",
    timePeriod = list(
      from = start_date,
      to = end_date
    ),
    dataset = list(
      granularity = "Monthly",
      aggregation = list(
        totalCost = list(
          name = "Cost",
          `function` = "Sum" # use backticks for reserved word
        )
      ),
      grouping = list(
        list(
          type = "Dimension",
          name = "ResourceId"
        )
      ),
      filter = list(
        dimensions = list(
          name = "ResourceType",
          operator = "In",
          values = list("microsoft.dbforpostgresql/flexibleservers")
        )
      )
    )
  )

  cost_data <- cost$query_usage(query)

  # Process results
  if (is.null(cost_data$properties$rows) || length(cost_data$properties$rows) == 0) {
    return(data.frame())
  }

  results <- do.call(rbind, lapply(cost_data$properties$rows, function(row) {
    data.frame(
      start = start_date,
      end = end_date,
      resource_id = row[[1]], # ResourceId
      cost = as.numeric(row[[length(row)]]), # Cost
      currency = cost_data$properties$columns[[length(cost_data$properties$columns)]]$name
    )
  }))

  # Extract server name from resource_id
  results$instance_name <- sapply(strsplit(results$resource_id, "/"), function(x) x[length(x)])

  results[, c("start", "end", "instance_name", "cost", "currency")]
  }
