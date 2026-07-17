import { RulesDatabase, defaultDatabasePath } from './db.mjs';

const database = new RulesDatabase(process.env.RULES_DB || defaultDatabasePath);

try {
  const meta = database.getMeta();

  if (meta.tables.length === 0) {
    throw new Error('No tables found');
  }

  const preferredTable = meta.tables.some((table) => table.name === 'units') ? 'units' : meta.tables[0].name;
  const page = database.getTableData({
    table: preferredTable,
    page: 1,
    pageSize: 5,
    search: '',
    sortBy: null,
    sortDir: 'asc',
  });

  if (!Array.isArray(page.rows)) {
    throw new Error('Rows payload is not an array');
  }

  console.log(`OK: ${meta.tables.length} tables, ${preferredTable} page has ${page.rows.length} rows`);
} finally {
  database.close();
}
