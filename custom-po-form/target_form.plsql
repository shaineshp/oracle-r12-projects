-- Forms program units for a TEMPLATE-based XXPO_CUSTOM.fmb.
-- Header block XXPO_HEADER uses XXPO_ENTRY_HEADERS.
-- Detail block XXPO_LINES uses XXPO_ENTRY_LINES, joined by DRAFT_ID.
-- Read README for properties, LOVs, PRE-INSERT and edit guards.

PROCEDURE XXPO_STARTUP IS
BEGIN
  MO_GLOBAL.INIT('PO');
  GO_BLOCK('XXPO_HEADER');
  CREATE_RECORD;
  :XXPO_HEADER.STATUS := 'DRAFT';
END;

PROCEDURE XXPO_POST IS
  l_request_id NUMBER;
BEGIN
  -- Validate and save the custom draft before enqueueing the import.
  DO_KEY('COMMIT_FORM');
  IF NOT FORM_SUCCESS OR :SYSTEM.FORM_STATUS <> 'QUERY' THEN
    RAISE FORM_TRIGGER_FAILURE;
  END IF;
  IF :XXPO_HEADER.DRAFT_ID IS NULL THEN
    RAISE FORM_TRIGGER_FAILURE;
  END IF;
  XXPO_ENTRY_PKG.POST_PO(:XXPO_HEADER.DRAFT_ID, l_request_id);
  -- The form is already saved; only the package's interface/request work is
  -- pending. Forms_DDL commits that work without altering form record state.
  FORMS_DDL('COMMIT');
  IF NOT FORM_SUCCESS THEN RAISE FORM_TRIGGER_FAILURE; END IF;
  :XXPO_CONTROL.REQUEST_ID := l_request_id;
  FND_MESSAGE.SET_STRING('Submitted for PO import. Request ID: ' || TO_CHAR(l_request_id));
  FND_MESSAGE.SHOW;
  -- Requery the same draft and disable edits via WHEN-NEW-RECORD-INSTANCE.
  GO_BLOCK('XXPO_HEADER');
  EXECUTE_QUERY;
EXCEPTION
  WHEN FORM_TRIGGER_FAILURE THEN RAISE;
  WHEN OTHERS THEN
    -- Clear the saved form buffer by requerying after a posting error.
    FND_MESSAGE.SET_STRING(SUBSTR(SQLERRM, 1, 1800));
    FND_MESSAGE.ERROR;
    RAISE FORM_TRIGGER_FAILURE;
END;

PROCEDURE XXPO_REFRESH IS
BEGIN
  IF :SYSTEM.FORM_STATUS = 'CHANGED' THEN
    FND_MESSAGE.SET_STRING('Save draft changes before refreshing import status.');
    FND_MESSAGE.ERROR;
    RAISE FORM_TRIGGER_FAILURE;
  END IF;
  IF :XXPO_HEADER.DRAFT_ID IS NOT NULL THEN
    XXPO_ENTRY_PKG.REFRESH_STATUS(:XXPO_HEADER.DRAFT_ID);
    FORMS_DDL('COMMIT');
    IF NOT FORM_SUCCESS THEN RAISE FORM_TRIGGER_FAILURE; END IF;
    GO_BLOCK('XXPO_HEADER');
    EXECUTE_QUERY;
  END IF;
END;
