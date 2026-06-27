# RBAC Integration Testing Guide

## Quick Start (5 minutes)

### 1. Start the Application
```R
# In RStudio or R console:
library(shiny)
source("lib/FInOpsApp.R")
shinyApp(ui, server)

# Or run launcher

```

### 2. Test Login Flow
The login page is now the first screen. Try these credentials:

**Admin User (Full Access)**
- Username: `admin`
- Password: `admin_password`
- Expected: See all tabs in navigation bar

**FinOps Analyst (Cost/Cloud Focus)**
- Username: `analyst`
- Password: `analyst_password`  
- Expected: Dashboard, Multi-Cloud, Reports tabs only

**DevOps Engineer (K8s Focus)**
- Username: `devops`
- Password: `devops_password`
- Expected: Dashboard, Kubernetes tabs only

**Viewer (Read-Only)**
- Username: `viewer`
- Password: `viewer_password`
- Expected: Dashboard tab only

### 3. Verify Features

#### After Login as Admin:
- [ ] See user name in top-right corner
- [ ] See all five tabs: Dashboard, Multi-Cloud, Kubernetes, Reports, Developer
- [ ] Click "Multi-Cloud" tab → see cloud provider configuration form
- [ ] Click "Developer" tab → see system settings
- [ ] Click logout → return to login page

#### After Login as Analyst:
- [ ] See user name in top-right corner  
- [ ] See three tabs: Dashboard, Multi-Cloud, Reports
- [ ] NO Kubernetes tab
- [ ] NO Developer tab
- [ ] Can configure cloud providers in Multi-Cloud tab

#### After Login as DevOps:
- [ ] See user name in top-right corner
- [ ] See two tabs: Dashboard, Kubernetes
- [ ] NO Multi-Cloud tab
- [ ] NO Reports tab
- [ ] NO Developer tab

#### After Login as Viewer:
- [ ] See user name in top-right corner
- [ ] See only Dashboard tab
- [ ] NO Multi-Cloud, Kubernetes, Reports, or Developer tabs

### 4. Session Management
- [ ] Login successfully
- [ ] Leave idle for 1 hour (or edit code to reduce timeout to 60 sec for testing)
- [ ] Automatic logout occurs
- [ ] Notification shows "Session expired due to inactivity"
- [ ] Redirected to login page

### 5. Rate Limiting
- [ ] Go to login page
- [ ] Try 5 incorrect password attempts  
- [ ] On 5th attempt, see lockout message
- [ ] Must wait 20 minutes before trying again (or edit code to reduce timeout for testing)

### 6. Cloud Provider Configuration (Admin or Analyst)
- [ ] Login as admin or analyst
- [ ] Go to Multi-Cloud tab
- [ ] See credential entry form for AWS, Azure, GCP
- [ ] Form validation works (required fields, format validation)
- [ ] Can submit valid credentials or mock data

## Testing Checklist

### Core RBAC Functions
- [ ] `authenticate_user("admin", "admin_password")` works
- [ ] `authenticate_user("wrong", "wrong")` fails
- [ ] `has_permission("admin", "system:configure")` returns TRUE
- [ ] `has_permission("viewer", "system:configure")` returns FALSE
- [ ] `get_ui_visibility("admin")` shows all features
- [ ] `get_ui_visibility("viewer")` hides most features

### Authentication State
- [ ] `user_authenticated()` is FALSE before login
- [ ] `user_authenticated()` is TRUE after login
- [ ] `current_user_data()$username` shows correct user
- [ ] `current_user_data()$role` shows correct role

### Navigation
- [ ] Nav panels update based on role
- [ ] Nav_spacer() creates spacing before user menu
- [ ] User info header displays username and role

### Session Timeout
- [ ] Session timer runs every 60 seconds
- [ ] User is logged out after inactivity timeout
- [ ] Notification triggers before logout
- [ ] New login required after timeout

## Troubleshooting

### "Login failed" message
- Check username/password match demo users above
- Verify `RBAC_DB_PATH` is `NULL` for demo mode
- Check RBAC modules are sourcing correctly

### Some tabs missing after login
- Expected behavior based on role
- Verify correct user logged in
- Check `get_ui_visibility()` in `lib/rbac.R`

### Cloud credentials form not visible
- Must be on Multi-Cloud tab
- Check user has `cloud:configure` permission (Admin/Analyst)
- Check viewer login (doesn't have Multi-Cloud tab)

### No logout button
- Check top-right corner for user info header
- User info header should have logout button
- Check `user_info_header()` in `lib/login_ui.R`

### Rate limiting not working
- Check demo credentials used (not admin/admin)
- Try with wrong password intentionally
- 5 attempts = lockout for 20 minutes

## File Modifications Made

### FInOpsApp.R Changes
- ✅ Added RBAC module sources (lines 77-79)
- ✅ Added RBAC authentication state variables (lines 1068-1100)
- ✅ Added session timeout observer (lines 1104-1130)
- ✅ Replaced main_ui output with RBAC-based rendering (lines 1140-1214)
- ✅ Removed old provider-based login handler
- ✅ Removed old logout handler
- ✅ Removed old navigation event handlers

### New Files Created
- ✅ lib/rbac.R - Core RBAC system
- ✅ lib/auth.R - Authentication module
- ✅ lib/login_ui.R - Login UI component  
- ✅ api/rbac_middleware.R - API auth/authorization
- ✅ api/rbac_endpoints.R - Example API endpoints
- ✅ setup/rbac_schema.sql - Database schema
- ✅ docs/RBAC_QUICK_START.md - 5-min setup
- ✅ docs/RBAC_SETUP.md - Complete guide

## Next Steps (After Testing)

1. **Production Database**
   - Replace `RBAC_DB_PATH <- NULL` with actual file path
   - Run `setup/rbac_schema.sql` to create schema
   - Create real users with `create_user()`

2. **API Integration**
   - Uncomment RBAC middleware in `api/plumber.R`
   - Apply filters to all endpoints
   - Test API authentication

3. **Add Permission Checks**
   - Add checks before sensitive operations:
     - Cost export: `if (has_permission(..., "cost:export"))`
     - User creation: `if (has_permission(..., "user:create"))`
     - K8s config: `if (has_permission(..., "cluster:configure"))`

4. **Customize Appearance**
   - Edit `lib/login_ui.R` for custom branding
   - Update `lib/rbac.R` with custom roles/permissions
   - Modify role colors in badge display

5. **Audit Monitoring**
   - Set up log monitoring from `audit_log` table
   - Create reports from role_changes table
   - Alert on suspicious activity patterns

---

**Expected Outcome**: CloudPulse now supports enterprise multi-user access with role-based features! 🎉
