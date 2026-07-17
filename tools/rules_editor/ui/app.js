const state = {
  meta: null,
  table: null,
  tablePage: null,
  selectedRow: null,
  mode: 'idle',
  page: 1,
  pageSize: 50,
  search: '',
  sortBy: null,
  sortDir: 'asc',
  hideEmptyColumns: false,
  busy: false,
};

const RULES_EXTENSION_ID = 'com.emperor.ruleseditor.db';
const REQUEST_TIMEOUT_MS = 20000;

const elements = {
  databasePath: document.querySelector('#databasePath'),
  tableFilter: document.querySelector('#tableFilter'),
  tableList: document.querySelector('#tableList'),
  tableTitle: document.querySelector('#tableTitle'),
  tableStats: document.querySelector('#tableStats'),
  rowSearch: document.querySelector('#rowSearch'),
  pageSize: document.querySelector('#pageSize'),
  hideEmptyColumns: document.querySelector('#hideEmptyColumns'),
  backupButton: document.querySelector('#backupButton'),
  reloadButton: document.querySelector('#reloadButton'),
  newRowButton: document.querySelector('#newRowButton'),
  gridHead: document.querySelector('#gridHead'),
  gridBody: document.querySelector('#gridBody'),
  emptyState: document.querySelector('#emptyState'),
  prevPage: document.querySelector('#prevPage'),
  nextPage: document.querySelector('#nextPage'),
  pageLabel: document.querySelector('#pageLabel'),
  detailTitle: document.querySelector('#detailTitle'),
  detailMeta: document.querySelector('#detailMeta'),
  clearSelection: document.querySelector('#clearSelection'),
  rowForm: document.querySelector('#rowForm'),
  formFields: document.querySelector('#formFields'),
  deleteRowButton: document.querySelector('#deleteRowButton'),
  saveRowButton: document.querySelector('#saveRowButton'),
  toast: document.querySelector('#toast'),
};

init().catch((error) => {
  showToast(error.message || String(error), true);
});

async function init() {
  await waitForApi();
  bindEvents();
  await loadMeta();
  const preferred = findTable('units') || state.meta.tables[0];
  await selectTable(preferred.name);
}

function bindEvents() {
  elements.tableFilter.addEventListener('input', renderTableList);
  elements.rowSearch.addEventListener(
    'input',
    debounce(() => {
      state.search = elements.rowSearch.value;
      state.page = 1;
      loadTableData();
    }, 220),
  );
  elements.pageSize.addEventListener('change', () => {
    state.pageSize = Number(elements.pageSize.value);
    state.page = 1;
    loadTableData();
  });
  elements.hideEmptyColumns.addEventListener('change', () => {
    state.hideEmptyColumns = elements.hideEmptyColumns.checked;
    renderGrid();
  });
  elements.reloadButton.addEventListener('click', async () => {
    await loadMeta();
    await loadTableData();
    showToast('Reloaded');
  });
  elements.backupButton.addEventListener('click', async () => {
    const result = await window.rulesApi.createBackup();
    showToast(`Backup created: ${result.backupPath}`);
  });
  elements.newRowButton.addEventListener('click', () => {
    startNewRow();
  });
  elements.prevPage.addEventListener('click', () => {
    if (state.page > 1) {
      state.page -= 1;
      loadTableData();
    }
  });
  elements.nextPage.addEventListener('click', () => {
    if (state.tablePage && state.page < pageCount()) {
      state.page += 1;
      loadTableData();
    }
  });
  elements.clearSelection.addEventListener('click', () => {
    clearSelection();
  });
  elements.rowForm.addEventListener('submit', (event) => {
    event.preventDefault();
    saveCurrentRow();
  });
  elements.deleteRowButton.addEventListener('click', () => {
    deleteCurrentRow();
  });
}

async function waitForApi() {
  if (window.rulesApi) {
    return;
  }

  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (window.Neutralino) {
      await window.Neutralino.init();
      await Neutralino.events.on('windowClose', () => {
        Neutralino.app.exit();
      });
      window.rulesApi = await createNeutralinoRulesApi();
      return;
    }

    await delay(30);
  }

  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (window.rulesApi) {
      return;
    }

    await delay(30);
  }

  throw new Error('Native API is not available');
}

