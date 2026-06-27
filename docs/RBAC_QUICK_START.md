# CloudPulse RBAC - Quick Start Guide
# Get up and running in 5 minutes
# Author: Keaton Szantho

## 5-Minute Setup

### Step 1: Load the RBAC Modules (1 min)

Add these lines to your R session or Shiny app:

```R
source("lib/rbac.R")
source("lib/auth.R")
source("lib/login_ui.R")
```

### Step 2: Test Authentication (1 min)

Try logging in with a demo user:

```R
# Test with admin credentials
result <- authenticate_user("admin", "admin_password", db_path = NULL)
print(result)
# Output should show: success = TRUE

# Test permission checking
has_permission(result$role, "user:create")  # TRUE for admin
# Output: TRUE
```

### Step 3: Check User Visibility (1 min)

```R
# Get UI visibility for each role
ui_vis_admin <- get_ui_visibility("admin")
ui_vis_analyst <- get_ui_visibility("finops_analyst")
ui_vis_devops <- get_ui_visibility("devops_engineer")
ui_vis_viewer <- get_ui_visibility("viewer")

# Check what each role can see
ui_vis_admin$show_users        # TRUE
ui_vis_analyst$show_users      # FALSE
ui_vis_devops$show_k8s         # TRUE
ui_vis_viewer$can_manage_users # FALSE
```

### Step 4: Integrate Into Shiny App (2 min)

In your `server` function:

```R
server <- function(input, output, session) {
  
  # Add RBAC state
  user_authenticated <- reactiveVal(FALSE)
  current_user_data <- reactiveVal(NULL)
  login_attempts_rv <- reactiveVal(0L)
  last_attempt_time_rv <- reactiveVal(NULL)
  
  # Setup login
  setup_login_server(
    input, output, session,
    user_authenticated,
    current_user_data,
    login_attempts_rv,
    last_attempt_time_rv
  )
  
  # Show login or dashboard
  output$main_ui <- renderUI({
    if (user_authenticated()) {
      h1("Welcome,", current_user_data()$display_name)
    } else {
      login_ui()
    }
  })
}
```

## Demo Users

| Username | Password | Role |
|----------|----------|------|
| **admin** | admin_password | Administrator |
| **analyst** | analyst_password | FinOps Analyst |
| **devops** | devops_password | DevOps Engineer |
| **viewer** | viewer_password | Viewer |

## Permission Checks

```R
# Check if user has permission
has_permission("admin", "user:create")           # TRUE
has_permission("viewer", "user:create")          # FALSE
has_permission("finops_analyst", "cost:export")  # TRUE
has_permission("devops_engineer", "cost:export") # FALSE

# Check multiple permissions
has_any_permission("admin", c("user:create", "cost:export"))  # TRUE
has_all_permissions("viewer", c("cost:view_own"))              # TRUE

# What can each role do?
get_ui_visibility("admin")           # Shows all flags
get_ui_visibility("finops_analyst")  # Shows cost/report flags
get_ui_visibility("devops_engineer") # Shows K8s flags
get_ui_visibility("viewer")          # Shows minimal flags
```

## Functions

| Function | Purpose | Example |
|----------|---------|---------|
| `authenticate_user()` | Verify login | `authenticate_user("admin", "password")` |
| `has_permission()` | Check permission | `has_permission("admin", "cost:view_all")` |
| `get_ui_visibility()` | Get visibility settings | `get_ui_visibility("admin")` |
| `create_user()` | Create new user | `create_user("john", "pwd123", "john@example.com", "viewer")` |
| `get_role_display_name()` | Get role label | `get_role_display_name("finops_analyst")` |
| `list_all_roles()` | List all roles | `list_all_roles()` |

## Role Permissions

### Admin
```
✓ User management (create, read, update, delete)
✓ Cloud account configuration
✓ View all costs
✓ Manage Kubernetes clusters
✓ Generate reports
✓ System settings
✓ Audit logs
```

### FinOps Analyst
```
✓ View all costs
✓ Generate reports
✓ View recommendations
✓ Infrastructure overview (read-only)
✗ User management
✗ Kubernetes management
```

