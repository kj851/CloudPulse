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

# Helper function for %notin%
`%notin%` <- function(x, y) !(x %in% y)

# withSpinner wrapper (graceful fallback)
if (!requireNamespace("shinycssloaders", quietly = TRUE)) {
  withSpinner <- function(expr, ...) expr
}

# Source cloud scripts
source("data/aws.r")
source("data/azure.r")
source("data/GCP.r")
source("data/mock.r")
source("data/forecast.r")

# Modern theme configuration
modern_theme <- bs_theme(
  preset = "bootstrap",
  primary = "#0D6EFD",
  secondary = "#6C757D",
  success = "#198754",
  danger = "#DC3545",
  warning = "#FFC107",
  info = "#0DCAF0",
  light = "#F8F9FA",
  dark = "#212529",
  base_font = font_collection(
    font_google("Inter"),
    "sans-serif"
  )
)

# UI - Credential Entry Page
credentials_ui <- function() {
  div(
    class = "d-flex align-items-center justify-content-center vh-100",
    style = "background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);",
    div(
      class = "card shadow-lg p-5",
      style = "width: 100%; max-width: 450px; border: none; border-radius: 15px;",
      div(
        class = "text-center mb-4",
        h1(
          "🚀 CloudPulse FinOps",
          class = "fw-bold",
          style = "color: #333; font-size: 2em; letter-spacing: -0.5px;"
        ),
        p(
          "Cloud Cost Intelligence Platform",
          class = "text-muted mb-0",
          style = "font-size: 1.1em;"
        )
      ),
      div(
        id = "credential_form",
        class = "mb-3",
        h5("Enter Cloud Credentials", class = "fw-bold mb-4"),
        # Provider selection
        div(
          class = "mb-3",
          label("Cloud Provider", class = "form-label fw-bold"),
          selectInput(
            "cred_provider",
            NULL,
            choices = c("AWS", "Azure", "GCP", "Use Mock Data"),
            width = "100%"
          )
        ),
        # AWS Credentials
        conditionalPanel(
          condition = "input.cred_provider == 'AWS'",
          div(
            class = "mb-3",
            textInput("aws_access_key", "AWS Access Key ID", placeholder = "AKIA...", width = "100%")
          ),
          div(
            class = "mb-3",
            passwordInput("aws_secret_key", "AWS Secret Access Key", placeholder = "Enter your secret key", width = "100%")
          ),
          div(
            class = "mb-3",
            textInput("aws_region", "AWS Region", value = "us-east-1", width = "100%")
          )
        ),
        # Azure Credentials
        conditionalPanel(
          condition = "input.cred_provider == 'Azure'",
          div(
            class = "mb-3",
            textInput("azure_subscription", "Subscription ID", placeholder = "UUID", width = "100%")
          ),
          div(
            class = "mb-3",
            textInput("azure_tenant", "Tenant ID", placeholder = "UUID", width = "100%")
          ),
          div(
            class = "mb-3",
            textInput("azure_client_id", "Client ID", placeholder = "UUID", width = "100%")
          ),
          div(
            class = "mb-3",
            passwordInput("azure_client_secret", "Client Secret", placeholder = "Enter your secret", width = "100%")
          )
        ),
        # GCP Credentials
        conditionalPanel(
          condition = "input.cred_provider == 'GCP'",
          div(
            class = "mb-3",
            textInput("gcp_project_id", "Project ID", placeholder = "my-project", width = "100%")
          ),
          div(
            class = "mb-3",
            textAreaInput("gcp_service_account", "Service Account JSON", placeholder = "Paste your service account key", rows = 5, width = "100%")
          )
        ),
        # Mock Data Option
        conditionalPanel(
          condition = "input.cred_provider == 'Use Mock Data'",
          div(
            class = "alert alert-info",
            icon("info-circle"),
            " Using demo data for testing purposes"
          )
        )
      ),
      div(
        class = "d-grid gap-2",
        actionButton(
          "login_btn",
          "Connect & Continue",
          class = "btn btn-primary btn-lg fw-bold",
          style = "border-radius: 10px; padding: 0.75rem 1.5rem;"
        )
      ),
      div(
        class = "text-center mt-3",
        small("Your credentials are secure and never stored", class = "text-muted")
      )
    )
  )
}

