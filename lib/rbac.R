# CloudPulse RBAC (Role-Based Access Control) Module
# Defines roles, permissions, and access control logic
# Author: Keaton Szantho

# ══════════════════════════════════════════════════════════════════════════════
# ROLE DEFINITIONS
# ══════════════════════════════════════════════════════════════════════════════

#' RBAC Role Definitions
#' Defines four roles with granular permissions
#' across cloud cost, infrastructure,
#' and user management functions.

rbac_roles <- list(
  admin = list(
    display_name = "Administrator",
    permissions = c(
      # User management
      "user:create", "user:read", "user:update", "user:delete",
      "user:list", "role:manage",
      # Cloud account management
      "cloud:configure", "cloud:list", "cloud:delete", "cloud:edit",
      # Cost visibility
      "cost:view_all", "cost:export", "cost:budget_manage",
      "metadata:view", "metadata:manage",
      # Cluster management
      "cluster:view_all", "cluster:manage", "cluster:configure",
      # Recommendations
      "recommendation:view", "recommendation:manage",
      # Reports
      "report:generate", "report:view_all",
      # System
      "system:settings", "system:audit_log"
    ),
    description = "Full platform access. Can manage users and cloud accounts."
  ),

  finops_analyst = list(
    display_name = "FinOps Analyst",
    permissions = c(
      # User management (read-only)
      "user:read", "user:list",
      # Cloud cost visibility
      "cost:view_all", "cost:export", "cost:budget_view",
      "metadata:view",
      # Cluster visibility
      "cluster:view_all",
      # Recommendations
      "recommendation:view",
      # Reports
      "report:generate", "report:view_all"
    ),
    description = "Cost analysis and reporting.
    Read-only access to infrastructure."
  ),

  devops_engineer = list(
    display_name = "DevOps Engineer",
    permissions = c(
      # Kubernetes management
      "cluster:view_all", "cluster:manage",
      "k8s:view_nodes", "k8s:view_pods", "k8s:view_namespaces",
      "k8s:manage_alerts", "k8s:manage_deployments",
      # Infrastructure metrics
      "metric:view_infrastructure", "metric:view_performance",
      "alert:manage",
      # Cost visibility (limited)
      "cost:view_own", "metadata:view"
    ),
    description = "Infrastructure and Kubernetes management.
    Alert and metric access."
  ),

  viewer = list(
    display_name = "Viewer",
    permissions = c(
      # Read-only visibility
      "cost:view_own",
      "cluster:view_own",
      "metric:view_own",
      "report:view_own"
    ),
    description = "Read-only access to assigned resources."
  )
)

# ══════════════════════════════════════════════════════════════════════════════
# PERMISSION HIERARCHY
# ══════════════════════════════════════════════════════════════════════════════

#' Permission Group Expansions
#' For convenience, some broad
#' permissions expand to multiple specific permissions
rbac_groups <- list(
  "all" = unlist(lapply(rbac_roles, function(r) r$permissions)),
  "admin" = rbac_roles$admin$permissions,
  "finops" = rbac_roles$finops_analyst$permissions,
  "devops" = rbac_roles$devops_engineer$permissions,
  "viewer" = rbac_roles$viewer$permissions
)

# ══════════════════════════════════════════════════════════════════════════════
# RBAC FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════

#' Get user role
#'
#' @param user_id Character. The user ID / username
#' @param role_cache Reactive list or
#' environment containing user roles (optional)
#' @return Character. The role
#' name (admin, finops_analyst, devops_engineer, viewer)
#'         or NULL if user not found
get_user_role <- function(user_id, role_cache = NULL) {
  if (is.null(user_id) || !nzchar(user_id)) return(NULL)

  # Check cache first (if provided)
  if (!is.null(role_cache)) {
    if (is.reactivevalues(role_cache) && !is.null(role_cache[[user_id]])) {
      return(role_cache[[user_id]])
    }
    if (is.environment(role_cache) && exists(user_id, envir = role_cache)) {
      return(get(user_id, envir = role_cache))
    }
  }

  # Placeholder: fetch from database
  # In production, this would query the user database
  # For now, return NULL (will be implemented with auth system)
  NULL
}

#' Check if user has permission
#' @param user_role Character. The role name
#' @param permission Character. Permission string (e.g., "cost:view_all")
#' @param resource_owner Character.
#' Owner of the resource (optional, for ownership checks)
#' @param current_user Character. Current user ID (optional,
#' for ownership checks)
#'
#' @return Logical. TRUE if user has permission, FALSE otherwise
has_permission <- function(user_role, permission, resource_owner = NULL, current_user = NULL) {
  if (is.null(user_role) || !nzchar(user_role)) return(FALSE)
  if (is.null(permission) || !nzchar(permission)) return(FALSE)

  # Check if role exists
  if (!(user_role %in% names(rbac_roles))) return(FALSE)

  # Get role permissions
  role_perms <- rbac_roles[[user_role]]$permissions

  # Handle ownership-based permissions (e.g., "cost:view_own")
  if (grepl("_own$", permission)) {
    if (!is.null(resource_owner) && !is.null(current_user)) {
      if (resource_owner == current_user) {
        # Check if they have the base permission (e.g., "cost:view")
        base_perm <- sub("_own$", "", permission)
        if (base_perm %in% role_perms) return(TRUE)
      }
    }
    # Also check if they have the full permission
    return(permission %in% role_perms)
  }

  # Direct permission check
  permission %in% role_perms
}

