-- Compile using APPS access to the custom staging objects and PO interfaces.
-- Validate on your EBS release before deployment. No direct PO base-table DML.
CREATE OR REPLACE PACKAGE xxpo_entry_pkg AUTHID DEFINER AS
  PROCEDURE post_po(p_draft_id NUMBER, x_request_id OUT NUMBER);
  PROCEDURE refresh_status(p_draft_id NUMBER);
END xxpo_entry_pkg;
/
CREATE OR REPLACE PACKAGE BODY xxpo_entry_pkg AS
  PROCEDURE authorize(p_org_id NUMBER, p_created_by NUMBER) IS
  BEGIN
    IF NVL(fnd_global.user_id, -1) < 0
       OR NVL(p_created_by, -1) <> fnd_global.user_id THEN
      raise_application_error(-20001, 'This draft is not owned by the current EBS user.');
    END IF;
    IF NOT fnd_function.test('XXPO_CUSTOM_PO') THEN
      raise_application_error(-20002, 'The current responsibility cannot create a custom PO.');
    END IF;
    mo_global.init('PO');
    IF NVL(mo_global.check_access(p_org_id), 'N') <> 'Y' THEN
      raise_application_error(-20003, 'Operating unit is not accessible.');
    END IF;
  END;

  PROCEDURE post_po(p_draft_id NUMBER, x_request_id OUT NUMBER) IS
    h xxpo_entry_headers%ROWTYPE;
    l_count NUMBER;
    l_header_id NUMBER;
    l_line_id NUMBER;
    l_distribution_id NUMBER;
    l_request NUMBER;
  BEGIN
    x_request_id := NULL;
    SAVEPOINT xxpo_post;
    SELECT * INTO h FROM xxpo_entry_headers
     WHERE draft_id = p_draft_id FOR UPDATE;
    authorize(h.org_id, h.created_by);

    -- Lock + persisted request ID make double-clicks/repeated posts idempotent.
    IF h.status <> 'DRAFT' THEN
      IF h.request_id IS NOT NULL THEN
        x_request_id := h.request_id;
        RETURN;
      END IF;
      raise_application_error(-20004, 'Draft is not available for posting.');
    END IF;

    SELECT COUNT(*) INTO l_count FROM xxpo_entry_lines WHERE draft_id = p_draft_id;
    IF l_count = 0 THEN
      raise_application_error(-20005, 'Enter at least one purchase order line.');
    END IF;

    SELECT COUNT(*) INTO l_count
      FROM ap_supplier_sites_all s
     WHERE s.vendor_site_id = h.vendor_site_id
       AND s.vendor_id = h.vendor_id AND s.org_id = h.org_id
       AND s.purchasing_site_flag = 'Y'
       AND (s.inactive_date IS NULL OR s.inactive_date > SYSDATE);
    IF l_count <> 1 THEN
      raise_application_error(-20006, 'Select an active purchasing site for this supplier and OU.');
    END IF;

    FOR ln IN (SELECT * FROM xxpo_entry_lines WHERE draft_id = p_draft_id) LOOP
      SELECT COUNT(*) INTO l_count FROM po_line_types_b
       WHERE line_type_id = ln.line_type_id AND order_type_lookup_code = 'QUANTITY';
      IF l_count <> 1 THEN
        raise_application_error(-20007, 'This form supports quantity-based PO line types.');
      END IF;
      IF TRUNC(ln.need_by_date) < TRUNC(SYSDATE) THEN
        raise_application_error(-20008, 'Need-by date must be today or later.');
      END IF;
      IF ln.item_id IS NOT NULL THEN
        SELECT COUNT(*) INTO l_count FROM mtl_system_items_b
         WHERE inventory_item_id = ln.item_id
           AND organization_id = ln.ship_to_organization_id
           AND purchasing_enabled_flag = 'Y';
        IF l_count <> 1 THEN
          raise_application_error(-20009, 'Item is not purchasing-enabled in the receiving organization.');
        END IF;
      END IF;
    END LOOP;

    -- PDOI validates remaining supplier, buyer, UOM, account and setup rules.
    mo_global.set_policy_context('S', h.org_id);
    SELECT po_headers_interface_s.NEXTVAL INTO l_header_id FROM dual;
    INSERT INTO po_headers_interface (
      interface_header_id, batch_id, interface_source_code,
      process_code, action, org_id, document_type_code,
      vendor_id, vendor_site_id, agent_id, currency_code,
      bill_to_location_id, ship_to_location_id, terms_id, approval_status,
      creation_date, created_by, last_update_date, last_updated_by, last_update_login
    ) VALUES (
      l_header_id, l_header_id, 'XXPO_CUSTOM',
      'PENDING', 'ORIGINAL', h.org_id, 'STANDARD',
      h.vendor_id, h.vendor_site_id, h.agent_id, h.currency_code,
      h.bill_to_location_id, h.ship_to_location_id, h.terms_id, 'INCOMPLETE',
      SYSDATE, fnd_global.user_id, SYSDATE, fnd_global.user_id, fnd_global.login_id
    );

    FOR ln IN (SELECT * FROM xxpo_entry_lines
                WHERE draft_id = p_draft_id ORDER BY line_num) LOOP
      SELECT po_lines_interface_s.NEXTVAL INTO l_line_id FROM dual;
      INSERT INTO po_lines_interface (
        interface_header_id, interface_line_id, line_num, shipment_num,
        action, process_code, line_type_id, item_id, item_description,
        category_id, unit_of_measure, quantity, unit_price, need_by_date,
        ship_to_organization_id, ship_to_location_id,
        creation_date, created_by, last_update_date, last_updated_by, last_update_login
      ) VALUES (
        l_header_id, l_line_id, ln.line_num, 1,
        'ORIGINAL', 'PENDING', ln.line_type_id, ln.item_id, ln.item_description,
        ln.category_id, ln.unit_of_measure, ln.quantity, ln.unit_price, ln.need_by_date,
        ln.ship_to_organization_id, h.ship_to_location_id,
        SYSDATE, fnd_global.user_id, SYSDATE, fnd_global.user_id, fnd_global.login_id
      );
      SELECT po_distributions_interface_s.NEXTVAL INTO l_distribution_id FROM dual;
      INSERT INTO po_distributions_interface (
        interface_header_id, interface_line_id, interface_distribution_id,
        distribution_num, org_id, quantity_ordered, destination_type_code,
        destination_organization_id, deliver_to_location_id, charge_account_id,
        creation_date, created_by, last_update_date, last_updated_by, last_update_login
      ) VALUES (
        l_header_id, l_line_id, l_distribution_id,
        1, h.org_id, ln.quantity, ln.destination_type_code,
        ln.ship_to_organization_id, h.ship_to_location_id, ln.charge_account_id,
        SYSDATE, fnd_global.user_id, SYSDATE, fnd_global.user_id, fnd_global.login_id
      );
    END LOOP;

    -- Verify these argument positions against the installed POXPOPDOI definition.
    fnd_request.set_org_id(h.org_id);
    l_request := fnd_request.submit_request(
      application => 'PO', program => 'POXPOPDOI', sub_request => FALSE,
      argument1 => NULL, argument2 => 'STANDARD', argument3 => NULL,
      argument4 => 'N', argument5 => 'N', argument6 => 'INCOMPLETE',
      argument7 => NULL, argument8 => TO_CHAR(l_header_id),
      argument9 => TO_CHAR(h.org_id), argument10 => 'N', argument11 => CHR(0)
    );
    IF NVL(l_request, 0) = 0 THEN
      raise_application_error(-20010,
        SUBSTR('Import request was not submitted: ' || fnd_message.get, 1, 2000));
    END IF;
    UPDATE xxpo_entry_headers
       SET status = 'SUBMITTED', interface_header_id = l_header_id,
           request_id = l_request, last_update_date = SYSDATE,
           last_updated_by = fnd_global.user_id
     WHERE draft_id = p_draft_id;
    x_request_id := l_request;
    -- Caller commits staging, interface rows and request in one transaction.
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK TO xxpo_post;
      RAISE;
  END;

  PROCEDURE refresh_status(p_draft_id NUMBER) IS
    h xxpo_entry_headers%ROWTYPE;
    l_process_code VARCHAR2(25);
    l_po_header_id NUMBER;
  BEGIN
    SELECT * INTO h FROM xxpo_entry_headers WHERE draft_id = p_draft_id FOR UPDATE;
    authorize(h.org_id, h.created_by);
    IF h.interface_header_id IS NULL THEN RETURN; END IF;
    BEGIN
      SELECT process_code, po_header_id INTO l_process_code, l_po_header_id
        FROM po_headers_interface WHERE interface_header_id = h.interface_header_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        -- Do not infer success when interface data was purged externally.
        RETURN;
    END;
    IF l_process_code = 'ACCEPTED' AND l_po_header_id IS NOT NULL THEN
      UPDATE xxpo_entry_headers SET status = 'IMPORTED', po_header_id = l_po_header_id,
        last_update_date = SYSDATE, last_updated_by = fnd_global.user_id
        WHERE draft_id = p_draft_id;
    ELSIF l_process_code IN ('REJECTED', 'VALIDATE AND REJECT') THEN
      UPDATE xxpo_entry_headers SET status = 'REJECTED',
        last_update_date = SYSDATE, last_updated_by = fnd_global.user_id
        WHERE draft_id = p_draft_id;
    END IF;
  END;
END xxpo_entry_pkg;
/
SHOW ERRORS
