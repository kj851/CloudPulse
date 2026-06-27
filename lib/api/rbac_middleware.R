# CloudPulse API RBAC Middleware
# Enforces role-based access control on API endpoints
# Author: Keaton Szantho

source("rbac.R")
source("auth.R")

# ══════════════════════════════════════════════════════════════════════════════
# API AUTHENTICATION & AUTHORIZATION
# ══════════════════════════════════════════════════════════════════════════════

#' Authenticate API request via JWT token or API key
#' 
#' @param req The request object (from Plumber)
#' @param res The response object (from Plumber)
#' 
#' @return List with success flag and user data, or error response
authenticate_api_request <- function(req, res) {

  # Try to get token from Authorization header
  auth_header <- req$HTTP_AUTHORIZATION %||% ""
  api_key <- req$HTTP_X_API_KEY %||% ""

  if (grepl("^Bearer ", auth_header)) {
    # JWT token authentication
    token <- sub("^Bearer ", "", auth_header)
    # In production, validate JWT token here
    # For now, return structured user data
    return(list(
      success = TRUE,
      user_id = "demo_user",
      role = "admin",  # Should be extracted from token
      token = token
    ))
  }
  
  if (nzchar(api_key)) {
    # API key authentication
    # In production, validate API key against database
    expected_key <- Sys.getenv("CLOUDPULSE_API_KEY", unset = "")
    if (!nzchar(expected_key) || !identical(api_key, expected_key)) {
      return(list(
        success = FALSE,
        error = "Unauthorized. Invalid API key.",
        code = 401
      ))
    }
    return(list(
      success = TRUE,
      user_id = "api_user",
      role = "admin",  # API key users typically have admin role
      api_key = api_key
    ))
  }
  
  # No authentication provided
  return(list(
    success = FALSE,
    error = "Unauthorized. Provide Authorization header or X-API-Key.",
    code = 401
  ))
}

#' Check if user has permission for an endpoint
#' 
#' @param user_role Character. The user's role
#' @param endpoint Character. The API endpoint path
#' 
#' @return Logical. TRUE if user has permission, FALSE otherwise
check_endpoint_permission <- function(user_role, endpoint) {
  is_endpoint_allowed(user_role, endpoint)
}

#' Create API auth error response
#' 
#' @param message Character. Error message
#' @param code Integer. HTTP status code
#' 
#' @return List with error response
api_error <- function(message, code = 403) {
  list(
    success = FALSE,
    error = message,
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ"),
    code = code
  )
}

#' Create successful API response
#' 
#' @param data Any. Response data
#' @param message Character. Optional message
#' 
#' @return List with success response
api_success <- function(data, message = NULL) {
  response <- list(
    success = TRUE,
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ"),
    data = data
  )
  
  if (!is.null(message)) {
    response$message <- message
  }
  
  response
}

# ══════════════════════════════════════════════════════════════════════════════
# ENDPOINT-SPECIFIC PERMISSION HANDLERS
# ══════════════════════════════════════════════════════════════════════════════

#' Check permission to view cost data
#' 
#' @param user_role Character. User role
#' @param account_owner Character. Owner of the account (optional)
#' @param user_id Character. Current user ID (optional)
#' 
#' @return Logical. TRUE if permitted
can_view_costs <- function(user_role, account_owner = NULL, user_id = NULL) {
  if (has_permission(user_role, "cost:view_all")) return(TRUE)
  if (has_permission(user_role, "cost:view_own")) {
    if (!is.null(account_owner) && !is.null(user_id)) {
      return(account_owner == user_id)
    }
  }
  FALSE
}

#' Check permission to manage users
#' 
#' @param user_role Character. User role
#' 
#' @return Logical. TRUE if permitted
can_manage_users <- function(user_role) {
  has_permission(user_role, "user:create") || has_permission(user_role, "user:update")
}