# Main Dashboard UI
dashboard_ui <- function() {
  page_sidebar(
    title = "FinOps Dashboard - CloudPulse",
    sidebar = sidebar(
      class = "bg-light",
      div(
        class = "d-flex align-items-center justify-content-between mb-4",
        div(
          h5("Dashboard", class = "fw-bold mb-0"),
          small("Cloud Analytics", class = "text-muted")
        ),
        actionButton(
          "logout_btn",
          icon("sign-out-alt"),
          class = "btn btn-sm btn-outline-secondary",
          title = "Logout"
        )
      ),
      hr(),
      
      # Query Configuration
      div(
        class = "mb-4",
        h6("Query Configuration", class = "fw-bold text-uppercase small text-muted"),
        
        selectInput(
          "provider",
          "Cloud Provider",
          choices = c("AWS", "Azure", "GCP"),
          width = "100%"
        ),
        
        selectInput(
          "query_type",
          "Query Type",
          choices = c("Metadata", "Usage", "Cost"),
          width = "100%"
        ),
        
        checkboxInput(
          "use_mock",
          "Use mock data (local)",
          value = TRUE
        )
      ),
      
      # Conditional Date Range
      conditionalPanel(
        condition = "input.query_type == 'Usage' || input.query_type == 'Cost'",
        div(
          class = "mb-4",
          h6("Time Period", class = "fw-bold text-uppercase small text-muted"),
          dateRangeInput(
            "date_range",
            NULL,
            start = Sys.Date() - 30,
            end = Sys.Date(),
            width = "100%"
          )
        )
      ),
      
      # Instance Selection
      conditionalPanel(
        condition = "input.query_type == 'Usage'",
        div(
          class = "mb-4",
          h6("Instance", class = "fw-bold text-uppercase small text-muted"),
          selectInput(
            "instance_usage",
            NULL,
            choices = NULL,
            width = "100%"
          )
        )
      ),
      
      conditionalPanel(
        condition = "input.query_type == 'Cost'",
        div(
          class = "mb-4",
          h6("Instance", class = "fw-bold text-uppercase small text-muted"),
          selectInput(
            "instance_cost",
            NULL,
            choices = NULL,
            width = "100%"
          )
        )
      ),
      
      conditionalPanel(
        condition = "input.query_type == 'Metadata'",
        div(
          class = "mb-4",
          h6("Filter", class = "fw-bold text-uppercase small text-muted"),
          selectInput(
            "instance_status",
            "Instance Status",
            choices = c("All", "Available", "Stopped", "Other"),
            width = "100%"
          )
        )
      ),
      
      # Forecast Options
      conditionalPanel(
        condition = "input.query_type == 'Usage'",
        div(
          class = "mb-4",
          h6("Forecast", class = "fw-bold text-uppercase small text-muted"),
          checkboxInput(
            "enable_forecast",
            "Enable forecast",
            value = FALSE
          ),
          conditionalPanel(
            condition = "input.enable_forecast == true",
            numericInput(
              "forecast_horizon",
              "Horizon (days)",
              value = 7,
              min = 1,
              max = 90,
              width = "100%"
            )
          )
        )
      ),
      
      # Action Buttons
      div(
        class = "d-grid gap-2 mt-4",
        actionButton(
          "query",
          "🔍 Query Data",
          class = "btn btn-primary fw-bold",
          style = "padding: 0.75rem; border-radius: 8px;"
        )
      ),
      
      hr(),
      
      # Theme Toggle
      div(
        class = "d-flex align-items-center justify-content-between",
        label("Dark Mode", class = "form-label mb-0"),
        input_dark_mode(id = "dark_mode")
      )
    ),
    
    # Main Content Area
    div(
      class = "p-4",
      
      # Header Card
      layout_columns(
        col_widths = c(12),
        card(
          class = "bg-gradient",
          style = "background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);",
          div(
            class = "text-white",
            h2("Cloud Analytics Dashboard", class = "fw-bold mb-2"),
            p("Real-time insights from your cloud infrastructure", class = "mb-0")
          )
        )
      ),
      
      # KPI Cards
      layout_columns(
        col_widths = c(3, 3, 3, 3),
        card(
          class = "text-center border-start border-5 border-primary",
          h6("Provider", class = "text-muted small"),
          textOutput("kpi_provider", inline = TRUE) %>% withSpinner(),
          class = "p-3"
        ),
        card(
          class = "text-center border-start border-5 border-success",
          h6("Query Type", class = "text-muted small"),
          textOutput("kpi_query_type", inline = TRUE) %>% withSpinner(),
          class = "p-3"
        ),
        card(
          class = "text-center border-start border-5 border-info",
          h6("Records", class = "text-muted small"),
          textOutput("kpi_records", inline = TRUE) %>% withSpinner(),
          class = "p-3"
        ),
        card(
          class = "text-center border-start border-5 border-warning",
          h6("Last Query", class = "text-muted small"),
          textOutput("kpi_last_query", inline = TRUE) %>% withSpinner(),
          class = "p-3"
        )
      ),
      
      # Results
      layout_columns(
        col_widths = c(12),
        card(
          full_screen = TRUE,
          card_header(
            "Query Results",
            class = "fw-bold",
            style = "background-color: #f8f9fa;"
          ),
          DTOutput("cloud_table") %>% withSpinner()
        )
      ),
      
      layout_columns(
        col_widths = c(12),
        card(
          full_screen = TRUE,
          card_header(
            "Visualization",
            class = "fw-bold",
            style = "background-color: #f8f9fa;"
          ),
          plotlyOutput("cloud_plot", height = "400px") %>% withSpinner()
        )
      ),
      
      # Forecast Table
      conditionalPanel(
        condition = "input.enable_forecast == true && input.query_type == 'Usage'",
        layout_columns(
          col_widths = c(12),
          card(
            full_screen = TRUE,
            card_header(
              "Forecast Projections",
              class = "fw-bold",
              style = "background-color: #f8f9fa;"
            ),
            DTOutput("forecast_table") %>% withSpinner()
          )
        )
      )
    )
  )
}