#' Check if user has any of multiple permissions
#' @param user_role Character. The role name
#' @param permissions Character vector. Permissions to check
#' @return Logical. TRUE if user has any of the permissions, FALSE otherwise
has_any_permission <- function(user_role, permissions) {
  if (is.null(user_role)) return(FALSE)
  any(sapply(permissions, function(p) has_permission(user_role, p)))
}

#' Check if user has all of multiple permissions
#'
#' @param user_role Character. The role name
#' @param permissions Character vector. Permissions to check
#' @return Logical. TRUE if user has all of the permissions, FALSE otherwise
has_all_permissions <- function(user_role, permissions) {
  if (is.null(user_role)) return(FALSE)
  all(sapply(permissions, function(p) has_permission(user_role, p)))
}

#' Get list of allowed API endpoints for a role
#' @param user_role Character. The role name
#'
#' @return Character vector. List of API endpoints the role can access
get_allowed_endpoints <- function(user_role) {
  endpoint_mapping <- list(
    admin = c(
      "/metadata", "/instances", "/usage", "/cost", "/forecast",
      "/k8s/clusters", "/k8s/nodes", "/k8s/pods", "/k8s/metrics",
      "/k8s/events", "/k8s/namespaces",
      "/users", "/users/*", "/roles", "/roles/*",
      "/settings", "/audit"
    ),
    finops_analyst = c(
      "/metadata", "/usage", "/cost", "/forecast",
      "/k8s/clusters",
      "/users/list", "/roles/list"
    ),
    devops_engineer = c(
      "/k8s/clusters", "/k8s/nodes", "/k8s/pods", "/k8s/metrics",
      "/k8s/events", "/k8s/namespaces",
      "/metadata", "/usage",
      "/alerts", "/alerts/*"
    ),
    viewer = c(
      "/k8s/clusters", "/k8s/nodes", "/k8s/pods", "/k8s/metrics"
    )
  )

  return(endpoint_mapping[[user_role]] %||% character(0))
}

#' Check if endpoint is accessible for a role
#'
#' @param user_role Character. The role name
#' @param endpoint Character. The API endpoint path
#'
#' @return Logical. TRUE if accessible, FALSE otherwise
is_endpoint_allowed <- function(user_role, endpoint) {
  allowed <- get_allowed_endpoints(user_role)

  # Direct match
  if (endpoint %in% allowed) return(TRUE)

  # Wildcard match (e.g., "/users/*" matches "/users/john")
  for (pattern in allowed) {
    if (grepl("\\*$", pattern)) {
      base <- sub("\\*$", "", pattern)
      if (grepl(paste0("^", gsub("/", "\\\\/", base)), endpoint)) {
        return(TRUE)
      }
    }
  }

  FALSE
}

#' Get filtered UI elements based on role
#'
#' @param user_role Character. The role name
#'
#' @return List with flags for UI visibility
get_ui_visibility <- function(user_role) {
  list(
    show_dashboard = TRUE,  # All roles
    show_multicloud = has_permission(user_role, "cost:view_all") ||
      has_permission(user_role, "cloud:list"),

    show_k8s = has_permission(user_role, "cluster:view_all"),
    show_cost = has_permission(user_role, "cost:view_all") ||
      has_permission(user_role, "cost:view_own"),

    show_reports = has_permission(user_role, "report:generate") ||
      has_permission(user_role, "report:view_all"),
    show_users = has_permission(user_role, "user:list") ||
      has_permission(user_role, "user:manage"),

    show_settings = has_permission(user_role, "system:settings"),
    show_audit = has_permission(user_role, "system:audit_log"),

    show_recommendations = has_permission(user_role, "recommendation:view"),
    show_alerts = has_permission(user_role, "k8s:manage_alerts") ||
      has_permission(user_role, "alert:manage"),

    # Edit/manage capabilities
    can_manage_users = has_permission(user_role, "user:create") ||
      has_permission(user_role, "user:update"),
    can_manage_cloud = has_permission(user_role, "cloud:configure"),

    can_manage_clusters = has_permission(user_role, "cluster:manage"),
    can_export_data = has_permission(user_role, "cost:export"),
    can_edit_alerts = has_permission(user_role, "alert:manage")
  )
}

#' Get role display name
#' @param role_name Character. The role name
#'
#' @return Character. Human-readable role name
get_role_display_name <- function(role_name) {
  if (is.null(role_name) || !(role_name %in% names(rbac_roles))) {
    return("Unknown")
  }
  rbac_roles[[role_name]]$display_name
}

#' List all available roles
#'
#' @return Data frame with role names, display names, and descriptions
list_all_roles <- function() {
  roles_df <- data.frame(
    role_name = names(rbac_roles),
    display_name = sapply(rbac_roles, function(r) r$display_name),
    description = sapply(rbac_roles, function(r) r$description),
    permission_count = sapply(rbac_roles, function(r) length(r$permissions)),
    stringsAsFactors = FALSE
  )
  rownames(roles_df) <- NULL
  roles_df
}

#' Get all permissions for a role
#'
#' @param role_name Character. The role name
#'
#' @return Character vector. All permissions for the role
get_role_permissions <- function(role_name) {
  if (!(role_name %in% names(rbac_roles))) return(character(0))
  rbac_roles[[role_name]]$permissions
}

#' Validate role name
#'
#' @param role_name Character. The role name to validate
#'
#' @return Logical. TRUE if valid role, FALSE otherwise
is_valid_role <- function(role_name) {
  role_name %in% names(rbac_roles)
}