async function createNeutralinoRulesApi() {
  const pending = new Map();

  await Neutralino.events.on('rulesDbResponse', (event) => {
    const response = event.detail || {};
    const request = pending.get(response.id);

    if (!request) {
      return;
    }

    clearTimeout(request.timer);
    pending.delete(response.id);

    if (response.ok) {
      request.resolve(response.result);
    } else {
      request.reject(new Error(response.error || 'Rules DB request failed'));
    }
  });

  async function invoke(method, ...args) {
    const id = createRequestId();
    const result = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`Rules DB request timed out: ${method}`));
      }, REQUEST_TIMEOUT_MS);

      pending.set(id, { resolve, reject, timer });
    });

    await Neutralino.extensions.dispatch(RULES_EXTENSION_ID, 'rulesDbRequest', {
      id,
      method,
      args,
    });

    return result;
  }

  return {
    getMeta: () => invoke('getMeta'),
    getTableData: (request) => invoke('getTableData', request),
    updateRow: (request) => invoke('updateRow', request),
    insertRow: (request) => invoke('insertRow', request),
    deleteRow: (request) => invoke('deleteRow', request),
    createBackup: () => invoke('createBackup'),
  };
}

async function loadMeta() {
  state.meta = await window.rulesApi.getMeta();
  elements.databasePath.textContent = state.meta.databasePath;
  renderTableList();
}

async function selectTable(tableName) {
  state.table = tableName;
  state.page = 1;
  state.search = '';
  state.sortBy = null;
  state.sortDir = 'asc';
  state.selectedRow = null;
  state.mode = 'idle';
  elements.rowSearch.value = '';
  await loadTableData();
  renderTableList();
}

async function loadTableData() {
  if (!state.table) {
    return;
  }

  setBusy(true);

  try {
    state.tablePage = await window.rulesApi.getTableData({
      table: state.table,
      page: state.page,
      pageSize: state.pageSize,
      search: state.search,
      sortBy: state.sortBy,
      sortDir: state.sortDir,
    });
    state.page = state.tablePage.page;
    state.sortBy = state.tablePage.sortBy;
    state.sortDir = state.tablePage.sortDir;
    state.selectedRow = null;
    state.mode = 'idle';
    renderAll();
  } catch (error) {
    showToast(error.message || String(error), true);
  } finally {
    setBusy(false);
  }
}

function renderAll() {
  renderTableHeader();
  renderGrid();
  renderPager();
  renderDetail();
}

function renderTableList() {
  const filter = elements.tableFilter.value.trim().toLowerCase();
  const tables = state.meta
    ? state.meta.tables.filter((table) => table.name.toLowerCase().includes(filter))
    : [];

  elements.tableList.replaceChildren(
    ...tables.map((table) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = `table-button${table.name === state.table ? ' active' : ''}`;
      button.addEventListener('click', () => {
        selectTable(table.name);
      });

      const name = document.createElement('span');
      name.className = 'table-name';
      name.textContent = table.name;

      const count = document.createElement('span');
      count.className = 'table-count';
      count.textContent = formatNumber(table.count);

      button.append(name, count);
      return button;
    }),
  );
}

function renderTableHeader() {
  const table = currentTable();
  const page = state.tablePage;

  elements.tableTitle.textContent = table.name;
  elements.tableStats.textContent = `${formatNumber(page.total)} matching rows, ${formatNumber(
    table.count,
  )} total, ${table.columns.length} columns`;
}

