# CloudPulse Login UI Module
# Provides user login interface and authentication
library(shiny)
library(bslib)
library(DT)

source("auth.R")

# ══════════════════════════════════════════════════════════════════════════════
# LOGIN UI
# ══════════════════════════════════════════════════════════════════════════════

#' Login page UI
login_ui <- function() {
  div(
    class = "d-flex align-items-center justify-content-center min-vh-100 py-5",
    style = "background: linear-gradient(135deg, #0D1F3C 0%, #1a3a5c 50%, #0D1F3C 100%);",

    div(
      style = "width: 100%; max-width: 500px; padding: 0 1rem;",

      # Header with logo
      div(class = "text-center mb-5",
        tags$img(
          src = "logo.png", height = "80px",
          onerror = "this.style.display='none'",
          style = "margin-bottom: 1rem;"
        ),
        h1("CloudPulse", class = "fw-bold text-white mb-2",
           style = "font-size: 2.5em;"),
        p("FinOps & Infrastructure Platform",
          class = "text-light",
          style = "font-size: 1.1em; opacity: 0.9;")
      ),

      # Login card
      div(class = "card shadow-lg p-4",
        style = "border: none; border-radius: 16px; background: rgba(255,255,255,0.98);",

        h5("Sign In to Your Account", class = "fw-bold mb-4 text-dark"),

        # Username input
        div(class = "mb-3",
          div(class = "form-floating",
            textInput("login_username", NULL,
              placeholder = "Enter username"
            ),
            tags$label("Username", `for` = "login_username"),
            tags$style(HTML("
              #login_username {
                border-radius: 8px;
                border: 1px solid #dee2e6;
                font-size: 1.125rem;
                padding: 0.75rem 0.75rem 0.75rem 0.75rem;
              }
            "))
          )
        ),

        # Password input
        div(class = "mb-3",
          div(class = "form-floating",
            passwordInput("login_password", NULL,
              placeholder = "Enter password"
            ),
            tags$label("Password", `for` = "login_password"),
            tags$style(HTML("
              #login_password {
                border-radius: 8px;
                border: 1px solid #dee2e6;
                font-size: 1.125rem;
                padding: 0.75rem 0.75rem 0.75rem 0.75rem;
              }
            "))
          )
        ),

        # Remember me checkbox
        div(class = "form-check mb-4",
          checkboxInput("login_remember", "Remember me", value = FALSE),
          tags$label("Remember me", `for` = "login_remember",
            class = "form-check-label"
          )
        ),

        # Error message
        uiOutput("login_error_message"),

        # Login button
        actionButton("login_button", "Sign In",
          class = "btn btn-primary btn-lg w-100",
          style = "border-radius: 8px; font-weight: 600; padding: 0.75rem;",
          disabled = FALSE
        ),

        # Divider
        hr(class = "my-4"),

        # Demo credentials (development only)
        tags$details(
          summary = span(
            "Demo Credentials (Development)",
            style = "cursor: pointer; color: #0D6EFD; font-weight: 500; font-size: 0.9em;"
          ),
          style = "margin-top: 1rem;",

          div(class = "mt-3",
            h6("Admin", class = "fw-bold"),
            code("Username: admin"), br(),
            code("Password: admin_password"), br(),

            h6("FinOps Analyst", class = "fw-bold mt-2"),
            code("Username: analyst"), br(),
            code("Password: analyst_password"), br(),

            h6("DevOps Engineer", class = "fw-bold mt-2"),
            code("Username: devops"), br(),
            code("Password: devops_password"), br(),

            h6("Viewer", class = "fw-bold mt-2"),
            code("Username: viewer"), br(),
            code("Password: viewer_password"), br(),

            div(class = "alert alert-info small mt-3",
              "In production, demo credentials are 
              disabled and a proper user database is required."
            )
          )
        )
      ),

      # Footer
      div(class = "text-center mt-4",
        p(class = "text-light small",
          "CloudPulse © 2026 | ",
          "Enterprise Multi-Cloud FinOps Solution"
        )
      )
    )
  )
}

#' Role badge UI
role_badge <- function(role) {
  role_colors <- list(
    admin = "#DC3545",
    finops_analyst = "#0DCAF0",
    devops_engineer = "#FFC107",
    viewer = "#6C757D"
  )

  role_labels <- list(
    admin = "Administrator",
    finops_analyst = "FinOps Analyst",
    devops_engineer = "DevOps Engineer",
    viewer = "Viewer"
  )

  color <- role_colors[[role]] %||% "#6C757D"
  label <- role_labels[[role]] %||% role

  span(
    label,
    class = "badge",
    style = paste0("background-color: ", color, "; margin-left: 0.5rem;")
  )
}

#' User info header (shown when authenticated)
user_info_header <- function(user_data) {
  div(class = "d-flex justify-content-between align-items-center mb-3 pb-3 border-bottom",
    div(
      h6(user_data$display_name %||% user_data$username,
        class = "mb-0 fw-bold"
      ),
      tags$small(user_data$email %||% user_data$username, class = "text-muted")
    ),
    div(
      role_badge(user_data$role),
      actionButton("logout_button", "Logout",
        class = "btn btn-sm btn-outline-danger ms-2",
        style = "border-radius: 6px;"
      )
    )
  )
}

check_rate_limit <- function(login_attempts, last_attempt_time) {
  max_attempts <- 5L
  lockout_duration <- 15 * 60

  if (is.null(last_attempt_time)) {
    return(list(locked = FALSE, attempts = login_attempts))
  }

  time_since_last <- as.numeric(difftime(Sys.time(), last_attempt_time, units = "secs"))

  if (time_since_last > lockout_duration) {
    return(list(locked = FALSE, attempts = 0L))
  }

  locked <- login_attempts >= max_attempts
  return(list(locked = locked, attempts = login_attempts))
}

# ══════════════════════════════════════════════════════════════════════════════
# LOGIN SERVER LOGIC (to be used in main server)
# ══════════════════════════════════════════════════════════════════════════════

#' Setup login server logic (call this in main server function)
setup_login_server <- function(input, output, session, user_authenticated,
                               current_user_data, login_attempts_rv,
                               last_attempt_time_rv) {

  # Track failed login attempts
  observeEvent(input$login_button, {
    req(input$login_username, input$login_password)

    # Check rate limit
    rate_status <- check_rate_limit(login_attempts_rv(), last_attempt_time_rv())

    if (rate_status$locked) {
      remaining <- remaining_lockout(last_attempt_time_rv())
      output$login_error_message <- renderUI({
        div(class = "alert alert-danger alert-dismissible fade show mb-3",
          h6("Account Locked", class = "alert-heading mb-2 fw-bold"),
          p(sprintf("Too many failed attempts. Try again in %d seconds.",
            ceiling(remaining)
          )),
          tags$button(type = "button", class = "btn-close",
            `data-bs-dismiss` = "alert", `aria-label` = "Close"
          )
        )
      })
      return()
    }

    # Attempt authentication
    result <- authenticate_user(
      input$login_username,
      input$login_password,
      db_path = NULL  # Use demo users (NULL) or specify db_path for production
    )

    if (result$success) {
      # Authentication successful
      user_authenticated(TRUE)
      current_user_data(result)
      login_attempts_rv(0L)
      last_attempt_time_rv(NULL)
      output$login_error_message <- renderUI(NULL)

      showNotification(
        paste0("Welcome, ", result$display_name, "!"),
        type = "message", duration = 5
      )
    } else {
      # Authentication failed
      login_attempts_rv(rate_status$attempts + 1L)
      last_attempt_time_rv(Sys.time())

      output$login_error_message <- renderUI({
        div(class = "alert alert-danger alert-dismissible fade show mb-3",
          h6("Login Failed", class = "alert-heading mb-2 fw-bold"),
          p(result$error %||% "Invalid credentials. Please try again."),
          tags$button(type = "button", class = "btn-close",
            `data-bs-dismiss` = "alert", `aria-label` = "Close"
          )
        )
      })
    }
  })

  # Logout
  observeEvent(input$logout_button, {
    user_authenticated(FALSE)
    current_user_data(NULL)
    login_attempts_rv(0L)
    last_attempt_time_rv(NULL)

    showNotification("You have been logged out.",
      type = "message", duration = 5
    )
  })
}
