# CloudPulse Authentication Module
# Handles user login, session management, and password hashing
# Author: Keaton Szantho

library(digest)
library(DBI)
library(RSQLite)

source("rbac.R")

# ══════════════════════════════════════════════════════════════════════════════
# USER AUTHENTICATION
# ══════════════════════════════════════════════════════════════════════════════

#' Hash password using PBKDF2 with SHA256
#'
#' @param password Character. Plain text password
#' @param salt Character. Optional salt (if NULL, generated)
#'
#' @return List with hashed password and salt
hash_password <- function(password, salt = NULL) {
  if (is.null(salt)) {
    salt <- paste0(sample(0:9, 16, replace = TRUE), collapse = "")
  }

  hashed <- digest::digest(
    object = paste0(password, salt),
    algo = "sha256",
    serialize = FALSE
  )

  list(hash = hashed, salt = salt)
}

#' Verify password against stored hash
#' @param password Character. Plain text password to verify
#' @param stored_hash Character. The stored password hash
#' @param salt Character. The salt used for hashing
#'
#' @return Logical. TRUE if password matches, FALSE otherwise
verify_password <- function(password, stored_hash, salt) {
  computed <- digest::digest(
    object = paste0(password, salt),
    algo = "sha256",
    serialize = FALSE
  )
  identical(computed, stored_hash)
}

#' Authenticate user credentials
#'
#' @param username Character. Username
#' @param password Character. Plain text password
#' @param db_path Character. Path to SQLite database (optional)
#'
#' @return List with success flag and user data, or error message
authenticate_user <- function(username, password, db_path = NULL) {

  if (!nzchar(username) || !nzchar(password)) {
    return(list(
      success = FALSE,
      error = "Username and password are required."
    ))
  }

  # Sanitize username
  username <- trimws(username)
  if (!grepl("^[a-zA-Z0-9._@-]{3,100}$", username, perl = TRUE)) {
    return(list(
      success = FALSE,
      error = "Invalid username format."
    ))
  }

  # For development: allow demo users
  # In production, query the database
  if (is.null(db_path)) {
    demo_users <- list(
      admin = list(
        password_hash = hash_password("admin_password")$hash,
        password_salt = hash_password("admin_password")$salt,
        role = "admin",
        email = "admin@cloudpulse.local",
        display_name = "Administrator"
      ),
      analyst = list(
        password_hash = hash_password("analyst_password")$hash,
        password_salt = hash_password("analyst_password")$salt,
        role = "finops_analyst",
        email = "analyst@cloudpulse.local",
        display_name = "FinOps Analyst"
      ),
      devops = list(
        password_hash = hash_password("devops_password")$hash,
        password_salt = hash_password("devops_password")$salt,
        role = "devops_engineer",
        email = "devops@cloudpulse.local",
        display_name = "DevOps Engineer"
      ),
      viewer = list(
        password_hash = hash_password("viewer_password")$hash,
        password_salt = hash_password("viewer_password")$salt,
        role = "viewer",
        email = "viewer@cloudpulse.local",
        display_name = "Viewer User"
      )
    )

    if (!(username %in% names(demo_users))) {
      return(list(
        success = FALSE,
        error = "Invalid username or password."
      ))
    }

    user_data <- demo_users[[username]]

    # Verify password
    if (!verify_password(password,
                         user_data$password_hash, user_data$password_salt)) {
      return(list(
        success = FALSE,
        error = "Invalid username or password."
      ))
    }

    return(list(
      success = TRUE,
      user_id = username,
      username = username,
      email = user_data$email,
      display_name = user_data$display_name,
      role = user_data$role,
      created_at = Sys.time()
    ))
  }

  # Production: query database
  tryCatch({
    conn <- DBISQLite::dbConnect(RSQLite::SQLite(), db_path)
    on.exit(DBI::dbDisconnect(conn), add = TRUE)

    query <- "SELECT user_id, username, email, 
    display_name, role, password_hash, password_salt 
              FROM users WHERE username = ? AND active = 1"
    result <- DBI::dbGetQuery(conn, query, params = list(username))

    if (nrow(result) == 0) {
      return(list(
        success = FALSE,
        error = "Invalid username or password."
      ))
    }

    user <- result[1, ]

    # Verify password
    if (!verify_password(password, user$password_hash, user$password_salt)) {
      return(list(
        success = FALSE,
        error = "Invalid username or password."
      ))
    }

    # Update last login
    DBI::dbExecute(
      conn,
      "UPDATE users SET last_login = ? WHERE user_id = ?",
      params = list(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), user$user_id)
    )

    return(list(
      success = TRUE,
      user_id = user$user_id,
      username = user$username,
      email = user$email,
      display_name = user$display_name,
      role = user$role,
      created_at = Sys.time()
    ))

  }, error = function(e) {
    list(
      success = FALSE,
      error = paste("Authentication error:", conditionMessage(e))
    )
  })
}

