import { copyFileSync, existsSync, statSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const moduleDirectory = dirname(fileURLToPath(import.meta.url));
export const defaultDatabasePath = resolve(
  moduleDirectory,
  '..',
  '..',
  '..',
  'assets',
  'converted',
  'rules.db',
);

const MAX_PAGE_SIZE = 200;
const DEFAULT_PAGE_SIZE = 50;

export class RulesDatabase {
  constructor(databasePath = defaultDatabasePath) {
    this.databasePath = resolve(databasePath);

    if (!existsSync(this.databasePath)) {
      throw new Error(`Database not found: ${this.databasePath}`);
    }

    this.db = new DatabaseSync(this.databasePath);
    this.db.exec('PRAGMA foreign_keys = ON');
    this.refreshSchema();
  }

  close() {
    this.db.close();
  }

  refreshSchema() {
    const rows = this.db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      )
      .all();

    this.tables = new Map();

    for (const row of rows) {
      const name = row.name;
      const columns = this.db
        .prepare(`PRAGMA table_info(${quoteIdentifier(name)})`)
        .all()
        .map((column) => ({
          cid: column.cid,
          name: column.name,
          type: column.type || '',
          notnull: Boolean(column.notnull),
          defaultValue: column.dflt_value,
          pk: column.pk,
        }));

      const foreignKeys = this.db
        .prepare(`PRAGMA foreign_key_list(${quoteIdentifier(name)})`)
        .all()
        .map((foreignKey) => ({
          column: foreignKey.from,
          refTable: foreignKey.table,
          refColumn: foreignKey.to,
        }));

      const foreignKeyByColumn = Object.fromEntries(
        foreignKeys.map((foreignKey) => [foreignKey.column, foreignKey]),
      );
      const primaryKeys = columns
        .filter((column) => column.pk > 0)
        .sort((left, right) => left.pk - right.pk)
        .map((column) => column.name);

      this.tables.set(name, {
        name,
        columns,
        columnsByName: new Map(columns.map((column) => [column.name, column])),
        foreignKeys,
        foreignKeyByColumn,
        primaryKeys,
      });
    }
  }

  getMeta() {
    const tables = [...this.tables.values()].map((table) => ({
      name: table.name,
      count: this.countRows(table.name),
      columns: table.columns,
      foreignKeys: table.foreignKeys,
      primaryKeys: table.primaryKeys,
    }));

    return {
      databasePath: this.databasePath,
      databaseSize: statSync(this.databasePath).size,
      tables,
      lookups: this.getLookups(),
    };
  }

  getTableData(request) {
    const table = this.requireTable(request?.table);
    const pageSize = clampInteger(request?.pageSize, 1, MAX_PAGE_SIZE, DEFAULT_PAGE_SIZE);
    const page = clampInteger(request?.page, 1, Number.MAX_SAFE_INTEGER, 1);
    const search = String(request?.search || '').trim();
    const sortBy = this.resolveSortColumn(table, request?.sortBy);
    const sortDirection = String(request?.sortDir || '').toLowerCase() === 'desc' ? 'DESC' : 'ASC';

    const where = this.buildSearchWhere(table, search);
    const total = this.db
      .prepare(`SELECT COUNT(*) AS count FROM ${quoteIdentifier(table.name)}${where.sql}`)
      .get(...where.params).count;
    const maxPage = Math.max(1, Math.ceil(total / pageSize));
    const safePage = Math.min(page, maxPage);
    const offset = (safePage - 1) * pageSize;
    const rows = this.db
      .prepare(
        `SELECT * FROM ${quoteIdentifier(table.name)}${where.sql} ORDER BY ${quoteIdentifier(sortBy)} ${sortDirection} LIMIT ? OFFSET ?`,
      )
      .all(...where.params, pageSize, offset)
      .map(toPlainObject);

    return {
      table: table.name,
      rows,
      total,
      page: safePage,
      pageSize,
      sortBy,
      sortDir: sortDirection.toLowerCase(),
    };
  }

  updateRow(request) {
    const table = this.requireTable(request?.table);
    const key = request?.key || {};
    const values = request?.values || {};
    const primaryKeys = this.requirePrimaryKeys(table);
    const assignments = [];
    const params = [];

    for (const column of table.columns) {
      if (primaryKeys.includes(column.name) || !Object.hasOwn(values, column.name)) {
        continue;
      }

      assignments.push(`${quoteIdentifier(column.name)} = ?`);
      params.push(normalizeValue(values[column.name], column));
    }

    if (assignments.length === 0) {
      return this.getRowByKey(table.name, key);
    }

    const where = this.buildKeyWhere(table, key);
    const result = this.db
      .prepare(
        `UPDATE ${quoteIdentifier(table.name)} SET ${assignments.join(', ')} WHERE ${where.sql}`,
      )
      .run(...params, ...where.params);

    if (result.changes !== 1) {
      throw new Error(`Expected to update 1 row, updated ${result.changes}`);
    }

    return this.getRowByKey(table.name, key);
  }

  insertRow(request) {
    const table = this.requireTable(request?.table);
    const values = request?.values || {};
    const insertedColumns = [];
    const params = [];

    for (const column of table.columns) {
      const rawValue = Object.hasOwn(values, column.name) ? values[column.name] : undefined;

      if (isAutoIntegerPrimaryKey(table, column) && isEmptyInput(rawValue)) {
        continue;
      }

      if (rawValue === undefined) {
        continue;
      }

      insertedColumns.push(column.name);
      params.push(normalizeValue(rawValue, column));
    }

    if (insertedColumns.length === 0) {
      throw new Error('No values to insert');
    }

    const placeholders = insertedColumns.map(() => '?').join(', ');
    const result = this.db
      .prepare(
        `INSERT INTO ${quoteIdentifier(table.name)} (${insertedColumns
          .map(quoteIdentifier)
          .join(', ')}) VALUES (${placeholders})`,
      )
      .run(...params);

    const key = {};
    const primaryKeys = this.requirePrimaryKeys(table);

    if (primaryKeys.length === 1 && !Object.hasOwn(values, primaryKeys[0])) {
      key[primaryKeys[0]] = result.lastInsertRowid;
    } else {
      for (const primaryKey of primaryKeys) {
        const column = table.columnsByName.get(primaryKey);
        key[primaryKey] = normalizeValue(values[primaryKey], column);
      }
    }

    return this.getRowByKey(table.name, key);
  }

  deleteRow(request) {
    const table = this.requireTable(request?.table);
    const key = request?.key || {};
    const where = this.buildKeyWhere(table, key);
    const result = this.db
      .prepare(`DELETE FROM ${quoteIdentifier(table.name)} WHERE ${where.sql}`)
      .run(...where.params);

    if (result.changes !== 1) {
      throw new Error(`Expected to delete 1 row, deleted ${result.changes}`);
    }

    return { deleted: true };
  }

  createBackup() {
    const timestamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..+$/, '').replace('T', '-');
    const backupPath = `${this.databasePath}.${timestamp}.bak`;
    copyFileSync(this.databasePath, backupPath);
    return { backupPath };
  }

  getRowByKey(tableName, key) {
    const table = this.requireTable(tableName);
    const where = this.buildKeyWhere(table, key);
    const row = this.db
      .prepare(`SELECT * FROM ${quoteIdentifier(table.name)} WHERE ${where.sql}`)
      .get(...where.params);

    if (!row) {
      throw new Error(`Row not found in ${table.name}`);
    }

    return toPlainObject(row);
  }

  getLookups() {
    const referencedTables = new Set();

    for (const table of this.tables.values()) {
      for (const foreignKey of table.foreignKeys) {
        referencedTables.add(foreignKey.refTable);
      }
    }

    const lookups = {};

    for (const tableName of referencedTables) {
      const table = this.tables.get(tableName);

      if (!table) {
        continue;
      }

      const primaryKey = table.primaryKeys.length === 1 ? table.primaryKeys[0] : null;

      if (!primaryKey) {
        continue;
      }

      const labelColumn = table.columnsByName.has('name') ? 'name' : primaryKey;
      const rows = this.db
        .prepare(
          `SELECT ${quoteIdentifier(primaryKey)} AS value, ${quoteIdentifier(labelColumn)} AS label FROM ${quoteIdentifier(
            tableName,
          )} ORDER BY ${quoteIdentifier(labelColumn)} COLLATE NOCASE, ${quoteIdentifier(primaryKey)} LIMIT 1000`,
        )
        .all()
        .map((row) => ({
          value: row.value,
          label: String(row.label),
        }));

      lookups[tableName] = {
        keyColumn: primaryKey,
        labelColumn,
        rows,
      };
    }

    return lookups;
  }

  countRows(tableName) {
    const table = this.requireTable(tableName);
    return this.db.prepare(`SELECT COUNT(*) AS count FROM ${quoteIdentifier(table.name)}`).get().count;
  }

  requireTable(tableName) {
    if (!tableName || !this.tables.has(tableName)) {
      throw new Error(`Unknown table: ${tableName}`);
    }

    return this.tables.get(tableName);
  }

  requirePrimaryKeys(table) {
    if (table.primaryKeys.length === 0) {
      throw new Error(`Table ${table.name} has no primary key`);
    }

    return table.primaryKeys;
  }

  resolveSortColumn(table, requestedColumn) {
    if (requestedColumn && table.columnsByName.has(requestedColumn)) {
      return requestedColumn;
    }

    if (table.columnsByName.has('name')) {
      return 'name';
    }

    return table.primaryKeys[0] || table.columns[0].name;
  }

  buildSearchWhere(table, search) {
    if (!search) {
      return { sql: '', params: [] };
    }

    const like = `%${escapeLike(search)}%`;
    const conditions = table.columns.map(
      (column) => `CAST(${quoteIdentifier(column.name)} AS TEXT) LIKE ? ESCAPE '\\'`,
    );

    return {
      sql: ` WHERE ${conditions.join(' OR ')}`,
      params: conditions.map(() => like),
    };
  }

  buildKeyWhere(table, key) {
    const primaryKeys = this.requirePrimaryKeys(table);
    const conditions = [];
    const params = [];

    for (const primaryKey of primaryKeys) {
      if (!Object.hasOwn(key, primaryKey)) {
        throw new Error(`Missing primary key field: ${primaryKey}`);
      }

      const column = table.columnsByName.get(primaryKey);
      conditions.push(`${quoteIdentifier(primaryKey)} = ?`);
      params.push(normalizeValue(key[primaryKey], column));
    }

    return {
      sql: conditions.join(' AND '),
      params,
    };
  }
}

