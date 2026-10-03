# APEX custom Standard Purchase Order entry

The APEX implementation captures the same **20 business fields**: 8 header fields
and 12 fields per repeating PO line. It includes searchable LOVs, item description
and UOM defaults, Save Draft, Post to PO, My Recent Drafts, and import status/errors.
Posting creates a new Standard PO as INCOMPLETE through the existing EBS PDOI
package. It does not update the PO currently open in Forms.

Target: **APEX 24.2, Oracle Database 19c or later, on the EBS database**, with an
approved custom integration schema. This is implementation source, not an APEX
application export. No APEX workspace or EBS connection is available here; the
page must be assembled in App Builder and database SQL compiled/tested there.
If APEX is on a separate database, the backend needs an authenticated EBS service
adapter; these local database packages cannot be used unchanged.

The downloadable `../apex-deployment.zip` contains this source tree and the EBS
staging/import dependencies. Extract it before running the scripts. It is a
**source deployment bundle**, not an App Builder application-export ZIP.

## Files

| File | Install/use |
| --- | --- |
| `schema.sql` | Custom-schema migration and administrator identity mappings |
| `install.sql` | Compile both packages and check installation prerequisites |
| `xxpo_apex_api.sql` | Server API; compile in the EBS integration environment |
| `grants.sql` | Restricted parsing-schema package access |
| `configure-user.sql` | Administrator example for mapping authenticated users |
| `region.html` | APEX Static Content region source |
| `po-entry.js` | Application static file for the entry UI |
| `po-entry.css` | Application static file for styling |
| `ajax-process.sql` | Page Ajax Callback source named XXPO_API |
| `custom_event.plsql` | Alternative Tools menu launcher for the APEX URL |

## 1. Install the database objects

Use the site's registered custom application and R12.2 editioning/deployment
process. The APEX parsing schema must be separate from APPS.

1. Install the existing `../staging.sql` if not installed. Do not rerun its CREATE
   TABLE statements against an existing installation.
2. Run `schema.sql` once in the custom schema owning the staging tables. Expose
   XXPO_APEX_USER_MAP and the existing staging tables/sequences to the integration
   package owner with approved direct grants and synonyms.
3. Compile `../xxpo_entry_pkg.sql` in the EBS integration environment. Run
   `../preflight.sql` and confirm the installed POXPOPDOI argument positions.
4. Compile `xxpo_apex_api.sql` in APPS or the site's approved integration schema,
   where APEX APIs and EBS objects are accessible through direct privileges.
5. Adapt `grants.sql` to the actual package owner and parsing schema. Grant only
   EXECUTE on XXPO_APEX_API to the APEX schema; no EBS/staging table privileges.
6. The assigned Purchasing responsibility must grant XXPO_CUSTOM_PO and have
   Import Standard Purchase Orders in its request group. For a new APEX-only
   installation, register XXPO_CUSTOM_PO as a **Subfunction** and grant it through
   the responsibility menu; a Forms registration is unnecessary.

After the owning-schema objects and integration-schema grants/synonyms are in
place, `@custom-po-form/apex/install.sql` runs steps 3–4 and reports compilation
errors. Run it from SQLcl/SQL*Plus connected to the approved integration schema.
Complete the parsing-schema grants separately using `grants.sql`.

No hardcoded user/responsibility IDs are used. The server maps authenticated
APP_USER plus application ID to a DBA-controlled EBS identity, verifies the active
responsibility assignment, and initializes EBS/MO context on every callback.
This implementation supports the standard EBS security group (ID 0).

## 2. Create the APEX application

In App Builder, create an application named **Custom PO Entry**, using Universal
Theme and the approved parsing schema. Use authenticated access; APEX Accounts
can be used for development, or configure your site's SSO for production.
Keep the generated login page.

Create authorization scheme **XXPO_ACCESS**:

- Type: PL/SQL Function Returning Boolean
- Source: `RETURN xxpo_apex_api.is_authorized;`
- Evaluation: Always / No Caching (the API independently checks each request)

Apply XXPO_ACCESS to the entry page and its callback. Require authentication on
both. Do not configure a public entry page or public Ajax process.

Upload `po-entry.js` and `po-entry.css` under Shared Components > Static
Application Files.