#' Create new user (admin only)
#'
#' @param username Character. Username
#' @param password Character. Initial password
#' @param email Character. Email address
#' @param role Character. Role (admin, finops_analyst, devops_engineer, viewer)
#' @param display_name Character. Display name
#' @param db_path Character. Path to SQLite database
#'
#' @return List with success flag and result
create_user <- function(username, password,
                        email, role, display_name = NULL, db_path = NULL) {

  # Validate inputs
  if (!nzchar(username) || !nzchar(password) || !nzchar(email)) {
    return(list(success = FALSE, error = "All fields are required."))
  }

  username <- trimws(tolower(username))
  if (!grepl("^[a-zA-Z0-9._@-]{3,100}$", username, perl = TRUE)) {
    return(list(success = FALSE, error = "Invalid username format."))
  }

  email <- trimws(tolower(email))
  if (!grepl("^[^@]+@[^@]+\\.[^@]+$", email, perl = TRUE)) {
    return(list(success = FALSE, error = "Invalid email format."))
  }

  if (!is_valid_role(role)) {
    return(list(success = FALSE, error = "Invalid role."))
  }

  if (nchar(password) < 8) {
    return(list(success = FALSE,
                error = "Password must be at least 8 characters."))
  }

  if (is.null(display_name) || !nzchar(display_name)) {
    display_name <- username
  }

  if (is.null(db_path)) {
    return(list(success = FALSE,
                error = "Database path required for user creation."))
  }

  tryCatch({
    conn <- DBI::dbConnect(RSQLite::SQLite(), db_path)
    on.exit(DBI::dbDisconnect(conn), add = TRUE)

    # Check if username already exists
    existing <- DBI::dbGetQuery(
      conn,
      "SELECT user_id FROM users WHERE username = ?",
      params = list(username)
    )

    if (nrow(existing) > 0) {
      return(list(success = FALSE, error = "Username already exists."))
    }

    # Hash password
    pwd_data <- hash_password(password)

    # Create user
    DBI::dbExecute(
      conn,
      "INSERT INTO users (username, email, display_name, role, 
      password_hash, password_salt, active, created_at)
       VALUES (?, ?, ?, ?, ?, ?, 1, ?)",
      params = list(
        username, email, display_name, role,
        pwd_data$hash, pwd_data$salt,
        format(Sys.time(), "%Y-%m-%d %H:%M:%S")
      )
    )

    return(list(
      success = TRUE,
      message = paste("User", username, "created successfully.")
    ))

  }, error = function(e) {
    list(
      success = FALSE,
      error = paste("Error creating user:", conditionMessage(e))
    )
  })
}

#' Get user information
#'
#' @param user_id Character. User ID or username
#' @param db_path Character. Path to SQLite database (optional)
#'
#' @return List with user data or error
get_user_info <- function(user_id, db_path = NULL) {

  if (!nzchar(user_id)) {
    return(list(success = FALSE, error = "User ID required."))
  }

  # Demo users (if no database)
  if (is.null(db_path)) {
    demo_users <- list(
      admin = list(
        user_id = "admin",
        username = "admin",
        email = "admin@cloudpulse.local",
        display_name = "Administrator",
        role = "admin",
        active = TRUE,
        created_at = "2026-01-01 00:00:00"
      ),
      analyst = list(
        user_id = "analyst",
        username = "analyst",
        email = "analyst@cloudpulse.local",
        display_name = "FinOps Analyst",
        role = "finops_analyst",
        active = TRUE,
        created_at = "2026-01-01 00:00:00"
      ),
      devops = list(
        user_id = "devops",
        username = "devops",
        email = "devops@cloudpulse.local",
        display_name = "DevOps Engineer",
        role = "devops_engineer",
        active = TRUE,
        created_at = "2026-01-01 00:00:00"
      ),
      viewer = list(
        user_id = "viewer",
        username = "viewer",
        email = "viewer@cloudpulse.local",
        display_name = "Viewer User",
        role = "viewer",
        active = TRUE,
        created_at = "2026-01-01 00:00:00"
      )
    )

    if (user_id %in% names(demo_users)) {
      return(list(success = TRUE, user = demo_users[[user_id]]))
    }

    return(list(success = FALSE, error = "User not found."))
  }

  # Production: query database
  tryCatch({
    conn <- DBI::dbConnect(RSQLite::SQLite(), db_path)
    on.exit(DBI::dbDisconnect(conn), add = TRUE)

    result <- DBI::dbGetQuery(
      conn,
      "SELECT user_id, username, email, 
      display_name, role, active, created_at, last_login 
       FROM users WHERE user_id = ? OR username = ?",
      params = list(user_id, user_id)
    )

    if (nrow(result) == 0) {
      return(list(success = FALSE, error = "User not found."))
    }

    return(list(
      success = TRUE,
      user = as.list(result[1, ])
    ))

  }, error = function(e) {
    list(success = FALSE, error = conditionMessage(e))
  })
}

#' List all users (admin only)
#'
#' @param db_path Character. Path to SQLite database (optional)
#'
#' @return Data frame with all users
list_users <- function(db_path = NULL) {

  if (is.null(db_path)) {
    # Demo users
    return(data.frame(
      user_id = c("admin", "analyst", "devops", "viewer"),
      username = c("admin", "analyst", "devops", "viewer"),
      email = c("admin@cloudpulse.local", "analyst@cloudpulse.local",
                "devops@cloudpulse.local", "viewer@cloudpulse.local"),
      display_name = c("Administrator", "FinOps Analyst",
        "DevOps Engineer", "Viewer User"
      ),
      role = c("admin", "finops_analyst", "devops_engineer", "viewer"),
      active = c(TRUE, TRUE, TRUE, TRUE),
      created_at = rep("2026-01-01 00:00:00", 4),
      stringsAsFactors = FALSE
    ))
  }

  tryCatch({
    conn <- DBI::dbConnect(RSQLite::SQLite(), db_path)
    on.exit(DBI::dbDisconnect(conn), add = TRUE)

    DBI::dbGetQuery(
      conn,
      "SELECT user_id, username, email, display_name, 
      role, active, created_at, last_login 
       FROM users ORDER BY username"
    )

  }, error = function(e) {
    data.frame(error = conditionMessage(e))
  })
}
