-- SQL*Plus / SQLcl entry point for an already provisioned EBS integration schema.
-- First install staging.sql + apex/schema.sql in the custom owning schema and
-- provision direct grants/synonyms described in README.md. This script does not
-- create custom tables in APPS or grant broad privileges to the APEX schema.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET DEFINE OFF
SET SERVEROUTPUT ON

DECLARE
  l_count NUMBER;
BEGIN
  EXECUTE IMMEDIATE 'select count(*) from xxpo_entry_headers where 1=0' INTO l_count;
  EXECUTE IMMEDIATE 'select count(apex_revision) from xxpo_entry_headers where 1=0' INTO l_count;
  EXECUTE IMMEDIATE 'select count(*) from xxpo_entry_lines where 1=0' INTO l_count;
  EXECUTE IMMEDIATE 'select count(*) from xxpo_apex_user_map where 1=0' INTO l_count;
  dbms_output.put_line('Custom staging objects and APEX migration are accessible.');
END;
/

@@../xxpo_entry_pkg.sql
@@xxpo_apex_api.sql

DECLARE
  l_errors NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_errors FROM user_errors
   WHERE name IN ('XXPO_ENTRY_PKG', 'XXPO_APEX_API') AND attribute = 'ERROR';
  FOR e IN (SELECT name, type, line, position, text FROM user_errors
             WHERE name IN ('XXPO_ENTRY_PKG', 'XXPO_APEX_API')
               AND attribute = 'ERROR' ORDER BY name, type, sequence) LOOP
    dbms_output.put_line(e.name || ' ' || e.type || ':' || e.line || ':' || e.position || ' ' || e.text);
  END LOOP;
  IF l_errors > 0 THEN
    raise_application_error(-20050, 'Package compilation failed. Resolve the reported errors before proceeding.');
  END IF;
  dbms_output.put_line('Packages compiled. Complete parsing-schema grants, user mappings, and APEX page setup.');
END;
/

@@../preflight.sql