## 3. Create the PO entry page

Create **Page 1**, a blank normal page named Create Purchase Order:

| Setting | Value |
| --- | --- |
| Authentication | Page requires authentication |
| Authorization scheme | XXPO_ACCESS |
| Page Access Protection | Arguments Must Have Checksum |
| Region type | Static Content |
| Region name | Custom PO Entry |
| Region source | Contents of `region.html` |
| Region template | Blank / no surrounding title |
| JavaScript File URLs | `#APP_FILES#po-entry.js` |
| CSS File URLs | `#APP_FILES#po-entry.css` |

Add a page process:

- Name: **XXPO_API** (exact spelling)
- Point/type: **Ajax Callback / Execute Code**
- Language: PL/SQL
- Source: contents of `ajax-process.sql`
- Authorization: XXPO_ACCESS

No automatic form DML process, Interactive Grid DML process, or page submit
process is needed. This implementation uses a custom APEX region and the
documented `apex.server.process` API. The JavaScript generates the 8 header
controls and 12 repeating line controls from one field definition.

Once this page is working, export the application using App Builder for a genuine,
version-specific APEX deployment artifact.

## 4. Map users and open from Tools

An administrator must populate XXPO_APEX_USER_MAP using the real application ID,
authenticated APEX username, EBS user ID, Purchasing responsibility ID and its
application ID. `configure-user.sql` provides the bind-variable example.
Do not expose this table through the app or accept EBS identity from URL/items.

Use `custom_event.plsql` instead of the earlier Forms launcher. Replace its URL
with the application's approved HTTPS URL and real application ID. Reserve an
unused Tools slot (SPECIAL15 is only an example), merge into existing CUSTOM.EVENT,
and generate/deploy CUSTOM.plx via the site's process. The browser authenticates
to APEX independently; this launcher does not implement EBS-to-APEX SSO.

## Behaviour and transaction handling

- All draft access is checked against the mapped EBS owner and OU access.
- Header selection changes clear dependent site/location/item/account values.
- The Item LOV is scoped to the receiving organization; selecting an item defaults
  its description and UOM. Select its Purchasing category explicitly.
- Save is one transaction for the header and all lines. Revision checking prevents
  another tab/session from overwriting a changed draft.
- Post first saves the draft and receives its durable ID, then queues PDOI using
  that ID. The interface batch, concurrent request, and SUBMITTED status commit
  together. Repeated POST on a queued draft returns the existing result.
- Posted drafts become read-only. The database guards also freeze their business
  fields and lines. Request completion is distinct from successful PO import.
- Refresh reads the interface result, PO number, request details, and validation
  errors. If a response is lost, open/refresh the saved draft before retrying.
- Rejected imports cannot be automatically reposted. Reconcile the existing batch
  and follow the site's correction procedure to prevent duplicate POs.

## Limits and validation

The backend supports 1–200 quantity-based lines per PO, one shipment and one
distribution per line. Items may be omitted for description-based purchasing.
Site setup must supply any additional inventory destination and foreign-currency
rate defaults. Amount-based service lines, projects, split distributions and
explicit subinventory fields require extensions. Final business validation is
performed by PDOI. Review master-data visibility rules for your Purchasing setup;
the supplier/category/location LOVs use the standard global master records.

Before production, compile both packages, verify all LOV queries against your
release, and test one/multiple-line POs, valid and inaccessible OUs, account/site
errors, missing defaults, failed imports, duplicate posts, lost responses, and
concurrent tabs. Verify the standard PO's lines, schedules, distributions,
accounts and INCOMPLETE approval status. Local checks cannot replace database
compilation and EBS end-to-end tests.

## References

- [APEX JavaScript API](https://docs.oracle.com/en/database/oracle/apex/24.2/aexjs/apex.server.html)
- [APEX JSON API](https://docs.oracle.com/en/database/oracle/apex/24.2/aeapi/APEX_JSON.html)
- [EBS context initialization](https://docs.oracle.com/cd/E26401_01/doc.122/e22961/T302934T462356.htm)
- [Import Standard Purchase Orders](https://docs.oracle.com/cd/E26401_01/doc.122/e48931/T446883T443960.htm)
