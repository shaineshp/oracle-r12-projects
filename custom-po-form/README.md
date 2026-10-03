# Custom Standard PO entry from Tools

For the requested **Oracle APEX implementation**, use [apex/README.md](apex/README.md).
It includes the entry UI, server API, identity mapping, and APEX page setup.
The Forms implementation below remains available as the earlier alternative.

This implementation captures 20 business fields, supports multiple lines, and
queues a new Standard Purchase Order through the R12 Purchasing Documents Open
Interface (PDOI). It creates the PO as INCOMPLETE for normal approval. It never
updates the PO currently open in the source form.

The workspace contains SQL/Forms source and an interactive layout preview. It has
no EBS connection, TEMPLATE.fmb, or Forms compiler, so no FMB/FMX has been built,
installed, or runtime-tested. The preview does not post transactions.

Open `preview.html` to review the layout, add lines, and export a sample entry.
The preview uses text inputs in place of Oracle LOVs; live master-data validation
belongs to the Forms implementation and PDOI.

## The 20 fields

Header fields are entered once; line fields repeat for each line. LOVs display
business names/numbers and store their underlying IDs.

| # | Field | Staging column | Behavior |
| --- | --- | --- | --- |
| 1 | Operating unit | ORG_ID | Required; responsibility-accessible OU |
| 2 | Supplier | VENDOR_ID | Required; active supplier LOV |
| 3 | Supplier site | VENDOR_SITE_ID | Required; purchasing site for supplier/OU |
| 4 | Buyer | AGENT_ID | Required; active buyer LOV |
| 5 | Currency | CURRENCY_CODE | Required; enabled currency LOV |
| 6 | Bill-to location | BILL_TO_LOCATION_ID | Required; valid location LOV |
| 7 | Ship-to location | SHIP_TO_LOCATION_ID | Required; valid receiving location |
| 8 | Payment terms | TERMS_ID | Required; active terms LOV |
| 9 | Line number | LINE_NUM | Automatically numbered; positive unique integer |
| 10 | Line type | LINE_TYPE_ID | Required; quantity-based types |
| 11 | Item | ITEM_ID | Optional for description-based lines |
| 12 | Description | ITEM_DESCRIPTION | Required; default from item |
| 13 | Purchasing category | CATEGORY_ID | Required; default from item/category set |
| 14 | UOM | UNIT_OF_MEASURE | Required; full UOM name, default from item |
| 15 | Quantity | QUANTITY | Required; greater than zero |
| 16 | Unit price | UNIT_PRICE | Required; zero or greater |
| 17 | Need-by date | NEED_BY_DATE | Required; today or later |
| 18 | Receiving organization | SHIP_TO_ORGANIZATION_ID | Required; valid inventory org |
| 19 | Destination type | DESTINATION_TYPE_CODE | Required; EXPENSE or INVENTORY |
| 20 | Charge account | CHARGE_ACCOUNT_ID | Required; accounting flexfield LOV |

PO number, document type STANDARD, approval status INCOMPLETE, draft/interface
identifiers, and audit/status fields are system-managed. Each line creates one
shipment and one distribution for its entire quantity. Amount/service lines,
split schedules, projects, and explicit subinventory entry need an extension.
Foreign currency exchange rates and additional inventory destination defaults
must be derivable from site setup; PDOI reports errors when they are missing.

## Database setup

1. Install `staging.sql` in your registered custom schema. Provide APPS synonyms
   and approved grants through the site's custom application deployment process.
2. Compile `xxpo_entry_pkg.sql` with APPS access to those staging objects, standard
   interfaces, sequences, and EBS APIs. Use appropriate editioning for R12.2.
3. Run `preflight.sql` and verify POXPOPDOI argument positions against the installed
   concurrent program definition. Ensure Import Standard Purchase Orders is in
   the responsibility's request group. Correct release-specific parameters before
   posting. The example maps argument8 to batch and argument9 to operating unit.
4. Preserve header interface rows until status reconciliation completes.

`POST_PO` locks the draft, checks ownership/function/OU access, validates site and
line basics, creates interface rows and queues POXPOPDOI. It leaves the transaction
uncommitted; the saved Forms caller commits interface rows and request together.
A persisted request ID prevents repeated posting of the same draft. Oracle PDOI
performs the remaining business validations. `REFRESH_STATUS` reconciles accepted
or rejected interfaces; request completion alone does not imply PO creation.

## Build XXPO_CUSTOM.fmb

Use the TEMPLATE.fmb and Forms Builder version from your EBS installation. Retain
standard EBS libraries, triggers, menus, initialization, and exit behavior.

- Create header block `XXPO_HEADER` on XXPO_ENTRY_HEADERS, with a canvas showing
  fields 1–8; hidden draft/audit fields and read-only status/request/PO indicators.
