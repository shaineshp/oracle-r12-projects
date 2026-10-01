-- Read-only installation checks. Run with development APPS access.
SELECT application_column_name, end_user_column_name, enabled_flag,
       required_flag, display_flag, default_value
  FROM fnd_descr_flex_column_usages
 WHERE application_id = 201
   AND descriptive_flexfield_name = '$SRS$.POXPOPDOI'
 ORDER BY column_seq_num;

SELECT owner, table_name, column_name, data_type, data_length
  FROM all_tab_columns
 WHERE table_name IN ('PO_HEADERS_INTERFACE', 'PO_LINES_INTERFACE',
                      'PO_DISTRIBUTIONS_INTERFACE')
 ORDER BY table_name, column_id;

SELECT concurrent_program_name, user_concurrent_program_name, enabled_flag
  FROM fnd_concurrent_programs_vl
 WHERE concurrent_program_name = 'POXPOPDOI';

SELECT object_name, object_type, status
  FROM user_objects WHERE object_name = 'XXPO_ENTRY_PKG';
SELECT line, position, text
  FROM user_errors WHERE name = 'XXPO_ENTRY_PKG'
 ORDER BY sequence;
