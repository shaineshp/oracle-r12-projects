-- Merge this branch into CUSTOM.EVENT; retain existing customizations.
-- Verify POXPOEPO and reserve an unused Tools slot; SPECIAL15 is an example.
-- Attach APPCORE2 to CUSTOM. FNDSQF supplies FND_FUNCTION.
IF NAME_IN('SYSTEM.CURRENT_FORM') = 'POXPOEPO' THEN
  IF event_name IN ('WHEN-NEW-FORM-INSTANCE', 'WHEN-FORM-NAVIGATE') THEN
    APP_SPECIAL2.INSTANTIATE('SPECIAL15', 'Create Custom PO');
    IF FND_FUNCTION.TEST('XXPO_CUSTOM_PO') THEN
      APP_SPECIAL2.ENABLE('SPECIAL15', PROPERTY_ON);
    ELSE
      APP_SPECIAL2.ENABLE('SPECIAL15', PROPERTY_OFF);
    END IF;
  ELSIF event_name = 'SPECIAL15' THEN
    FND_FUNCTION.EXECUTE(
      function_name => 'XXPO_CUSTOM_PO',
      open_flag => 'Y',
      session_flag => 'SESSION'
    );
  END IF;
END IF;