### DevOps Engineer
```
✓ Kubernetes management
✓ Alert management
✓ Infrastructure metrics
✓ Pod/namespace details
✓ Limited cost visibility (own)
✗ User management
✗ Report generation
```

### Viewer
```
✓ View own costs
✓ View own resources (read-only)
✗ Everything else (read-only access only)
```

## Role Comparison Matrix

| Feature | Admin | Analyst | DevOps | Viewer |
|---------|-------|---------|--------|--------|
| View Costs | ✅ All | ✅ All | ⚠️ Own | ⚠️ Own |
| Manage Users | ✅ | ❌ | ❌ | ❌ |
| Configure Cloud | ✅ | ❌ | ❌ | ❌ |
| View K8s | ✅ | ✅ | ✅ | ✅ |
| Manage K8s | ✅ | ❌ | ✅ | ❌ |
| Create Reports | ✅ | ✅ | ❌ | ❌ |
| Manage Alerts | ✅ | ❌ | ✅ | ❌ |

## Testing Checklist

```R
# Test 1: Admin can do everything
admin_result <- authenticate_user("admin", "admin_password", NULL)
has_permission(admin_result$role, "user:create")      # Should be TRUE
has_permission(admin_result$role, "cost:view_all")    # Should be TRUE
has_permission(admin_result$role, "cluster:manage")   # Should be TRUE

# Test 2: Analyst can view costs
analyst_result <- authenticate_user("analyst", "analyst_password", NULL)
has_permission(analyst_result$role, "cost:view_all")  # Should be TRUE
has_permission(analyst_result$role, "user:create")    # Should be FALSE

# Test 3: DevOps can manage K8s
devops_result <- authenticate_user("devops", "devops_password", NULL)
has_permission(devops_result$role, "cluster:manage")  # Should be TRUE
has_permission(devops_result$role, "user:create")     # Should be FALSE

# Test 4: Viewer is read-only
viewer_result <- authenticate_user("viewer", "viewer_password", NULL)
has_permission(viewer_result$role, "cost:view_own")   # Should be TRUE
has_permission(viewer_result$role, "cost:export")     # Should be FALSE
```

## Security Features

- ✅ Password hashing (PBKDF2-SHA256)
- ✅ Session timeout (1 hour)
- ✅ Login rate limiting (5 attempts, 20-min lockout)
- ✅ Input validation & sanitization
- ✅ Audit logging
- ✅ API authentication (JWT/API Key)
- ✅ Permission-based endpoint access

## Full Documentation

For detailed information, see:

- **Complete Setup Guide**: `docs/RBAC_SETUP.md`
- **Integration Guide**: `docs/RBAC_INTEGRATION.md`

## Troubleshooting

### "Authentication failed" error
```R
# Make sure db_path is NULL for demo users
result <- authenticate_user("admin", "admin_password", db_path = NULL)
#                                                       ^^^^^^^^^^^ 
# Must be NULL for demo users
```

### Permission check returns FALSE unexpectedly
```R
# Verify role name is exact (case-sensitive)
has_permission("finops_analyst", "cost:view_all")  # Correct
has_permission("FinOps Analyst", "cost:view_all")  # Wrong (wrong case)
```

### UI elements not showing/hiding
```R
# Verify conditional rendering in UI
if (ui_visibility$show_users) {
  # This block only shows if user can see users
  nav_panel("Users", users_ui())
}
```

## Tips

1. **Always use demo users first** to test the system
2. **Check permissions before operations** to provide good UX
3. **Use `get_ui_visibility()`** to control navigation
4. **Log important actions** for audit trail
5. **Test with all 4 roles** before deployment

## Next Steps

1. ✅ Test RBAC with demo users
2. ✅ Integrate into your Shiny app
3. ✅ Add permission checks to operations
4. ✅ Test with actual users
5. ✅ Deploy with production database

## Need Help?

Refer to the appropriate guide:
- **Getting started**: This guide (RBAC_QUICK_START.md)
- **Installation**: `docs/RBAC_SETUP.md`
- **Integration**: `docs/RBAC_INTEGRATION.md`
- **Architecture**: `docs/RBAC_SUMMARY.md`

---

**Start in 5 minutes** 