- Create repeating detail block `XXPO_LINES` on XXPO_ENTRY_LINES for fields 9–20.
  Define a master/detail relation on DRAFT_ID, with deferred coordination disabled.
- Create a Number parameter `P_DRAFT_ID` and non-database control block
  `XXPO_CONTROL` with REQUEST_ID. Add Post to PO and Refresh Status buttons.
- Add program units from `target_form.plsql`. Call XXPO_STARTUP after standard
  initialization in WHEN-NEW-FORM-INSTANCE. Button triggers call XXPO_POST and
  XXPO_REFRESH respectively.
- Set XXPO_HEADER.Default Where to:
  `draft_id = :parameter.p_draft_id AND created_by = fnd_global.user_id AND mo_global.check_access(org_id) = 'Y'`.
  Set P_DRAFT_ID immediately when allocating a new draft so requery stays scoped.
- In header PRE-INSERT, allocate DRAFT_ID from XXPO_ENTRY_HEADERS_S.NEXTVAL;
  assign P_DRAFT_ID, STATUS=DRAFT, and standard WHO fields from FND_GLOBAL.
- In line PRE-INSERT, allocate DRAFT_LINE_ID from XXPO_ENTRY_LINES_S.NEXTVAL;
  assign parent DRAFT_ID and standard WHO fields. Default line numbers sequentially
  when creating lines, with database uniqueness enforcing the final value.
- In PRE-UPDATE, set LAST_UPDATE_DATE, LAST_UPDATED_BY, LAST_UPDATE_LOGIN. Keep
  owner, primary keys, status, and interface/request IDs non-editable.
- Reject insert/update/delete operations when the saved header status is not
  DRAFT. The database line guard also locks the parent to serialize posting.
  In WHEN-NEW-RECORD-INSTANCE, disable editing and Post for submitted/imported/
  rejected drafts. Keep Refresh available. Do not allow changing ORG_ID after
  entering supplier/site/line data without clearing and revalidating those values.
- Create dependent LOVs for all ID-based fields. Use FND_KEY_FLEX for the charge
  account, with the purchasing OU's chart of accounts. Validate account dates,
  enabled/posting flags, and ledger membership. Restrict receiving organizations
  to valid organizations for the selected OU and Purchasing setup.
- Default description, purchasing category, and UOM when selecting the item;
  use the applicable purchasing category set, not an arbitrary item category.
- Display import errors through a read-only block scoped to the draft's
  INTERFACE_HEADER_ID in PO_INTERFACE_ERRORS. Display request phase/status and
  the created PO number joined using the reconciled PO_HEADER_ID.

## Register and launch from Tools

Register form XXPO_CUSTOM under the custom application. Register form function
XXPO_CUSTOM_PO (type Form) against it, with no parameters. Grant it through the
responsibility menu with a blank prompt; check exclusions too.

Verify the source form using Help > Diagnostics > Examine. The launcher assumes
POXPOEPO. Reserve an unused Tools slot between SPECIAL1 and SPECIAL15; SPECIAL15
is an example. Check seeded triggers, personalizations, and existing CUSTOM code.

Merge `custom_event.plsql` into CUSTOM.EVENT without replacing existing logic.
Attach APPCORE2 to CUSTOM and use APP_SPECIAL2. FNDSQF supplies FND_FUNCTION.
The Tools label is Create Custom PO; launch opens a separate session for entry.
Compile/deploy the FMX under the registered application's forms/<language> and
generate/deploy CUSTOM.plx via your site's deployment process. For R12.2 follow
online patching and edition rules. Preserve existing CUSTOM artifacts for rollback.

## Rejected imports and retry

Show the existing batch's errors and request status. Reconcile whether a PO was
created before any retry. Do not reset the draft to DRAFT or blindly create a new
batch; that can duplicate an existing document. This source intentionally prevents
automatic reposting of rejected/submitted drafts. Use the site's controlled PDOI
correction/reprocessing procedure after reviewing the interface errors.

## Required development validation

Test a one-line and multiple-line PO, item and description-based purchasing,
expense and inventory destinations with applicable defaults, inaccessible OUs,
invalid sites/UOM/accounts, missing rates/defaults, import rejection, failed request
submission, duplicate clicks, and concurrent sessions. Confirm the created PO's
header, quantities, shipments, distributions, accounts and INCOMPLETE status.
Ensure existing Tools actions still work and submitted drafts cannot be edited.

Local verification covers source consistency only. Forms compilation and database
integration require the EBS development environment.

## Oracle references

- [R12.2 Import Standard Purchase Orders](https://docs.oracle.com/cd/E26401_01/doc.122/e48931/T446883T443960.htm)
- [CUSTOM library and APPCORE2](https://docs.oracle.com/cd/E26401_01/doc.122/e22961/T302934T458265.htm)
- [Function security and FND_FUNCTION.EXECUTE](https://docs.oracle.com/cd/E18727_01/doc.121/e12897/T302934T458251.htm)
