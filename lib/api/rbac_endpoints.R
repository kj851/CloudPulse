# CloudPulse API - User Management Endpoints
# Demonstrates RBAC integration in Plumber API
# Author: Keaton Szantho

# Source these files before defining endpoints
source("lib/rbac.R")
source("lib/auth.R")
source("lib/api/rbac_middleware.R")

# ══════════════════════════════════════════════════════════════════════════════
# USER MANAGEMENT ENDPOINTS (RBAC EXAMPLE)
# ══════════════════════════════════════════════════════════════════════════════

#* List all users (Admin only)
#* @tag Users
#* @get /users
function(req, res) {
  # Check permission
  if (!has_permission(req$user$role, "user:list")) {
    res$status <- 403
    log_api_action(req$user$user_id, "LIST_USERS", "users", "all", "failure")
    return(list(error = "Insufficient permissions to list users."))
  }

  tryCatch({
    users <- list_users(db_path = NULL)  # Use actual db_path in production

    # Log successful action
    log_api_action(req$user$user_id, "LIST_USERS", "users", "all", "success",
      list(user_count = nrow(users))
    )

    # Return only non-sensitive fields
    users_safe <- users[, c("user_id", "username", 
      "email", "display_name", "role", "active"
    )]

    list(
      success = TRUE,
      data = users_safe,
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
    )
  }, error = function(e) {
    res$status <- 500
    log_api_action(req$user$user_id, "LIST_USERS", "users", "all", "failure",
      list(error = conditionMessage(e))
    )
    list(error = "Failed to list users.")
  })
}

#* Get user details
#* @tag Users
#* @param user_id User ID to retrieve
#* @get /users/<user_id>
function(req, res, user_id) {
  # Check permission (can view own or all if admin)
  can_view <- has_permission(req$user$role, "user:read") ||
    (req$user$user_id == user_id &&
       has_permission(req$user$role, "user:read"))

  if (!can_view) {
    res$status <- 403
    log_api_action(req$user$user_id, "VIEW_USER", "users", user_id, "failure")
    return(list(error = "Insufficient permissions."))
  }

  tryCatch({
    result <- get_user_info(user_id, db_path = NULL)

    if (!result$success) {
      res$status <- 404
      return(list(error = result$error))
    }

    user <- result$user
    # Remove sensitive fields
    user$password_hash <- NULL
    user$password_salt <- NULL

    log_api_action(req$user$user_id, "VIEW_USER", "users", user_id, "success")

    list(
      success = TRUE,
      data = user,
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
    )
  }, error = function(e) {
    res$status <- 500
    log_api_action(req$user$user_id, "VIEW_USER", "users", user_id, "failure",
      list(error = conditionMessage(e))
    )
    list(error = "Failed to retrieve user.")
  })
}

#* Create new user (Admin only)
#* @tag Users
#* @param username New username
#* @param password Initial password
#* @param email Email address
#* @param role Role (admin, finops_analyst, devops_engineer, viewer)
#* @param display_name Display name (optional)
#* @post /users
function(req, res, username, password, email, role, display_name = NULL) {
  # Check permission
  if (!has_permission(req$user$role, "user:create")) {
    res$status <- 403
    log_api_action(req$user$user_id, "CREATE_USER",
      "users", username, "failure",
      list(reason = "Insufficient permissions")
    )
    return(list(error = "Only admins can create users."))
  }

  tryCatch({
    result <- create_user(username, password,
      email, role, display_name, db_path = NULL
    )

    if (!result$success) {
      res$status <- 400
      log_api_action(req$user$user_id,
        "CREATE_USER", "users", username, "failure",
        list(error = result$error)
      )
      return(list(error = result$error))
    }

    log_api_action(req$user$user_id,
      "CREATE_USER", "users", username, "success",
      list(role = role, email = email)
    )

    res$status <- 201
    list(
      success = TRUE,
      message = result$message,
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
    )
  }, error = function(e) {
    res$status <- 500
    log_api_action(req$user$user_id,
      "CREATE_USER", "users", username, "failure",
      list(error = conditionMessage(e))
    )
    list(error = "Failed to create user.")
  })
}

#* Update user role (Admin only)
#* @tag Users
#* @param user_id User to update
#* @param new_role New role
#* @patch /users/<user_id>/role
function(req, res, user_id, new_role) {
  # Check permission
  if (!has_permission(req$user$role, "role:manage")) {
    res$status <- 403
    log_api_action(req$user$user_id,
      "UPDATE_USER_ROLE", "users", user_id, "failure"
    )
    return(list(error = "Only admins can update user roles."))
  }

  # Validate role
  if (!is_valid_role(new_role)) {
    res$status <- 400
    return(list(error = "Invalid role."))
  }

  tryCatch({
    # In production, update database
    # For now, just log the action
    old_role <- get_user_role(user_id)

    log_api_action(req$user$user_id,
      "UPDATE_USER_ROLE", "users", user_id, "success",
      list(old_role = old_role, new_role = new_role)
    )

    list(
      success = TRUE,
      message = sprintf("User role updated from %s to %s", old_role, new_role),
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
    )
  }, error = function(e) {
    res$status <- 500
    log_api_action(req$user$user_id,
      "UPDATE_USER_ROLE", "users", user_id, "failure",
      list(error = conditionMessage(e))
    )
    list(error = "Failed to update user role.")
  })
}

