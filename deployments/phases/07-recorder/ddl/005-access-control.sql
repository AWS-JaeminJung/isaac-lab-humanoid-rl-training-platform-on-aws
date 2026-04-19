-- ClickHouse Access Control: Users, Roles, Row Policies
-- Keycloak roles (researcher, engineer, admin) map 1:1 to ClickHouse roles.

-- Service account (callback, Fluent Bit INSERT only)
CREATE USER IF NOT EXISTS writer IDENTIFIED BY '${CLICKHOUSE_WRITER_PASSWORD}';
CREATE ROLE IF NOT EXISTS role_writer;
GRANT INSERT ON training_metrics TO role_writer;
GRANT INSERT ON training_raw_logs TO role_writer;
GRANT INSERT ON training_summary TO role_writer;
GRANT INSERT ON platform_logs TO role_writer;
GRANT INSERT ON node_logs TO role_writer;
GRANT role_writer TO writer;

-- Researcher (own workflow data only, no platform_logs)
CREATE USER IF NOT EXISTS researcher IDENTIFIED BY '${CLICKHOUSE_RESEARCHER_PASSWORD}';
CREATE ROLE IF NOT EXISTS role_researcher;
GRANT SELECT ON training_metrics TO role_researcher;
GRANT SELECT ON training_raw_logs TO role_researcher;
GRANT SELECT ON training_summary TO role_researcher;
GRANT role_researcher TO researcher;

-- Engineer (full read access including platform_logs)
CREATE USER IF NOT EXISTS engineer IDENTIFIED BY '${CLICKHOUSE_ENGINEER_PASSWORD}';
CREATE ROLE IF NOT EXISTS role_engineer;
GRANT SELECT ON training_metrics TO role_engineer;
GRANT SELECT ON training_raw_logs TO role_engineer;
GRANT SELECT ON training_summary TO role_engineer;
GRANT SELECT ON platform_logs TO role_engineer;
GRANT SELECT ON node_logs TO role_engineer;
GRANT role_engineer TO engineer;

-- Admin (full access)
CREATE USER IF NOT EXISTS ch_admin IDENTIFIED BY '${CLICKHOUSE_ADMIN_PASSWORD}';
GRANT ALL ON *.* TO ch_admin WITH GRANT OPTION;

-- Row Policies: researcher sees only own workflows (workflow_id prefix = username)
CREATE ROW POLICY IF NOT EXISTS researcher_own_metrics
ON training_metrics FOR SELECT
USING workflow_id LIKE concat(currentUser(), '-%')
TO role_researcher;

CREATE ROW POLICY IF NOT EXISTS engineer_all_metrics
ON training_metrics FOR SELECT
USING 1=1
TO role_engineer;

CREATE ROW POLICY IF NOT EXISTS researcher_own_raw_logs
ON training_raw_logs FOR SELECT
USING workflow_id LIKE concat(currentUser(), '-%')
TO role_researcher;

CREATE ROW POLICY IF NOT EXISTS engineer_all_raw_logs
ON training_raw_logs FOR SELECT
USING 1=1
TO role_engineer;