#' Check permission to view Kubernetes data
#' 
#' @param user_role Character. User role
#' @param cluster_owner Character. Owner of the cluster (optional)
#' @param user_id Character. Current user ID (optional)
#' 
#' @return Logical. TRUE if permitted
can_view_k8s <- function(user_role, cluster_owner = NULL, user_id = NULL) {
  if (has_permission(user_role, "cluster:view_all")) return(TRUE)
  if (has_permission(user_role, "cluster:view_own")) {
    if (!is.null(cluster_owner) && !is.null(user_id)) {
      return(cluster_owner == user_id)
    }
  }
  FALSE
}

#' Check permission to manage alerts
#' 
#' @param user_role Character. User role
#' 
#' @return Logical. TRUE if permitted
can_manage_alerts <- function(user_role) {
  has_permission(user_role, "alert:manage") || 
  has_permission(user_role, "k8s:manage_alerts")
}

# ══════════════════════════════════════════════════════════════════════════════
# MIDDLEWARE FUNCTIONS (for Plumber filters)
# ══════════════════════════════════════════════════════════════════════════════

#' Plumber filter for RBAC enforcement
#' 
#' Usage in plumber.R:
#' #* @filter rbac
#' function(req, res) { setup_rbac_filter(req, res) }
setup_rbac_filter <- function(req, res) {
  
  # Skip auth on public endpoints
  if (grepl("^/health$|^/__docs__|^/openapi", req$PATH_INFO)) {
    return(plumber::forward())
  }
  
  # Authenticate request
  auth <- authenticate_api_request(req, res)
  
  if (!auth$success) {
    res$status <- auth$code %||% 401
    return(list(
      success = FALSE,
      error = auth$error,
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
    ))
  }
  
  # Check endpoint permission
  if (!check_endpoint_permission(auth$role, req$PATH_INFO)) {
    res$status <- 403
    return(list(
      success = FALSE,
      error = "Forbidden. Insufficient permissions for this endpoint.",
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
    ))
  }
  
  # Store auth info in request for use in endpoints
  req$user <- list(
    user_id = auth$user_id,
    role = auth$role
  )
  
  plumber::forward()
}

#' Check if request has required permission (for use in endpoint handlers)
#' 
#' @param req The request object
#' @param permission Character. Required permission
#' @param res The response object
#' 
#' @return Logical. TRUE if permitted, FALSE if not (sends error to res)
check_permission_or_error <- function(req, res, permission) {
  
  if (!has_permission(req$user$role, permission)) {
    res$status <- 403
    return(FALSE)
  }
  
  TRUE
}

#' Log API action for audit trail
#' 
#' @param user_id Character. User ID
#' @param action Character. Action performed
#' @param resource_type Character. Type of resource
#' @param resource_id Character. Resource identifier
#' @param status Character. success or failure
#' @param details List. Additional details
#' @param db_path Character. Database path (optional)
log_api_action <- function(user_id, action, resource_type, resource_id, 
                           status = "success", details = NULL, db_path = NULL) {
  
  if (is.null(db_path)) {
    # Development: just print to console
    message(sprintf(
      "[AUDIT] %s | User: %s | Action: %s | Resource: %s/%s | Status: %s",
      format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
      user_id, action, resource_type, resource_id, status
    ))
    return()
  }
  
  # Production: write to audit log database
  tryCatch({
    conn <- DBI::dbConnect(RSQLite::SQLite(), db_path)
    on.exit(DBI::dbDisconnect(conn), add = TRUE)
    
    DBI::dbExecute(
      conn,
      "INSERT INTO audit_log (user_id, action, resource_type, resource_id, status, details, timestamp)
       VALUES (?, ?, ?, ?, ?, ?, ?)",
      params = list(
        user_id, action, resource_type, resource_id, status,
        if (is.null(details)) NULL else jsonlite::toJSON(details),
        format(Sys.time(), "%Y-%m-%d %H:%M:%S")
      )
    )
  }, error = function(e) {
    warning("Failed to log API action: ", conditionMessage(e))
  })
}
