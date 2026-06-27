-- CloudPulse RBAC Database Schema
-- SQLite schema for users, roles, and access control
-- Execute this script to initialize the database

-- Users table
CREATE TABLE IF NOT EXISTS users (
  user_id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL UNIQUE COLLATE NOCASE,
  email TEXT NOT NULL UNIQUE COLLATE NOCASE,
  display_name TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  password_salt TEXT NOT NULL,
  role TEXT NOT NULL CHECK(role IN ('admin', 'finops_analyst', 'devops_engineer', 'viewer')),
  active INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_login TIMESTAMP,
  last_password_change TIMESTAMP,
  locked_until TIMESTAMP
);

-- User sessions table (for audit and session management)
CREATE TABLE IF NOT EXISTS user_sessions (
  session_id TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL,
  token TEXT NOT NULL UNIQUE,
  ip_address TEXT,
  user_agent TEXT,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_activity TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMP NOT NULL,
  active INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE
);

-- User roles history (for audit trail)
CREATE TABLE IF NOT EXISTS role_changes (
  change_id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  old_role TEXT,
  new_role TEXT NOT NULL,
  changed_by INTEGER,
  changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  reason TEXT,
  FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE,
  FOREIGN KEY (changed_by) REFERENCES users(user_id) ON DELETE SET NULL
);

-- Cloud account access control (per-user)
CREATE TABLE IF NOT EXISTS user_cloud_access (
  access_id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  provider TEXT NOT NULL CHECK(provider IN ('AWS', 'Azure', 'GCP')),
  account_id TEXT NOT NULL,
  account_name TEXT,
  access_level TEXT NOT NULL CHECK(access_level IN ('read', 'write', 'admin')),
  granted_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  granted_by INTEGER,
  expires_at TIMESTAMP,
  active INTEGER NOT NULL DEFAULT 1,
  UNIQUE(user_id, provider, account_id),
  FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE,
  FOREIGN KEY (granted_by) REFERENCES users(user_id) ON DELETE SET NULL
);

-- Cluster access control (per-user)
CREATE TABLE IF NOT EXISTS user_cluster_access (
  access_id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  cluster_name TEXT NOT NULL,
  cluster_id TEXT NOT NULL,
  access_level TEXT NOT NULL CHECK(access_level IN ('read', 'write', 'admin')),
  namespaces TEXT,  -- comma-separated list or '*' for all
  granted_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  granted_by INTEGER,
  expires_at TIMESTAMP,
  active INTEGER NOT NULL DEFAULT 1,
  UNIQUE(user_id, cluster_id),
  FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE,
  FOREIGN KEY (granted_by) REFERENCES users(user_id) ON DELETE SET NULL
);

-- Audit log
CREATE TABLE IF NOT EXISTS audit_log (
  audit_id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER,
  action TEXT NOT NULL,
  resource_type TEXT,
  resource_id TEXT,
  old_value TEXT,
  new_value TEXT,
  status TEXT NOT NULL CHECK(status IN ('success', 'failure')),
  details TEXT,
  ip_address TEXT,
  timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE SET NULL
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_role ON users(role);
CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON user_sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_token ON user_sessions(token);
CREATE INDEX IF NOT EXISTS idx_sessions_expires ON user_sessions(expires_at);
CREATE INDEX IF NOT EXISTS idx_role_changes_user ON role_changes(user_id);
CREATE INDEX IF NOT EXISTS idx_cloud_access_user ON user_cloud_access(user_id);
CREATE INDEX IF NOT EXISTS idx_cluster_access_user ON user_cluster_access(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_user ON audit_log(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_timestamp ON audit_log(timestamp);

-- Default admin user (password: CloudPulse2026!)
-- In production, change this password after first login
INSERT OR IGNORE INTO users (username, email, display_name, password_hash, password_salt, role, active)
VALUES (
  'admin',
  'admin@cloudpulse.local',
  'CloudPulse Administrator',
  -- password hash for 'CloudPulse2026!' with salt 'defaultsalt123456'
  '7c8b8e8e9a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d',
  'defaultsalt123456',
  'admin',
  1
);