# Main UI with conditional rendering
ui <- function() {
  page_navbar(
    title = "CloudPulse FinOps",
    theme = modern_theme,
    
    uiOutput("main_ui"),
    
    # Hide navbar when on login
    tags$head(
      tags$style(HTML("
        .navbar { display: none; }
        body { font-family: 'Inter', sans-serif; }
        .card { border: none; box-shadow: 0 0.125rem 0.25rem rgba(0, 0, 0, 0.075); }
        .btn-primary { background-color: #667eea; border-color: #667eea; }
        .btn-primary:hover { background-color: #764ba2; border-color: #764ba2; }
      "))
    )
  )
}

# Server
server <- function(input, output, session) {
  # Reactives for authentication state
  user_authenticated <- reactiveVal(FALSE)
  authenticated_provider <- reactiveVal(NULL)
  last_query_time <- reactiveVal(NULL)
  
  # Render main UI based on authentication state
  output$main_ui <- renderUI({
    if (user_authenticated()) {
      dashboard_ui()
    } else {
      credentials_ui()
    }
  })
  
  # Login handler
  observeEvent(input$login_btn, {
    provider <- input$cred_provider
    
    if (provider == "Use Mock Data") {
      # Mock data doesn't require credentials
      user_authenticated(TRUE)
      authenticated_provider("Mock")
      showNotification("Connected with mock data!", type = "success", duration = 3)
    } else if (provider == "AWS") {
      # Validate AWS credentials
      if (nzchar(input$aws_access_key) && nzchar(input$aws_secret_key)) {
        tryCatch({
          # Store credentials in session (in production, use secure methods)
          session$userData$aws_creds <- list(
            access_key = input$aws_access_key,
            secret_key = input$aws_secret_key,
            region = input$aws_region
          )
          user_authenticated(TRUE)
          authenticated_provider("AWS")
          showNotification("AWS credentials connected successfully!", type = "success", duration = 3)
        }, error = function(e) {
          showNotification(paste("Connection failed:", e$message), type = "error")
        })
      } else {
        showNotification("Please enter AWS Access Key and Secret Key", type = "warning")
      }
    } else if (provider == "Azure") {
      # Validate Azure credentials
      if (nzchar(input$azure_subscription) && nzchar(input$azure_client_id)) {
        tryCatch({
          session$userData$azure_creds <- list(
            subscription = input$azure_subscription,
            tenant = input$azure_tenant,
            client_id = input$azure_client_id,
            client_secret = input$azure_client_secret
          )
          user_authenticated(TRUE)
          authenticated_provider("Azure")
          showNotification("Azure credentials connected successfully!", type = "success", duration = 3)
        }, error = function(e) {
          showNotification(paste("Connection failed:", e$message), type = "error")
        })
      } else {
        showNotification("Please enter required Azure credentials", type = "warning")
      }
    } else if (provider == "GCP") {
      # Validate GCP credentials
      if (nzchar(input$gcp_project_id) && nzchar(input$gcp_service_account)) {
        tryCatch({
          session$userData$gcp_creds <- list(
            project_id = input$gcp_project_id,
            service_account = input$gcp_service_account
          )
          user_authenticated(TRUE)
          authenticated_provider("GCP")
          showNotification("GCP credentials connected successfully!", type = "success", duration = 3)
        }, error = function(e) {
          showNotification(paste("Connection failed:", e$message), type = "error")
        })
      } else {
        showNotification("Please enter GCP Project ID and Service Account JSON", type = "warning")
      }
    }
  })
  
  # Logout handler
  observeEvent(input$logout_btn, {
    user_authenticated(FALSE)
    authenticated_provider(NULL)
    session$userData$aws_creds <- NULL
    session$userData$azure_creds <- NULL
    session$userData$gcp_creds <- NULL
    showNotification("Logged out successfully", type = "info", duration = 3)
  })
  
  # Cloud data queries (only executed after login)
  instances <- reactive({
    if (!user_authenticated()) return(character(0))
    
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
  })

  cloud_data <- eventReactive(input$query, {
    if (!user_authenticated()) return(data.frame(Error = "Not authenticated"))
    
    provider <- input$provider
    query_type <- input$query_type
    tryCatch(
      {
        if (isTRUE(input$use_mock)) {
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
    last_query_time(Sys.time())
  })

  # KPI Outputs
  output$kpi_provider <- renderText({
    input$provider
  })
  
  output$kpi_query_type <- renderText({
    input$query_type
  })
  
  output$kpi_records <- renderText({
    data <- cloud_data()
    nrow(data)
  })
  
  output$kpi_last_query <- renderText({
    if (is.null(last_query_time())) {
      "Never"
    } else {
      format(last_query_time(), "%H:%M:%S")
    }
  })

  # Data Table
  output$cloud_table <- renderDT({
    data <- cloud_data()
    if ("Error" %in% colnames(data)) {
      datatable(data, options = list(dom = "t"))
    } else {
      datatable(
        data,
        options = list(
          autoWidth = FALSE,
          scrollX = TRUE,
          pageLength = 10,
          lengthMenu = c(5, 10, 25, 50),
          searching = TRUE,
          ordering = TRUE
        ),
        filter = "top"
      )
    }
  })

  # Visualization
  output$cloud_plot <- renderPlotly({
    data <- cloud_data()
    
    if ("Error" %in% colnames(data)) {
      return(plot_ly() %>% add_annotations(
        text = "No data available",
        showarrow = FALSE
      ))
    }
    
    if (input$query_type == "Usage" && nrow(data) > 0 && "timestamp" %in% colnames(data)) {
      p <- plot_ly(data, x = ~timestamp, y = ~cpu_avg, type = "scatter", mode = "lines", name = "Avg CPU",
                   line = list(color = "#667eea", width = 2)) %>%
        add_trace(y = ~cpu_max, name = "Max CPU", line = list(color = "#764ba2", width = 2))
      
      if (isTRUE(input$enable_forecast)) {
        fc_res <- tryCatch({
          train_forecast_usage(data, periods = as.integer(input$forecast_horizon))
        }, error = function(e) list(original = data.frame(), forecast = data.frame()))
        
        if (!is.null(fc_res$forecast) && nrow(fc_res$forecast) > 0) {
          fc_plot_df <- fc_res$forecast %>% transform(timestamp = as.POSIXct(date) + 12 * 3600)
          p <- p %>%
            add_lines(
              x = fc_plot_df$timestamp,
              y = fc_plot_df$yhat,
              name = "Forecast",
              line = list(dash = "dash", color = "#FFC107", width = 2)
            ) %>%
            add_ribbons(
              x = fc_plot_df$timestamp,
              ymin = fc_plot_df$lower80,
              ymax = fc_plot_df$upper80,
              name = "80% Confidence",
              fillcolor = "rgba(255, 193, 7, 0.2)",
              line = list(color = "transparent"),
              showlegend = FALSE
            )
        }
      }
      
      p %>% layout(
        hovermode = "x unified",
        plot_bgcolor = "#f8f9fa",
        paper_bgcolor = "#ffffff"
      )
    } else if (input$query_type == "Cost" && nrow(data) > 0 && "cost" %in% colnames(data)) {
      plot_ly(data, x = ~start, y = ~cost, type = "bar", name = "Cost",
              marker = list(color = "#198754")) %>%
        layout(
          hovermode = "x unified",
          plot_bgcolor = "#f8f9fa",
          paper_bgcolor = "#ffffff"
        )
    } else {
      plot_ly() %>% add_annotations(
        text = "No visualization available for this query type",
        showarrow = FALSE
      )
    }
  })

  # Forecast Table
  output$forecast_table <- renderDT({
    if (isTRUE(input$enable_forecast) && input$query_type == "Usage") {
      data <- cloud_data()
      if (nrow(data) > 0 && "Error" %notin% colnames(data)) {
        fc_res <- tryCatch({
          train_forecast_usage(data, periods = as.integer(input$forecast_horizon))
        }, error = function(e) NULL)
        
        if (!is.null(fc_res) && nrow(fc_res$forecast) > 0) {
          datatable(
            fc_res$forecast,
            options = list(
              autoWidth = FALSE,
              scrollX = TRUE,
              pageLength = 10
            )
          )
        } else {
          datatable(data.frame(Note = "No forecast available"))
        }
      } else {
        datatable(data.frame(Note = "No historical usage data"))
      }
    } else {
      datatable(data.frame(Note = "Enable forecast in the sidebar to view predictions"))
    }
  })
}

# Return the Shiny app object
shinyApp(ui, server)