function renderGrid() {
  const table = currentTable();
  const rows = state.tablePage ? state.tablePage.rows : [];
  const columns = visibleColumns(table, rows);
  const headerRow = document.createElement('tr');

  for (const column of columns) {
    const th = document.createElement('th');
    const button = document.createElement('button');
    button.type = 'button';
    button.title = `Sort by ${column.name}`;
    button.textContent = column.name + sortSuffix(column.name);
    button.addEventListener('click', () => {
      if (state.sortBy === column.name) {
        state.sortDir = state.sortDir === 'asc' ? 'desc' : 'asc';
      } else {
        state.sortBy = column.name;
        state.sortDir = 'asc';
      }

      loadTableData();
    });
    th.append(button);
    headerRow.append(th);
  }

  elements.gridHead.replaceChildren(headerRow);
  elements.gridBody.replaceChildren(
    ...rows.map((row) => {
      const tr = document.createElement('tr');
      tr.className = state.selectedRow && sameRow(table, row, state.selectedRow) ? 'selected' : '';
      tr.addEventListener('click', () => {
        selectRow(row);
      });

      for (const column of columns) {
        const td = document.createElement('td');
        const value = row[column.name];
        const renderedValue = renderCellValue(table, column, value);
        td.textContent = renderedValue.text;
        td.title = renderedValue.title || renderedValue.text;

        if (value === null) {
          td.classList.add('cell-null');
        } else if (typeof value === 'number') {
          td.classList.add('cell-number');
        }

        tr.append(td);
      }

      return tr;
    }),
  );

  elements.emptyState.hidden = rows.length > 0;
}

function renderPager() {
  const count = pageCount();
  elements.pageLabel.textContent = `Page ${state.page} of ${count}`;
  elements.prevPage.disabled = state.busy || state.page <= 1;
  elements.nextPage.disabled = state.busy || state.page >= count;
}

function selectRow(row) {
  state.selectedRow = row;
  state.mode = 'edit';
  renderGrid();
  renderDetail();
}

function startNewRow() {
  state.selectedRow = buildEmptyRow(currentTable());
  state.mode = 'new';
  renderGrid();
  renderDetail();
}

function clearSelection() {
  state.selectedRow = null;
  state.mode = 'idle';
  renderGrid();
  renderDetail();
}

function renderDetail() {
  const table = currentTable();
  const row = state.selectedRow;
  const canEdit = Boolean(row);

  elements.rowForm.hidden = !canEdit;
  elements.clearSelection.disabled = state.busy || !canEdit;
  elements.saveRowButton.disabled = state.busy || !canEdit;
  elements.deleteRowButton.disabled = state.busy || state.mode !== 'edit';

  if (!row) {
    elements.detailTitle.textContent = 'No row selected';
    elements.detailMeta.textContent = 'Select a row or create a new one';
    elements.formFields.replaceChildren();
    return;
  }

  elements.detailTitle.textContent = state.mode === 'new' ? `New ${table.name} row` : rowLabel(table, row);
  elements.detailMeta.textContent =
    state.mode === 'new' ? 'Insert mode' : table.primaryKeys.map((key) => `${key}=${row[key]}`).join(', ');
  elements.formFields.replaceChildren(...table.columns.map((column) => renderField(table, column, row)));
}

function renderField(table, column, row) {
  const field = document.createElement('div');
  field.className = 'field';
  field.dataset.column = column.name;

  const labelRow = document.createElement('div');
  labelRow.className = 'field-label-row';

  const name = document.createElement('div');
  name.className = 'field-name';
  name.textContent = column.name;

  const flags = document.createElement('div');
  flags.className = 'field-flags';

  for (const flag of fieldFlags(table, column)) {
    const item = document.createElement('span');
    item.className = 'field-flag';
    item.textContent = flag;
    flags.append(item);
  }

  labelRow.append(name, flags);

  const input = renderInput(table, column, row[column.name]);
  input.dataset.role = 'value';

  const nullRow = document.createElement('label');
  nullRow.className = 'null-row';
  const nullToggle = document.createElement('input');
  nullToggle.type = 'checkbox';
  nullToggle.dataset.role = 'null';
  nullToggle.checked = row[column.name] === null || row[column.name] === undefined;
  nullToggle.disabled = column.notnull || column.pk > 0 || input.disabled;
  const nullText = document.createElement('span');
  nullText.textContent = 'NULL';
  nullRow.append(nullToggle, nullText);

  nullToggle.addEventListener('change', () => {
    input.disabled = nullToggle.checked || isReadOnlyField(table, column);
  });

  input.disabled = nullToggle.checked || isReadOnlyField(table, column);
  field.append(labelRow, input, nullRow);
  return field;
}

