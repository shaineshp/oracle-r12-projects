-- DBA-run grants; replace XXPO_APEX with the actual APEX parsing schema.
-- Apply via the site's registered custom schema / R12.2 patching process.
GRANT EXECUTE ON apps.xxpo_apex_api TO xxpo_apex;
CREATE OR REPLACE SYNONYM xxpo_apex.xxpo_apex_api FOR apps.xxpo_apex_api;

-- No grants on staging, identity mapping, EBS base or interface tables to APEX.
-- The package owner needs direct privileges on the custom schema objects.
