-- Administrator-only example. Replace values with real IDs after deployment.
-- The mapping is tied to an authenticated APEX username and application ID.
-- Never source these EBS identity values from browser page items or URL values.
INSERT INTO xxpo_apex_user_map (
  application_id, apex_username, ebs_user_id,
  responsibility_id, responsibility_application_id, enabled_flag
) VALUES (
  :application_id, UPPER(:authenticated_apex_username), :ebs_user_id,
  :purchasing_responsibility_id, :purchasing_application_id, 'Y'
);
COMMIT;
