-- Install in the custom schema that owns XXPO_ENTRY_HEADERS.
-- Requires ../staging.sql; this is an additive, one-time migration.
ALTER TABLE xxpo_entry_headers ADD (apex_revision NUMBER DEFAULT 0 NOT NULL);

-- DBA-controlled identity bindings. No browser-supplied EBS identity is trusted.
CREATE TABLE xxpo_apex_user_map (
  application_id NUMBER NOT NULL,
  apex_username VARCHAR2(255) NOT NULL,
  ebs_user_id NUMBER NOT NULL,
  responsibility_id NUMBER NOT NULL,
  responsibility_application_id NUMBER NOT NULL,
  enabled_flag VARCHAR2(1) DEFAULT 'Y' NOT NULL,
  CONSTRAINT xxpo_apex_user_map_pk PRIMARY KEY (application_id, apex_username),
  CONSTRAINT xxpo_apex_user_case_ck CHECK (apex_username = UPPER(apex_username)),
  CONSTRAINT xxpo_apex_user_enabled_ck CHECK (enabled_flag IN ('Y','N'))
);

-- Create APPS synonyms/grants for the new table/column through your normal
-- custom schema deployment. Do NOT grant the APEX parsing schema table DML.
