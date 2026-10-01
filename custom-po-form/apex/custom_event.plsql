-- Alternative CUSTOM.EVENT branch for the APEX implementation.
-- Replace the URL with the application's approved HTTPS URL (session ID 0).
-- APEX authenticates the browser independently; no EBS credentials in the URL.
-- Reserve an unused Tools slot before installing SPECIAL15.
IF NAME_IN('SYSTEM.CURRENT_FORM') = 'POXPOEPO' THEN
  IF event_name IN ('WHEN-NEW-FORM-INSTANCE', 'WHEN-FORM-NAVIGATE') THEN
    APP_SPECIAL2.INSTANTIATE('SPECIAL15', 'Create PO in APEX');
    IF FND_FUNCTION.TEST('XXPO_CUSTOM_PO') THEN
      APP_SPECIAL2.ENABLE('SPECIAL15', PROPERTY_ON);
    ELSE
      APP_SPECIAL2.ENABLE('SPECIAL15', PROPERTY_OFF);
    END IF;
  ELSIF event_name = 'SPECIAL15' THEN
    IF FND_FUNCTION.TEST('XXPO_CUSTOM_PO') THEN
      FND_UTILITIES.OPEN_URL('https://your-apex-host/ords/f?p=YOUR_APP_ID:1:0');
    END IF;
  END IF;
END IF;
