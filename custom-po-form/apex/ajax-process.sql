-- Page-level Ajax Callback process named XXPO_API.
-- Require the page/application authentication and XXPO authorization scheme.
DECLARE
  l_payload CLOB;
BEGIN
  IF apex_application.g_f01.COUNT > 128 THEN
    raise_application_error(-20040, 'Purchase order payload is too large.');
  END IF;
  dbms_lob.createtemporary(l_payload, TRUE);
  FOR i IN 1 .. apex_application.g_f01.COUNT LOOP
    IF LENGTHB(apex_application.g_f01(i)) > 30000 THEN
      raise_application_error(-20040, 'Purchase order payload chunk is too large.');
    END IF;
    IF apex_application.g_f01(i) IS NOT NULL THEN
      dbms_lob.writeappend(l_payload, LENGTH(apex_application.g_f01(i)),
                          apex_application.g_f01(i));
    END IF;
  END LOOP;
  xxpo_apex_api.dispatch(
    p_action => apex_application.g_x01,
    p_draft_id => TO_NUMBER(apex_application.g_x02),
    p_kind => apex_application.g_x03,
    p_search => apex_application.g_x04,
    p_org_id => TO_NUMBER(apex_application.g_x05),
    p_vendor_id => TO_NUMBER(apex_application.g_x06),
    p_receiving_org_id => TO_NUMBER(apex_application.g_x07),
    p_payload => l_payload
  );
  dbms_lob.freetemporary(l_payload);
EXCEPTION
  WHEN OTHERS THEN
    IF dbms_lob.istemporary(l_payload) = 1 THEN
      dbms_lob.freetemporary(l_payload);
    END IF;
    RAISE;
END;