function renderInput(table, column, value) {
  const foreignKey = table.foreignKeyByColumn[column.name];
  const editablePrimaryKey = state.mode === 'new' && !isAutoIntegerPrimaryKey(table, column);

  if (foreignKey && (column.pk === 0 || editablePrimaryKey)) {
    const select = document.createElement('select');
    const lookup = state.meta.lookups[foreignKey.refTable];
    appendOption(select, '', column.notnull ? 'Choose value' : 'NULL');

    if (lookup) {
      for (const row of lookup.rows) {
        appendOption(select, String(row.value), `${row.value} - ${row.label}`);
      }
    }

    if (value !== null && value !== undefined && !selectHasValue(select, String(value))) {
      appendOption(select, String(value), String(value));
    }

    select.value = value === null || value === undefined ? '' : String(value);
    return select;
  }

  const input = document.createElement('input');
  input.type = isNumericColumn(column) ? 'number' : 'text';

  if (isRealColumn(column)) {
    input.step = 'any';
  } else if (isIntegerColumn(column)) {
    input.step = '1';
  }

  input.value = value === null || value === undefined ? '' : String(value);
  return input;
}

async function saveCurrentRow() {
  const table = currentTable();
  const values = collectFormValues(table);

  try {
    setBusy(true);

    if (state.mode === 'new') {
      const inserted = await window.rulesApi.insertRow({
        table: table.name,
        values,
      });
      await loadMeta();
      await loadTableData();
      state.selectedRow = inserted;
      state.mode = 'edit';
      renderAll();
      showToast('Inserted');
    } else {
      const updated = await window.rulesApi.updateRow({
        table: table.name,
        key: rowKey(table, state.selectedRow),
        values,
      });
      replaceRow(updated);
      state.selectedRow = updated;
      renderAll();
      showToast('Saved');
    }
  } catch (error) {
    showToast(error.message || String(error), true);
  } finally {
    setBusy(false);
  }
}

async function deleteCurrentRow() {
  const table = currentTable();

  if (!state.selectedRow || state.mode !== 'edit') {
    return;
  }

  if (!confirm(`Delete ${rowLabel(table, state.selectedRow)} from ${table.name}?`)) {
    return;
  }

  try {
    setBusy(true);
    await window.rulesApi.deleteRow({
      table: table.name,
      key: rowKey(table, state.selectedRow),
    });
    await loadMeta();
    await loadTableData();
    showToast('Deleted');
  } catch (error) {
    showToast(error.message || String(error), true);
  } finally {
    setBusy(false);
  }
}

function collectFormValues(table) {
  const values = {};

  for (const column of table.columns) {
    const field = elements.formFields.querySelector(`[data-column="${cssEscape(column.name)}"]`);

    if (!field) {
      continue;
    }

    if (state.mode === 'edit' && column.pk > 0) {
      continue;
    }

    if (state.mode === 'new' && isAutoIntegerPrimaryKey(table, column)) {
      continue;
    }

    const nullToggle = field.querySelector('[data-role="null"]');
    const input = field.querySelector('[data-role="value"]');

    values[column.name] = nullToggle && nullToggle.checked ? null : input.value;
  }

  return values;
}

function replaceRow(updatedRow) {
  const table = currentTable();
  const index = state.tablePage.rows.findIndex((row) => sameRow(table, row, state.selectedRow));

  if (index !== -1) {
    state.tablePage.rows[index] = updatedRow;
  }
}

function visibleColumns(table, rows) {
  if (!state.hideEmptyColumns || rows.length === 0) {
    return table.columns;
  }

  return table.columns.filter((column) => column.pk > 0 || rows.some((row) => row[column.name] !== null));
}

function renderCellValue(table, column, value) {
  if (value === null || value === undefined) {
    return { text: 'NULL' };
  }

  const foreignKey = table.foreignKeyByColumn[column.name];

  if (foreignKey) {
    const lookup = state.meta.lookups[foreignKey.refTable];
    const match = lookup && lookup.rows.find((row) => String(row.value) === String(value));

    if (match) {
      return {
        text: `${value} - ${match.label}`,
        title: `${foreignKey.refTable}.${foreignKey.refColumn}`,
      };
    }
  }

  return { text: String(value) };
}

