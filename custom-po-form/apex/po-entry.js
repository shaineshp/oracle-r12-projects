/* APEX page JavaScript file; uses authenticated XXPO_API Ajax Callback. */
(function () {
  "use strict";
  const headerFields = [
    ["org_id", "Operating unit", "lov"], ["vendor_id", "Supplier", "lov"],
    ["vendor_site_id", "Supplier site", "lov"], ["agent_id", "Buyer", "lov"],
    ["currency_code", "Currency", "lov"], ["bill_to_location_id", "Bill-to location", "lov"],
    ["ship_to_location_id", "Ship-to location", "lov"], ["terms_id", "Payment terms", "lov"]
  ];
  const lineFields = [
    ["line_num", "Line number", "number"], ["line_type_id", "Line type", "lov"],
    ["item_id", "Item (optional)", "lov"], ["item_description", "Description", "text"],
    ["category_id", "Purchasing category", "lov"], ["unit_of_measure", "UOM", "lov"],
    ["quantity", "Quantity", "number"], ["unit_price", "Unit price", "number"],
    ["need_by_date", "Need-by date", "date"], ["ship_to_organization_id", "Receiving organization", "lov"],
    ["destination_type_code", "Destination type", "select"], ["charge_account_id", "Charge account", "lov"]
  ];
  const stringFields = new Set(["currency_code", "item_description", "unit_of_measure", "need_by_date", "destination_type_code"]);
  const state = { id: null, revision: 0, status: "DRAFT", header: {}, lines: [], dirty: false, busy: false };
  let lovTarget = null, lookupSequence = 0, debounceTimer, fieldSequence = 0;
  const el = id => document.getElementById("xxpo-" + id);
  function message(text, error) {
    el("message").textContent = text; el("message").hidden = !text;
    el("message").classList.toggle("xxpo-error", !!error);
  }
  function api(action, options = {}, body) {
    const data = { x01: action, ...options };
    if (body) {
      const characters = Array.from(JSON.stringify(body)); data.f01 = [];
      for (let i = 0; i < characters.length; i += 6000) data.f01.push(characters.slice(i, i + 6000).join(""));
    }
    return apex.server.process("XXPO_API", data, { dataType: "json" }).then(result => {
      if (!result.ok) throw new Error(result.message || "The request could not be completed.");
      return result;
    });
  }
  function setBusy(busy) {
    state.busy = busy;
    el("app").querySelectorAll("button,input,select").forEach(control => {
      const editableControl = !!control.closest("#xxpo-header,#xxpo-lines") || ["xxpo-add", "xxpo-save", "xxpo-post"].includes(control.id);
      control.disabled = busy || (editableControl && state.status !== "DRAFT");
    });
    el("refresh").disabled = busy || !state.id;
  }
  async function operation(fn) {
    if (state.busy) return;
    message(""); setBusy(true);
    try { await fn(); } catch (error) {
      message(error.message || "Connection failed. Reload the draft list before retrying a post.", true);
    } finally { setBusy(false); }
  }
  function lowerKeys(row) { return Object.fromEntries(Object.entries(row || {}).map(([key, value]) => [key.toLowerCase(), value])); }
  function total() {
    const amount = state.lines.reduce((sum, line) => sum + (Number(line.quantity) || 0) * (Number(line.unit_price) || 0), 0);
    el("total").textContent = "Line total: " + amount.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + " " + (state.header.currency_code || "");
  }
  function clearFields(model, names) { for (const name of names) { model[name] = null; delete model[name + "_label"]; } }
  async function changed(model, name) {
    state.dirty = true;
    if (name === "org_id") {
      clearFields(state.header, ["vendor_site_id", "bill_to_location_id", "ship_to_location_id"]);
      state.lines.forEach(line => clearFields(line, ["ship_to_organization_id", "item_id", "item_description", "category_id", "unit_of_measure", "charge_account_id"]));
    } else if (name === "vendor_id") clearFields(state.header, ["vendor_site_id"]);
    else if (name === "ship_to_organization_id") clearFields(model, ["item_id", "item_description", "category_id", "unit_of_measure"]);
    render();
    if (name === "item_id" && model.item_id) {
      const item = model.item_id, receiving = model.ship_to_organization_id;
      setBusy(true);
      try {
        const result = await api("ITEM_DEFAULTS", { x04: String(item), x05: state.header.org_id, x07: receiving });
        if (model.item_id === item && model.ship_to_organization_id === receiving && result.rows.length) {
          const defaults = lowerKeys(result.rows[0]); model.item_description = defaults.description;
          model.unit_of_measure = defaults.unit_of_measure; model.unit_of_measure_label = defaults.unit_of_measure;
          render();
        }
      } catch (error) { message(error.message, true); } finally { setBusy(false); }
    }
  }
  function field(definition, model) {
    const [name, label, type] = definition;
    const box = document.createElement("div"); box.className = "xxpo-field";
    const caption = document.createElement("label"), id = "xxpo-field-" + (++fieldSequence);
    caption.textContent = label; caption.htmlFor = id; box.append(caption);
    if (type === "lov") {
      const group = document.createElement("div"); group.className = "xxpo-value";
      const button = document.createElement("button"); button.id = id; button.type = "button";
      button.textContent = model[name + "_label"] || (model[name] ? String(model[name]) : "Select " + label.toLowerCase());
      button.addEventListener("click", () => openLookup(model, definition)); group.append(button);
      if (name === "item_id") {
        const clear = document.createElement("button"); clear.type = "button"; clear.textContent = "Clear";
        clear.addEventListener("click", () => { clearFields(model, ["item_id"]); changed(model, name); }); group.append(clear);
      }
      box.append(group);
    } else {
      const input = document.createElement(type === "select" ? "select" : "input"); input.id = id;
      if (type === "select") {
        for (const value of ["EXPENSE", "INVENTORY"]) {
          const option = document.createElement("option"); option.value = value; option.textContent = value === "EXPENSE" ? "Expense" : "Inventory"; input.append(option);
        }
      } else { input.type = type; input.required = true; }
      input.value = model[name] == null ? "" : model[name];
      if (type === "date") {
        const d = new Date(); input.min = [d.getFullYear(), String(d.getMonth() + 1).padStart(2, "0"), String(d.getDate()).padStart(2, "0")].join("-");
      }
      if (type === "number") { input.step = name === "line_num" ? "1" : "any"; input.min = name === "unit_price" ? "0" : "0.000001"; }
      if (name === "line_num") input.readOnly = true;
      if (name === "item_description") input.maxLength = 240;
      input.addEventListener("input", () => { model[name] = input.value; state.dirty = true; total(); }); box.append(input);
    }
    return box;
  }
  function render() {
    fieldSequence = 0; el("header").replaceChildren(...headerFields.map(def => field(def, state.header)));
    el("lines").replaceChildren();
    state.lines.forEach((line, index) => {
      line.line_num = index + 1;
      const section = document.createElement("section"); section.className = "xxpo-card";
      const top = document.createElement("div"); top.className = "xxpo-section-title";
      const title = document.createElement("h2"); title.textContent = "Line " + (index + 1); top.append(title);
      const remove = document.createElement("button"); remove.type = "button"; remove.textContent = "Remove line";
      remove.addEventListener("click", () => { if (state.lines.length > 1) { state.lines.splice(index, 1); state.dirty = true; render(); } }); top.append(remove);
      const grid = document.createElement("div"); grid.className = "xxpo-grid"; lineFields.forEach(def => grid.append(field(def, line)));
      section.append(top, grid); el("lines").append(section);
    });
    el("status").textContent = state.id ? state.status : "New draft"; total(); setBusy(state.busy);
  }
  function payload() {
    for (const input of el("app").querySelectorAll("#xxpo-header input,#xxpo-lines input")) {
      if (!input.checkValidity()) { input.reportValidity(); throw new Error("Check the highlighted field."); }
    }
    function values(model, definitions) {
      return Object.fromEntries(definitions.map(([name, label]) => {
        const value = model[name];
        if ((value === null || value === undefined || value === "") && name !== "item_id") throw new Error("Enter " + label.toLowerCase() + ".");
        return [name, value == null || value === "" ? null : stringFields.has(name) ? String(value).trim() : Number(value)];
      }));
    }
    return { draft_id: state.id, revision: state.revision, header: values(state.header, headerFields), lines: state.lines.map(line => values(line, lineFields)) };
  }
  function applyDraft(result) {
    const header = lowerKeys(result.header[0]);
    state.id = header.draft_id; state.revision = header.apex_revision; state.status = header.status;
    state.header = header; state.lines = result.lines.map(lowerKeys);
    state.lines.forEach(line => { if (line.need_by_date) line.need_by_date = line.need_by_date.slice(0, 10); });
    state.dirty = false; render();
    const po = lowerKeys((result.purchase_order || [])[0]), request = lowerKeys((result.request || [])[0]);
    el("result").textContent = po.po_number ? "PO " + po.po_number + " · " + po.authorization_status : header.request_id ? "Import request " + header.request_id + " · " + state.status + (request.completion_text ? " · " + request.completion_text : "") : "Draft saved. Ready to post to Purchasing.";
    el("errors").replaceChildren();
    for (const row of result.errors || []) {
      const error = lowerKeys(row), item = document.createElement("li");
      item.textContent = error.error_message || error.error_message_text || error.error_message_name || "Purchasing import validation failed. Review the request log.";
      el("errors").append(item);
    }
  }
  async function save(post) {
    applyDraft(await api("SAVE", {}, payload()));
    if (post) applyDraft(await api("POST", {}, payload()));
    message(post ? "Submitted to Purchasing. Refresh status to see the created PO or validation errors." : "Draft saved.");
    await listDrafts();
  }
  async function listDrafts() {
    const result = await api("LIST"); el("list").replaceChildren();
    if (!result.rows.length) { el("list").textContent = "No saved drafts yet."; return; }
    const table = document.createElement("table"), head = document.createElement("tr");
    for (const caption of ["Draft", "Supplier", "Operating unit", "Status", "PO"]) { const th = document.createElement("th"); th.textContent = caption; head.append(th); }
    const thead = document.createElement("thead"); thead.append(head); table.append(thead);
    const tbody = document.createElement("tbody"); table.append(tbody);
    for (const raw of result.rows) {
      const row = lowerKeys(raw), tr = document.createElement("tr"), td = document.createElement("td"), button = document.createElement("button");
      button.type = "button"; button.textContent = "Open " + row.draft_id;
      button.addEventListener("click", () => { if (discardAllowed()) operation(async () => applyDraft(await api("LOAD", { x02: row.draft_id }))); }); td.append(button); tr.append(td);
      for (const key of ["supplier", "operating_unit", "status", "po_number"]) { const cell = document.createElement("td"); cell.textContent = row[key] || "—"; tr.append(cell); } tbody.append(tr);
    }
    el("list").append(table);
  }
  function discardAllowed() { return !state.dirty || window.confirm("Discard unsaved changes?"); }
  function newDraft() {
    if (!discardAllowed()) return;
    state.id = null; state.revision = 0; state.status = "DRAFT"; state.header = {};
    state.lines = [{ line_num: 1, destination_type_code: "EXPENSE" }]; state.dirty = false;
    message(""); el("result").textContent = "Save and post a draft to create a purchase order."; el("errors").replaceChildren(); render();
  }
  function openLookup(model, definition) {
    const [name, label] = definition;
    if (name !== "org_id" && !state.header.org_id) { message("Select an operating unit first.", true); return; }
    if (name === "vendor_site_id" && !state.header.vendor_id) { message("Select a supplier first.", true); return; }
    if (name === "item_id" && !model.ship_to_organization_id) { message("Select a receiving organization first.", true); return; }
    lovTarget = { model, name }; el("lov-title").textContent = "Select " + label.toLowerCase();
    el("lov-search").value = ""; el("lov").showModal(); el("lov-search").focus(); searchLookup();
  }
  async function searchLookup() {
    const target = lovTarget, sequence = ++lookupSequence;
    if (!target) return;
    el("lov-results").textContent = "Searching…";
    try {
      const result = await api("LOOKUP", { x03: target.name, x04: el("lov-search").value, x05: state.header.org_id, x06: state.header.vendor_id, x07: target.model.ship_to_organization_id });
      if (sequence !== lookupSequence || lovTarget !== target) return;
      el("lov-results").replaceChildren();
      if (!result.rows.length) el("lov-results").textContent = "No matching values.";
      for (const raw of result.rows) {
        const row = lowerKeys(raw), button = document.createElement("button"); button.type = "button"; button.textContent = row.label;
        button.addEventListener("click", () => {
          target.model[target.name] = stringFields.has(target.name) ? row.value : Number(row.value);
          target.model[target.name + "_label"] = row.label; closeLookup(); changed(target.model, target.name);
        }); el("lov-results").append(button);
      }
      if (result.rows.length === 50) { const hint = document.createElement("p"); hint.textContent = "Showing 50 values. Refine your search for more results."; el("lov-results").append(hint); }
    } catch (error) { if (sequence === lookupSequence) el("lov-results").textContent = error.message; }
  }
  function closeLookup() { lovTarget = null; ++lookupSequence; el("lov").close(); }
  function init() {
    if (!el("app")) return;
    el("save").addEventListener("click", () => operation(() => save(false)));
    el("post").addEventListener("click", () => operation(() => save(true)));
    el("refresh").addEventListener("click", () => operation(async () => {
      if (state.dirty) throw new Error("Save changes before refreshing status.");
      applyDraft(await api("REFRESH", { x02: state.id })); await listDrafts();
    }));
    el("new").addEventListener("click", newDraft);
    el("add").addEventListener("click", () => { if (state.lines.length >= 200) return message("Maximum 200 lines per PO.", true); state.lines.push({ destination_type_code: "EXPENSE" }); state.dirty = true; render(); });
    el("list-refresh").addEventListener("click", () => operation(listDrafts));
    el("lov-close").addEventListener("click", closeLookup);
    el("lov").addEventListener("cancel", () => { lovTarget = null; ++lookupSequence; });
    el("lov-search").addEventListener("input", () => { clearTimeout(debounceTimer); debounceTimer = setTimeout(searchLookup, 250); });
    window.addEventListener("beforeunload", event => { if (state.dirty) { event.preventDefault(); event.returnValue = ""; } });
    newDraft(); operation(listDrafts);
  }
  apex.jQuery(init);
}());
