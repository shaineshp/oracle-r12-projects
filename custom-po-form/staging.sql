-- Development DDL. Install tables/sequences in your registered custom schema,
-- expose approved APPS synonyms/grants, and follow your R12.2 editioning process.
-- Do not rerun against an existing installation without a migration.
CREATE TABLE xxpo_entry_headers (
  draft_id NUMBER PRIMARY KEY,
  org_id NUMBER NOT NULL,
  vendor_id NUMBER NOT NULL,
  vendor_site_id NUMBER NOT NULL,
  agent_id NUMBER NOT NULL,
  currency_code VARCHAR2(15) NOT NULL,
  bill_to_location_id NUMBER NOT NULL,
  ship_to_location_id NUMBER NOT NULL,
  terms_id NUMBER NOT NULL,
  status VARCHAR2(20) DEFAULT 'DRAFT' NOT NULL,
  interface_header_id NUMBER,
  request_id NUMBER,
  po_header_id NUMBER,
  creation_date DATE DEFAULT SYSDATE NOT NULL,
  created_by NUMBER NOT NULL,
  last_update_date DATE DEFAULT SYSDATE NOT NULL,
  last_updated_by NUMBER NOT NULL,
  last_update_login NUMBER,
  CONSTRAINT xxpo_entry_status_ck CHECK
    (status IN ('DRAFT', 'SUBMITTED', 'IMPORTED', 'REJECTED'))
);
CREATE SEQUENCE xxpo_entry_headers_s;

-- Freeze business data once queued; the package can still reconcile status.
CREATE OR REPLACE TRIGGER xxpo_entry_headers_guard
BEFORE UPDATE OR DELETE ON xxpo_entry_headers
FOR EACH ROW
BEGIN
  IF :OLD.status <> 'DRAFT' THEN
    IF DELETING THEN
      raise_application_error(-20022, 'Posted drafts cannot be deleted.');
    ELSE
      IF :NEW.status = 'DRAFT'
         OR NVL(:NEW.org_id, -1) <> :OLD.org_id
         OR NVL(:NEW.vendor_id, -1) <> :OLD.vendor_id
         OR NVL(:NEW.vendor_site_id, -1) <> :OLD.vendor_site_id
         OR NVL(:NEW.agent_id, -1) <> :OLD.agent_id
         OR NVL(:NEW.currency_code, '?') <> :OLD.currency_code
         OR NVL(:NEW.bill_to_location_id, -1) <> :OLD.bill_to_location_id
         OR NVL(:NEW.ship_to_location_id, -1) <> :OLD.ship_to_location_id
         OR NVL(:NEW.terms_id, -1) <> :OLD.terms_id
         OR NVL(:NEW.created_by, -1) <> :OLD.created_by
         OR NVL(:NEW.draft_id, -1) <> :OLD.draft_id THEN
        raise_application_error(-20023, 'Posted draft business fields cannot be changed.');
      END IF;
    END IF;
  END IF;
END;
/

CREATE TABLE xxpo_entry_lines (
  draft_line_id NUMBER PRIMARY KEY,
  draft_id NUMBER NOT NULL REFERENCES xxpo_entry_headers(draft_id),
  line_num NUMBER NOT NULL,
  line_type_id NUMBER NOT NULL,
  item_id NUMBER,
  item_description VARCHAR2(240) NOT NULL,
  category_id NUMBER NOT NULL,
  unit_of_measure VARCHAR2(25) NOT NULL,
  quantity NUMBER NOT NULL,
  unit_price NUMBER NOT NULL,
  need_by_date DATE NOT NULL,
  ship_to_organization_id NUMBER NOT NULL,
  destination_type_code VARCHAR2(25) NOT NULL,
  charge_account_id NUMBER NOT NULL,
  creation_date DATE DEFAULT SYSDATE NOT NULL,
  created_by NUMBER NOT NULL,
  last_update_date DATE DEFAULT SYSDATE NOT NULL,
  last_updated_by NUMBER NOT NULL,
  last_update_login NUMBER,
  CONSTRAINT xxpo_entry_line_uq UNIQUE (draft_id, line_num),
  CONSTRAINT xxpo_entry_qty_ck CHECK (quantity > 0),
  CONSTRAINT xxpo_entry_price_ck CHECK (unit_price >= 0),
  CONSTRAINT xxpo_entry_num_ck CHECK (line_num > 0 AND line_num = TRUNC(line_num)),
  CONSTRAINT xxpo_entry_dest_ck CHECK (destination_type_code IN ('EXPENSE', 'INVENTORY'))
);
CREATE SEQUENCE xxpo_entry_lines_s;

-- Serialize line edits with the parent lock used by POST_PO. Stops a line from
-- changing underneath a concurrent post, and freezes posted draft lines.
CREATE OR REPLACE TRIGGER xxpo_entry_lines_guard
BEFORE INSERT OR UPDATE OR DELETE ON xxpo_entry_lines
FOR EACH ROW
DECLARE
  l_draft_id NUMBER;
  l_status VARCHAR2(20);
BEGIN
  IF UPDATING AND :NEW.draft_id <> :OLD.draft_id THEN
    raise_application_error(-20020, 'A line cannot be moved to another draft.');
  END IF;
  IF DELETING THEN l_draft_id := :OLD.draft_id;
  ELSE l_draft_id := :NEW.draft_id; END IF;
  SELECT status INTO l_status FROM xxpo_entry_headers
   WHERE draft_id = l_draft_id FOR UPDATE;
  IF l_status <> 'DRAFT' THEN
    raise_application_error(-20021, 'Posted purchase order draft lines cannot be edited.');
  END IF;
END;
/
