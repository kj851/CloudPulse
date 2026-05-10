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
# for async
if (requireNamespace("future", quietly = TRUE)) {
  # use multisession backend for non-blocking futures in Shiny
  future::plan(future::multisession)
} else {
  message("'future' package not available; async futures disabled. Install 'future' to enable.")
}

# Source cloud scripts
source("data/aws.r")
source("data/azure.r")
source("data/GCP.r")
source("data/mock.r")
source("data/forecast.r")

# UI
ui <- page_sidebar(
  title = "FinOps Dashboard",
  sidebar = sidebar(
    selectInput("provider", "Cloud Provider", choices = c("AWS", "Azure", "GCP")),
    selectInput("query_type", "Query Type", choices = c("Metadata", "Usage", "Cost")),
    # for testing with mock data, allow bypassing credential checks and real cloud queries
    checkboxInput("use_mock", "Use mock data (local)", value = TRUE),
    conditionalPanel(
      condition = "input.query_type == 'Usage' || input$query_type == 'Cost'",
      dateRangeInput("date_range", "Date Range", start = Sys.Date() - 30, end = Sys.Date())
    ),
    conditionalPanel(
      condition = "input.query_type == 'Usage'",
      selectInput("instance_usage", "Instance", choices = NULL),
      # forecast controls
      checkboxInput("enable_forecast", "Enable forecast", value = FALSE),
      conditionalPanel(
        condition = "input.enable_forecast == true",
        numericInput("forecast_horizon", "Forecast horizon (days)", value = 7, min = 1, max = 90)
      )
    ),
    conditionalPanel(
      condition = "input$query_type == 'Cost'",
      selectInput("instance_cost", "Instance", choices = NULL)
    ),
    conditionalPanel(
      default = TRUE,
      condition = "input.query_type == 'Metadata'",
      selectInput("instance_status", "Instance Status", choices = c("All", "Available", "Stopped", "Other"))
    ),
    actionButton("query", "Query Data"),
    input_dark_mode(id = "dark_mode")
  ),
  card(
    full_screen = TRUE,
    card_header("Cloud Data Query Results"),
    DTOutput("cloud_table"),
    plotlyOutput("cloud_plot"),
    DTOutput("forecast_table")
  ),
  theme = bs_theme(bootswatch = "flatly")
)

# Server
server <- function(input, output, session) {
  # Cloud data
  instances <- reactive({
    provider <- input$provider
    tryCatch(
      {
        if (isTRUE(input$use_mock)) {
          get_mock_instances(provider)
        } else {
          if (provider == "AWS") {
            meta <- aws_rds_instances_metadata()
            meta$identifier
          } else if (provider == "Azure") {
            meta <- azure_db_instances_metadata()
            meta$name
          } else if (provider == "GCP") {
            meta <- gcp_db_instances_metadata()
            meta$name
          }
        }
      },
      error = function(e) character(0)
    )
  })

  observe({
    updateSelectInput(session, "instance_usage", choices = instances())
    updateSelectInput(session, "instance_cost", choices = instances())
    # instance_status has fixed choices; do not overwrite them here
  })

  cloud_data <- eventReactive(input$query, {
    provider <- input$provider
    query_type <- input$query_type
    tryCatch(
      {
        if (isTRUE(input$use_mock)) {
          # mock paths
          if (query_type == "Metadata") {
            get_mock_metadata(provider)
          } else if (query_type == "Usage") {
            instance <- input$instance_usage
            get_mock_usage(provider, instance)
          } else if (query_type == "Cost") {
            start_date <- format(input$date_range[1], "%Y-%m-%d")
            end_date <- format(input$date_range[2], "%Y-%m-%d")
            get_mock_cost(start_date, end_date)
          }
        } else {
          # real cloud paths (existing code)
          if (query_type == "Metadata") {
            if (provider == "AWS") {
              aws_rds_instances_metadata()
            } else if (provider == "Azure") {
              azure_db_instances_metadata()
            } else if (provider == "GCP") {
              gcp_db_instances_metadata()
            }
          } else if (query_type == "Usage") {
            instance <- input$instance_usage
            if (provider == "AWS") {
              aws_rds_instance_usage(instance)
            } else if (provider == "Azure") {
              azure_db_instance_usage(instance)
            } else if (provider == "GCP") {
              gcp_db_instance_usage(instance)
            }
          } else if (query_type == "Cost") {
            start_date <- format(input$date_range[1], "%Y-%m-%d")
            end_date <- format(input$date_range[2], "%Y-%m-%d")
            if (provider == "AWS") {
              aws_rds_cost_by_instance(start_date, end_date)
            } else if (provider == "Azure") {
              azure_db_cost_by_instance(start_date, end_date)
            } else if (provider == "GCP") {
              gcp_db_cost_by_instance(start_date, end_date)
            }
          }
        }
      },
      error = function(e) data.frame(Error = e$message)
    )
  })

  output$cloud_table <- renderDT({
    datatable(cloud_data())
  })

  output$cloud_plot <- renderPlotly({
    data <- cloud_data()
    if (input$query_type == "Usage" && nrow(data) > 0 && "timestamp" %in% colnames(data)) {
      p <- plot_ly(data, x = ~timestamp, y = ~cpu_avg, type = "scatter", mode = "lines", name = "Avg CPU") |>
        add_trace(y = ~cpu_max, name = "Max CPU")
      # overlay forecast if enabled
      if (isTRUE(input$enable_forecast)) {
        fc_res <- tryCatch(
          {
            train_forecast_usage(data, periods = as.integer(input$forecast_horizon))
          },
          error = function(e) list(original = data.frame(), forecast = data.frame())
        )
        if (!is.null(fc_res$forecast) && nrow(fc_res$forecast) > 0) {
          # convert forecast dates to POSIXct for plotting at midday
          fc_plot_df <- fc_res$forecast |> transform(timestamp = as.POSIXct(date) + 12 * 3600)
          p <- p |>
            add_lines(
              x = fc_plot_df$timestamp,
              y = fc_plot_df$yhat,
              name = "Forecast (mean)",
              line = list(dash = "dash", color = "orange")
            ) |>
            add_ribbons(
              x = fc_plot_df$timestamp,
              ymin = fc_plot_df$lower80,
              ymax = fc_plot_df$upper80,
              name = "80% CI",
              fillcolor = "rgba(255,165,0,0.2)",
              line = list(color = "transparent"),
              showlegend = FALSE
            )
        }
      }
      p
    } else if (input$query_type == "Cost" && nrow(data) > 0 && "cost" %in% colnames(data)) {
      plot_ly(data, x = ~start, y = ~cost, type = "bar", name = "Cost")
    } else {
      plot_ly() |> add_annotations(text = "No plot available for this query type or no data", showarrow = FALSE)
    }
  })

  # new forecast table output
  output$forecast_table <- renderDT({
    if (isTRUE(input$enable_forecast) && input$query_type == "Usage") {
      data <- cloud_data()
      if (nrow(data) > 0) {
        fc_res <- tryCatch(train_forecast_usage(data, periods = as.integer(input$forecast_horizon)), error = function(e) NULL)
        if (!is.null(fc_res) && nrow(fc_res$forecast) > 0) {
          datatable(fc_res$forecast)
        } else {
          datatable(data.frame(Note = "No forecast available"))
        }
      } else {
        datatable(data.frame(Note = "No historical usage data"))
      }
    } else {
      datatable(data.frame(Note = "Forecast disabled"))
    }
  })
}

# Return the Shiny app object
shinyApp(ui, server)