#* Deactivate user (Admin only)
#* @tag Users
#* @param user_id User to deactivate
#* @delete /users/<user_id>
function(req, res, user_id) {
  # Check permission
  if (!has_permission(req$user$role, "user:delete")) {
    res$status <- 403
    log_api_action(req$user$user_id,
      "DELETE_USER", "users", user_id, "failure"
    )
    return(list(error = "Only admins can delete users."))
  }

  # Prevent admin from deleting their own account
  if (req$user$user_id == user_id) {
    res$status <- 400
    return(list(error = "Cannot delete your own account."))
  }

  tryCatch({
    # In production, deactivate in database

    log_api_action(req$user$user_id, "DELETE_USER", "users", user_id, "success",
      list(action = "deactivate")
    )

    list(
      success = TRUE,
      message = "User deactivated successfully.",
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
    )
  }, error = function(e) {
    res$status <- 500
    log_api_action(req$user$user_id,
      "DELETE_USER", "users", user_id, "failure"
    )
    list(error = "Failed to delete user.")
  })
}

# ══════════════════════════════════════════════════════════════════════════════
# RBAC ENDPOINTS
# ══════════════════════════════════════════════════════════════════════════════

#* Get all available roles
#* @tag RBAC
#* @get /roles
function(req, res) {
  if (!has_permission(req$user$role, "role:manage")) {
    res$status <- 403
    return(list(error = "Insufficient permissions."))
  }

  roles_df <- list_all_roles()

  # Convert to list format for JSON
  roles_list <- lapply(1:nrow(roles_df), function(i) {
    as.list(roles_df[i, ])
  })

  list(
    success = TRUE,
    data = roles_list,
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
  )
}

#* Get role details and permissions
#* @tag RBAC
#* @param role Role name
#* @get /roles/<role>
function(req, res, role) {
  if (!is_valid_role(role)) {
    res$status <- 404
    return(list(error = "Role not found."))
  }

  permissions <- get_role_permissions(role)
  display_name <- get_role_display_name(role)

  list(
    success = TRUE,
    data = list(
      name = role,
      display_name = display_name,
      permission_count = length(permissions),
      permissions = permissions
    ),
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
  )
}

# COST DATA ENDPOINTS WITH RBAC

#* Get cost data (with RBAC filtering)
#* @tag Cloud
#* @param provider AWS | Azure | GCP | mock
#* @param account_id Account ID (optional, for filtering)
#* @get /cost
function(req, res, provider = "mock", account_id = NULL) {

  # Check permission
  if (!can_view_costs(req$user$role,
        resource_owner = account_id, user_id = req$user$user_id
      )) {
    res$status <- 403
    log_api_action(req$user$user_id, "VIEW_COST", "cost",
      account_id %||% provider, "failure"
    )
    return(list(error = "Insufficient permissions to view this cost data."))
  }

  tryCatch({
    # Get cost data (existing function)
    cost_data <- get_mock_cost(provider)

    # Filter by account_id if specified and user doesn't have full access
    if (!is.null(account_id) &&
          !has_permission(req$user$role, "cost:view_all")) {
      # Filter to user's accessible accounts (implement per-user filtering)
      # For now, just return the data
    }

    log_api_action(req$user$user_id, "VIEW_COST", "cost",
      account_id %||% provider, "success"
    )

    list(
      success = TRUE,
      data = cost_data,
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
    )
  }, error = function(e) {
    res$status <- 500
    log_api_action(req$user$user_id, "VIEW_COST", "cost",
      account_id %||% provider, "failure"
    )
    list(error = "Failed to retrieve cost data.")
  })
}

#* Get Kubernetes clusters (with RBAC filtering)
#* @tag Kubernetes
#* @get /k8s/clusters
function(req, res) {

  # Check permission
  if (!can_view_k8s(req$user$role)) {
    res$status <- 403
    log_api_action(req$user$user_id,
      "VIEW_K8S_CLUSTERS", "k8s", "clusters", "failure"
    )
    return(list(error = "Insufficient permissions to view Kubernetes data."))
  }

  tryCatch({
    # Get cluster data (existing function)
    clusters <- get_mock_k8s_clusters()

    # Filter clusters based on user's access (implement per-user cluster access)
    if (!has_permission(req$user$role, "cluster:view_all")) {
      # Filter to user's accessible clusters
      # For now, return all clusters for demo
    }

    log_api_action(req$user$user_id,
      "VIEW_K8S_CLUSTERS", "k8s", "clusters", "success"
    )

    list(
      success = TRUE,
      data = clusters,
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
    )
  }, error = function(e) {
    res$status <- 500
    log_api_action(req$user$user_id,
      "VIEW_K8S_CLUSTERS", "k8s", "clusters", "failure"
    )
    list(error = "Failed to retrieve cluster data.")
  })
}