function currentTable() {
  const table = findTable(state.table);

  if (!table) {
    throw new Error(`Table not loaded: ${state.table}`);
  }

  table.foreignKeyByColumn = Object.fromEntries(table.foreignKeys.map((foreignKey) => [foreignKey.column, foreignKey]));
  return table;
}

function findTable(name) {
  return state.meta ? state.meta.tables.find((table) => table.name === name) : null;
}

function rowKey(table, row) {
  return Object.fromEntries(table.primaryKeys.map((primaryKey) => [primaryKey, row[primaryKey]]));
}

function sameRow(table, left, right) {
  return table.primaryKeys.every((primaryKey) => String(left[primaryKey]) === String(right[primaryKey]));
}

function rowLabel(table, row) {
  if (Object.hasOwn(row, 'name') && row.name !== null) {
    return String(row.name);
  }

  return table.primaryKeys.map((primaryKey) => `${primaryKey}=${row[primaryKey]}`).join(', ');
}

function buildEmptyRow(table) {
  const row = {};

  for (const column of table.columns) {
    row[column.name] = column.notnull && !isAutoIntegerPrimaryKey(table, column) ? '' : null;
  }

  return row;
}

function isReadOnlyField(table, column) {
  if (state.mode === 'new') {
    return isAutoIntegerPrimaryKey(table, column);
  }

  return column.pk > 0;
}

function isAutoIntegerPrimaryKey(table, column) {
  return table.primaryKeys.length === 1 && column.pk === 1 && isIntegerColumn(column);
}

function isNumericColumn(column) {
  return isIntegerColumn(column) || isRealColumn(column);
}

function isIntegerColumn(column) {
  return String(column.type).toUpperCase().includes('INT');
}

function isRealColumn(column) {
  const type = String(column.type).toUpperCase();
  return type.includes('REAL') || type.includes('FLOA') || type.includes('DOUB');
}

function fieldFlags(table, column) {
  const flags = [];

  if (column.pk > 0) {
    flags.push('PK');
  }

  if (column.notnull) {
    flags.push('NOT NULL');
  }

  const foreignKey = table.foreignKeyByColumn[column.name];

  if (foreignKey) {
    flags.push(`FK ${foreignKey.refTable}`);
  }

  if (column.type) {
    flags.push(column.type);
  }

  return flags;
}

function sortSuffix(columnName) {
  if (state.sortBy !== columnName) {
    return '';
  }

  return state.sortDir === 'asc' ? ' ASC' : ' DESC';
}

function pageCount() {
  if (!state.tablePage) {
    return 1;
  }

  return Math.max(1, Math.ceil(state.tablePage.total / state.tablePage.pageSize));
}

function setBusy(isBusy) {
  state.busy = isBusy;
  elements.reloadButton.disabled = isBusy;
  elements.newRowButton.disabled = isBusy;
  elements.backupButton.disabled = isBusy;
  renderPager();
  renderDetail();
}

function showToast(message, isError = false) {
  elements.toast.textContent = message;
  elements.toast.style.background = isError ? '#7a1d16' : '#15221f';
  elements.toast.hidden = false;
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => {
    elements.toast.hidden = true;
  }, isError ? 6500 : 3200);
}

function appendOption(select, value, label) {
  const option = document.createElement('option');
  option.value = value;
  option.textContent = label;
  select.append(option);
}

function selectHasValue(select, value) {
  return [...select.options].some((option) => option.value === value);
}

function debounce(callback, delayMs) {
  let timer = 0;

  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => callback(...args), delayMs);
  };
}

function delay(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function createRequestId() {
  if (window.crypto && typeof window.crypto.randomUUID === 'function') {
    return window.crypto.randomUUID();
  }

  return `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function formatNumber(value) {
  return new Intl.NumberFormat('en-US').format(value);
}

function cssEscape(value) {
  if (window.CSS && window.CSS.escape) {
    return window.CSS.escape(value);
  }

  return String(value).replaceAll('"', '\\"');
}
