-- Compile in APPS (or the site's EBS integration schema with direct grants).
-- Grant the APEX parsing schema EXECUTE on this package only.
CREATE OR REPLACE PACKAGE xxpo_apex_api AUTHID DEFINER AS
  FUNCTION is_authorized RETURN BOOLEAN;
  PROCEDURE dispatch(
    p_action VARCHAR2, p_draft_id NUMBER DEFAULT NULL,
    p_kind VARCHAR2 DEFAULT NULL, p_search VARCHAR2 DEFAULT NULL,
    p_org_id NUMBER DEFAULT NULL, p_vendor_id NUMBER DEFAULT NULL,
    p_receiving_org_id NUMBER DEFAULT NULL, p_payload CLOB DEFAULT NULL);
END xxpo_apex_api;
/
CREATE OR REPLACE PACKAGE BODY xxpo_apex_api AS
  PROCEDURE initialize_identity IS
    m xxpo_apex_user_map%ROWTYPE;
    l_count NUMBER;
    l_username VARCHAR2(255) := UPPER(sys_context('APEX$SESSION', 'APP_USER'));
  BEGIN
    IF l_username IS NULL OR l_username IN ('NOBODY', 'APEX_PUBLIC_USER')
       OR sys_context('APEX$SESSION', 'APP_SESSION') IS NULL THEN
      raise_application_error(-20030, 'Sign in to access purchase order entry.');
    END IF;
    SELECT * INTO m FROM xxpo_apex_user_map
     WHERE application_id = apex_application.g_flow_id
       AND apex_username = l_username AND enabled_flag = 'Y';
    SELECT COUNT(*) INTO l_count
      FROM fnd_user u JOIN fnd_user_resp_groups g ON g.user_id = u.user_id
      JOIN fnd_responsibility r ON r.responsibility_id = g.responsibility_id
                              AND r.application_id = g.responsibility_application_id
     WHERE u.user_id = m.ebs_user_id
       AND g.responsibility_id = m.responsibility_id
       AND g.responsibility_application_id = m.responsibility_application_id
       AND g.security_group_id = 0
       AND (u.start_date IS NULL OR u.start_date <= SYSDATE)
       AND (u.end_date IS NULL OR u.end_date > SYSDATE)
       AND (g.start_date IS NULL OR g.start_date <= SYSDATE)
       AND (g.end_date IS NULL OR g.end_date > SYSDATE)
       AND (r.start_date IS NULL OR r.start_date <= SYSDATE)
       AND (r.end_date IS NULL OR r.end_date > SYSDATE);
    IF l_count = 0 THEN
      raise_application_error(-20031, 'Your Purchasing responsibility is not active.');
    END IF;
    -- Reinitialize on EVERY callback: ORDS database sessions are pooled.
    fnd_global.apps_initialize(m.ebs_user_id, m.responsibility_id,
                              m.responsibility_application_id);
    mo_global.init('PO');
    IF NOT fnd_function.test('XXPO_CUSTOM_PO') THEN
      raise_application_error(-20032, 'You do not have access to custom PO entry.');
    END IF;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      raise_application_error(-20033, 'Your APEX account has no Purchasing access mapping.');
  END;

  FUNCTION is_authorized RETURN BOOLEAN IS
  BEGIN
    initialize_identity;
    RETURN TRUE;
  EXCEPTION WHEN OTHERS THEN RETURN FALSE;
  END;

  PROCEDURE require_org(p_org_id NUMBER) IS
  BEGIN
    IF p_org_id IS NULL OR NVL(mo_global.check_access(p_org_id), 'N') <> 'Y' THEN
      raise_application_error(-20034, 'Select an accessible operating unit.');
    END IF;
  END;

  PROCEDURE get_owned(p_draft_id NUMBER, h OUT xxpo_entry_headers%ROWTYPE) IS
  BEGIN
    SELECT * INTO h FROM xxpo_entry_headers
     WHERE draft_id = p_draft_id AND created_by = fnd_global.user_id
       AND mo_global.check_access(org_id) = 'Y' FOR UPDATE;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    raise_application_error(-20035, 'Purchase order draft was not found or is not accessible.');
  END;

  PROCEDURE write_draft(p_draft_id NUMBER) IS
    h xxpo_entry_headers%ROWTYPE;
    c SYS_REFCURSOR;
  BEGIN
    get_owned(p_draft_id, h);
    OPEN c FOR SELECT eh.*, o.name org_id_label, s.vendor_name vendor_id_label,
      ss.vendor_site_code vendor_site_id_label, p.full_name agent_id_label,
      bl.location_code bill_to_location_id_label, sl.location_code ship_to_location_id_label,
      t.name terms_id_label
      FROM xxpo_entry_headers eh
      JOIN hr_operating_units o ON o.organization_id = eh.org_id
      JOIN ap_suppliers s ON s.vendor_id = eh.vendor_id
      JOIN ap_supplier_sites_all ss ON ss.vendor_site_id = eh.vendor_site_id
      LEFT JOIN per_all_people_f p ON p.person_id = eh.agent_id
        AND SYSDATE BETWEEN p.effective_start_date AND p.effective_end_date
      LEFT JOIN hr_locations_all bl ON bl.location_id = eh.bill_to_location_id
      LEFT JOIN hr_locations_all sl ON sl.location_id = eh.ship_to_location_id
      LEFT JOIN ap_terms_tl t ON t.term_id = eh.terms_id AND t.language = USERENV('LANG')
      WHERE eh.draft_id = h.draft_id;
    apex_json.write('header', c);
    OPEN c FOR SELECT el.*, lt.line_type line_type_id_label,
      i.concatenated_segments item_id_label, cat.concatenated_segments category_id_label,
      o.organization_code ship_to_organization_id_label,
      ac.concatenated_segments charge_account_id_label
      FROM xxpo_entry_lines el
      LEFT JOIN po_line_types_vl lt ON lt.line_type_id = el.line_type_id
      LEFT JOIN mtl_system_items_kfv i ON i.inventory_item_id = el.item_id
        AND i.organization_id = el.ship_to_organization_id
      LEFT JOIN mtl_categories_kfv cat ON cat.category_id = el.category_id
      LEFT JOIN org_organization_definitions o ON o.organization_id = el.ship_to_organization_id
      LEFT JOIN gl_code_combinations_kfv ac ON ac.code_combination_id = el.charge_account_id
      WHERE el.draft_id = h.draft_id ORDER BY el.line_num;
    apex_json.write('lines', c);
    OPEN c FOR SELECT segment1 po_number, authorization_status
      FROM po_headers_all WHERE po_header_id = h.po_header_id AND org_id = h.org_id;
    apex_json.write('purchase_order', c);
    OPEN c FOR SELECT phase_code, status_code, completion_text
      FROM fnd_concurrent_requests WHERE request_id = h.request_id;
    apex_json.write('request', c);
    OPEN c FOR SELECT * FROM po_interface_errors
      WHERE interface_header_id = h.interface_header_id;
    apex_json.write('errors', c);
  END;

  PROCEDURE save_draft(p_payload CLOB, p_post BOOLEAN, x_draft_id OUT NUMBER) IS
    j apex_json.t_values;
    h xxpo_entry_headers%ROWTYPE;
    l_id NUMBER;
    l_revision NUMBER;
    l_request NUMBER;
    l_count NUMBER;
    l_org NUMBER;
    l_receiving_org NUMBER;
    l_valid NUMBER;
    entry xxpo_entry_headers%ROWTYPE;
    detail xxpo_entry_lines%ROWTYPE;
  BEGIN
    apex_json.parse(j, p_payload);
    l_id := apex_json.get_number('draft_id', p_values => j);
    IF p_post AND l_id IS NULL THEN
      raise_application_error(-20043, 'Save the draft before posting to Purchasing.');
    END IF;
    l_org := apex_json.get_number('header.org_id', p_values => j);
    require_org(l_org);
    entry.vendor_id := apex_json.get_number('header.vendor_id', p_values => j);
    entry.vendor_site_id := apex_json.get_number('header.vendor_site_id', p_values => j);
    entry.agent_id := apex_json.get_number('header.agent_id', p_values => j);
    entry.currency_code := apex_json.get_varchar2('header.currency_code', p_values => j);
    entry.bill_to_location_id := apex_json.get_number('header.bill_to_location_id', p_values => j);
    entry.ship_to_location_id := apex_json.get_number('header.ship_to_location_id', p_values => j);
    entry.terms_id := apex_json.get_number('header.terms_id', p_values => j);
    l_count := apex_json.get_count('lines', p_values => j);
    IF NVL(l_count, 0) < 1 OR l_count > 200 THEN
      raise_application_error(-20036, 'Enter between 1 and 200 PO lines.');
    END IF;
    IF l_id IS NOT NULL THEN
      get_owned(l_id, h);
      -- A repeated POST for an already queued draft returns its existing result.
      IF h.status <> 'DRAFT' THEN
        IF p_post AND h.request_id IS NOT NULL THEN x_draft_id := l_id; RETURN; END IF;
        raise_application_error(-20037, 'Submitted drafts cannot be edited.');
      END IF;
      l_revision := apex_json.get_number('revision', p_values => j);
      IF l_revision IS NULL OR l_revision <> h.apex_revision THEN
        raise_application_error(-20038, 'This draft changed in another session. Reload before saving.');
      END IF;
    ELSE
      SELECT xxpo_entry_headers_s.NEXTVAL INTO l_id FROM dual;
      INSERT INTO xxpo_entry_headers (
        draft_id, org_id, vendor_id, vendor_site_id, agent_id, currency_code,
        bill_to_location_id, ship_to_location_id, terms_id, created_by,
        last_updated_by, last_update_login
      ) VALUES (
        l_id, l_org,
        entry.vendor_id,
        entry.vendor_site_id,
        entry.agent_id,
        entry.currency_code,
        entry.bill_to_location_id,
        entry.ship_to_location_id,
        entry.terms_id,
        fnd_global.user_id, fnd_global.user_id, fnd_global.login_id
      );
    END IF;
    UPDATE xxpo_entry_headers SET
      org_id = l_org,
      vendor_id = entry.vendor_id,
      vendor_site_id = entry.vendor_site_id,
      agent_id = entry.agent_id,
      currency_code = entry.currency_code,
      bill_to_location_id = entry.bill_to_location_id,
      ship_to_location_id = entry.ship_to_location_id,
      terms_id = entry.terms_id,
      apex_revision = apex_revision + 1,
      last_update_date = SYSDATE, last_updated_by = fnd_global.user_id,
      last_update_login = fnd_global.login_id
    WHERE draft_id = l_id;
    DELETE FROM xxpo_entry_lines WHERE draft_id = l_id;
    FOR i IN 1 .. l_count LOOP
      detail.line_num := apex_json.get_number('lines[%d].line_num', i, p_values => j);
      detail.line_type_id := apex_json.get_number('lines[%d].line_type_id', i, p_values => j);
      detail.item_id := apex_json.get_number('lines[%d].item_id', i, p_values => j);
      detail.item_description := apex_json.get_varchar2('lines[%d].item_description', i, p_values => j);
      detail.category_id := apex_json.get_number('lines[%d].category_id', i, p_values => j);
      detail.unit_of_measure := apex_json.get_varchar2('lines[%d].unit_of_measure', i, p_values => j);
      detail.quantity := apex_json.get_number('lines[%d].quantity', i, p_values => j);
      detail.unit_price := apex_json.get_number('lines[%d].unit_price', i, p_values => j);
      detail.destination_type_code := apex_json.get_varchar2('lines[%d].destination_type_code', i, p_values => j);
      detail.charge_account_id := apex_json.get_number('lines[%d].charge_account_id', i, p_values => j);
      detail.need_by_date := TO_DATE(apex_json.get_varchar2('lines[%d].need_by_date', i, p_values => j), 'FXYYYY-MM-DD');
      l_receiving_org := apex_json.get_number('lines[%d].ship_to_organization_id', i, p_values => j);
      SELECT COUNT(*) INTO l_valid FROM org_organization_definitions
       WHERE organization_id = l_receiving_org AND operating_unit = l_org
         AND (disable_date IS NULL OR disable_date > SYSDATE);
      IF l_valid <> 1 THEN
        raise_application_error(-20044, 'Select an active receiving organization for the operating unit.');
      END IF;
      INSERT INTO xxpo_entry_lines (
        draft_line_id, draft_id, line_num, line_type_id, item_id, item_description,
        category_id, unit_of_measure, quantity, unit_price, need_by_date,
        ship_to_organization_id, destination_type_code, charge_account_id,
        created_by, last_updated_by, last_update_login
      ) VALUES (
        xxpo_entry_lines_s.NEXTVAL, l_id,
        detail.line_num,
        detail.line_type_id,
        detail.item_id,
        detail.item_description,
        detail.category_id,
        detail.unit_of_measure,
        detail.quantity,
        detail.unit_price,
        detail.need_by_date,
        l_receiving_org,
        detail.destination_type_code,
        detail.charge_account_id,
        fnd_global.user_id, fnd_global.user_id, fnd_global.login_id
      );
    END LOOP;
    IF p_post THEN xxpo_entry_pkg.post_po(l_id, l_request); END IF;
    x_draft_id := l_id;
  END;

  PROCEDURE lookup(p_kind VARCHAR2, p_search VARCHAR2, p_org_id NUMBER,
                   p_vendor_id NUMBER, p_receiving_org_id NUMBER) IS
    c SYS_REFCURSOR;
    l_sql VARCHAR2(12000);
    l_q VARCHAR2(200) := '%' || UPPER(SUBSTR(p_search, 1, 100)) || '%';
    l_id VARCHAR2(100) := SUBSTR(p_search, 1, 100);
    l_count NUMBER;
  BEGIN
    IF p_kind <> 'org_id' THEN require_org(p_org_id); END IF;
    IF p_kind = 'item_id' THEN
      SELECT COUNT(*) INTO l_count FROM org_organization_definitions
       WHERE organization_id = p_receiving_org_id AND operating_unit = p_org_id;
      IF l_count <> 1 THEN
        raise_application_error(-20039, 'Select a receiving organization for this operating unit first.');
      END IF;
    END IF;
    -- Each branch returns VALUE/LABEL. Query text is fixed; all input is bound.
    CASE p_kind
      WHEN 'org_id' THEN l_sql :=
        'select to_char(organization_id) value, name label from hr_operating_units where mo_global.check_access(organization_id) = ''Y''';
      WHEN 'vendor_id' THEN l_sql :=
        'select to_char(vendor_id) value, vendor_name label from ap_suppliers where (start_date_active is null or start_date_active <= sysdate) and (end_date_active is null or end_date_active > sysdate)';
      WHEN 'vendor_site_id' THEN l_sql :=
        'select to_char(vendor_site_id) value, vendor_site_code label from ap_supplier_sites_all where org_id = (select org_id from params) and vendor_id = (select vendor_id from params) and purchasing_site_flag = ''Y'' and (inactive_date is null or inactive_date > sysdate)';
      WHEN 'agent_id' THEN l_sql :=
        'select to_char(a.agent_id) value, p.full_name label from po_agents a join per_all_people_f p on p.person_id = a.agent_id where sysdate between p.effective_start_date and p.effective_end_date and (a.start_date_active is null or a.start_date_active <= sysdate) and (a.end_date_active is null or a.end_date_active > sysdate)';
      WHEN 'currency_code' THEN l_sql :=
        'select currency_code value, currency_code label from fnd_currencies where enabled_flag = ''Y'' and (start_date_active is null or start_date_active <= sysdate) and (end_date_active is null or end_date_active > sysdate)';
      WHEN 'bill_to_location_id' THEN l_sql :=
        'select to_char(location_id) value, location_code label from hr_locations_all where bill_to_site_flag = ''Y'' and (inactive_date is null or inactive_date > sysdate)';
      WHEN 'ship_to_location_id' THEN l_sql :=
        'select to_char(location_id) value, location_code label from hr_locations_all where ship_to_site_flag = ''Y'' and (inactive_date is null or inactive_date > sysdate)';
      WHEN 'terms_id' THEN l_sql :=
        'select to_char(b.term_id) value, t.name label from ap_terms_b b join ap_terms_tl t on t.term_id = b.term_id and t.language = userenv(''LANG'') where (b.start_date_active is null or b.start_date_active <= sysdate) and (b.end_date_active is null or b.end_date_active > sysdate)';
      WHEN 'line_type_id' THEN l_sql :=
        'select to_char(line_type_id) value, line_type label from po_line_types_vl where order_type_lookup_code = ''QUANTITY'' and (inactive_date is null or inactive_date > sysdate)';
      WHEN 'item_id' THEN l_sql :=
        'select to_char(inventory_item_id) value, concatenated_segments || '' - '' || description label from mtl_system_items_kfv where organization_id = (select receiving_org_id from params) and purchasing_enabled_flag = ''Y''';
      WHEN 'category_id' THEN l_sql :=
        'select to_char(category_id) value, concatenated_segments label from mtl_categories_kfv where (disable_date is null or disable_date > sysdate)';
      WHEN 'unit_of_measure' THEN l_sql :=
        'select unit_of_measure value, unit_of_measure label from mtl_units_of_measure_vl where disable_date is null or disable_date > sysdate';
      WHEN 'ship_to_organization_id' THEN l_sql :=
        'select to_char(organization_id) value, organization_code || '' - '' || organization_name label from org_organization_definitions where operating_unit = (select org_id from params) and (disable_date is null or disable_date > sysdate)';
      WHEN 'charge_account_id' THEN l_sql :=
        'select to_char(c.code_combination_id) value, c.concatenated_segments label from gl_code_combinations_kfv c join gl_ledgers l on l.chart_of_accounts_id = c.chart_of_accounts_id join hr_operating_units o on o.set_of_books_id = l.ledger_id where o.organization_id = (select org_id from params) and c.enabled_flag = ''Y'' and c.summary_flag = ''N'' and c.detail_posting_allowed_flag = ''Y'' and (c.start_date_active is null or c.start_date_active <= sysdate) and (c.end_date_active is null or c.end_date_active > sysdate)';
      ELSE raise_application_error(-20041, 'Unsupported lookup field.');
    END CASE;
    OPEN c FOR 'with params as (select :org_id org_id, :vendor_id vendor_id, :receiving_org_id receiving_org_id from dual) select value, label from (' ||
      l_sql || ') where upper(label) like :q or value = :id order by label fetch first 50 rows only'
      USING p_org_id, p_vendor_id, p_receiving_org_id, l_q, l_id;
    apex_json.write('rows', c);
  END;

  PROCEDURE dispatch(
    p_action VARCHAR2, p_draft_id NUMBER DEFAULT NULL,
    p_kind VARCHAR2 DEFAULT NULL, p_search VARCHAR2 DEFAULT NULL,
    p_org_id NUMBER DEFAULT NULL, p_vendor_id NUMBER DEFAULT NULL,
    p_receiving_org_id NUMBER DEFAULT NULL, p_payload CLOB DEFAULT NULL) IS
    c SYS_REFCURSOR;
    l_id NUMBER;
    h xxpo_entry_headers%ROWTYPE;
    l_output CLOB;
    l_message VARCHAR2(2000);
    l_savepoint BOOLEAN := FALSE;
  BEGIN
    initialize_identity;
    SAVEPOINT xxpo_apex_request;
    l_savepoint := TRUE;
    apex_json.initialize_clob_output;
    apex_json.open_object;
    apex_json.write('ok', TRUE);
    CASE UPPER(p_action)
      WHEN 'LIST' THEN
        OPEN c FOR SELECT h.draft_id, h.status, h.request_id, h.apex_revision,
          s.vendor_name supplier, o.name operating_unit, p.segment1 po_number
          FROM xxpo_entry_headers h
          JOIN ap_suppliers s ON s.vendor_id = h.vendor_id
          JOIN hr_operating_units o ON o.organization_id = h.org_id
          LEFT JOIN po_headers_all p ON p.po_header_id = h.po_header_id
          WHERE h.created_by = fnd_global.user_id AND mo_global.check_access(h.org_id) = 'Y'
          ORDER BY h.draft_id DESC FETCH FIRST 100 ROWS ONLY;
        apex_json.write('rows', c);
      WHEN 'LOOKUP' THEN lookup(p_kind, p_search, p_org_id, p_vendor_id, p_receiving_org_id);
      WHEN 'ITEM_DEFAULTS' THEN
        require_org(p_org_id);
        OPEN c FOR SELECT i.description, u.unit_of_measure
          FROM mtl_system_items_b i
          JOIN mtl_units_of_measure_vl u ON u.uom_code = i.primary_uom_code
          JOIN org_organization_definitions o ON o.organization_id = i.organization_id
          WHERE i.inventory_item_id = TO_NUMBER(p_search)
            AND i.organization_id = p_receiving_org_id
            AND o.operating_unit = p_org_id AND i.purchasing_enabled_flag = 'Y';
        apex_json.write('rows', c);
      WHEN 'LOAD' THEN write_draft(p_draft_id);
      WHEN 'SAVE' THEN
        save_draft(p_payload, FALSE, l_id);
        write_draft(l_id);
      WHEN 'POST' THEN
        save_draft(p_payload, TRUE, l_id);
        write_draft(l_id);
      WHEN 'REFRESH' THEN
        get_owned(p_draft_id, h);
        xxpo_entry_pkg.refresh_status(p_draft_id);
        write_draft(p_draft_id);
      ELSE raise_application_error(-20042, 'Unsupported purchase order action.');
    END CASE;
    apex_json.close_object;
    l_output := apex_json.get_clob_output;
    -- JSON and all database work succeeded; commit request+interfaces atomically.
    COMMIT;
    l_savepoint := FALSE;
    apex_util.prn(l_output, FALSE);
    apex_json.free_output;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_savepoint THEN ROLLBACK TO xxpo_apex_request; END IF;
      IF SQLCODE BETWEEN -20999 AND -20000 THEN
        l_message := REGEXP_REPLACE(SQLERRM, '^ORA-[0-9]+: *', '');
      ELSE
        l_message := 'The request could not be completed. Check required fields and contact your administrator.';
      END IF;
      apex_debug.error('XXPO API failure: %s', SQLERRM);
      apex_json.free_output;
      apex_json.open_object;
      apex_json.write('ok', FALSE);
      apex_json.write('message', l_message);
      apex_json.close_object;
  END;
END xxpo_apex_api;
/
SHOW ERRORS