function quoteIdentifier(identifier) {
  return `"${String(identifier).replaceAll('"', '""')}"`;
}

function clampInteger(value, min, max, fallback) {
  const parsed = Number.parseInt(value, 10);

  if (!Number.isFinite(parsed)) {
    return fallback;
  }

  return Math.min(max, Math.max(min, parsed));
}

function normalizeValue(value, column) {
  if (value === null || value === undefined) {
    return null;
  }

  if (typeof value === 'string' && value === '' && !isTextColumn(column)) {
    return null;
  }

  if (isIntegerColumn(column)) {
    const parsed = Number(value);

    if (!Number.isInteger(parsed)) {
      throw new Error(`${column.name} expects an integer`);
    }

    return parsed;
  }

  if (isRealColumn(column)) {
    const parsed = Number(value);

    if (!Number.isFinite(parsed)) {
      throw new Error(`${column.name} expects a number`);
    }

    return parsed;
  }

  return String(value);
}

function isIntegerColumn(column) {
  return column.type.toUpperCase().includes('INT');
}

function isRealColumn(column) {
  const type = column.type.toUpperCase();
  return type.includes('REAL') || type.includes('FLOA') || type.includes('DOUB');
}

function isTextColumn(column) {
  const type = column.type.toUpperCase();
  return type.includes('TEXT') || type.includes('CHAR') || type.includes('CLOB');
}

function isAutoIntegerPrimaryKey(table, column) {
  return table.primaryKeys.length === 1 && column.pk === 1 && isIntegerColumn(column);
}

function isEmptyInput(value) {
  return value === null || value === undefined || value === '';
}

function escapeLike(value) {
  return value.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');
}

function toPlainObject(row) {
  return Object.fromEntries(Object.entries(row));
}
