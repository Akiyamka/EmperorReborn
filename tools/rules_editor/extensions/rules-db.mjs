import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { RulesDatabase, defaultDatabasePath } from '../app/db.mjs';

const input = JSON.parse(readFileSync(process.stdin.fd, 'utf8'));
const database = new RulesDatabase(process.env.RULES_DB || defaultDatabasePath);
const client = new WebSocket(
  `ws://localhost:${input.nlPort}?extensionId=${input.nlExtensionId}&connectToken=${input.nlConnectToken}`,
);

client.addEventListener('message', async (event) => {
  let message;

  try {
    message = JSON.parse(event.data);
  } catch (error) {
    console.error(`Invalid Neutralino extension message: ${error.message}`);
    return;
  }

  if (message.event !== 'rulesDbRequest') {
    return;
  }

  const response = await handleRequest(message.data || {});
  broadcast('rulesDbResponse', response);
});

client.addEventListener('close', () => {
  database.close();
  process.exit(0);
});

client.addEventListener('error', (event) => {
  console.error('Neutralino extension WebSocket error', event.message || event.type);
});

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

async function handleRequest(request) {
  const id = request.id;

  try {
    if (!id) {
      throw new Error('Missing request id');
    }

    const args = Array.isArray(request.args) ? request.args : [];
    const result = dispatch(request.method, args);
    return { id, ok: true, result };
  } catch (error) {
    return {
      id,
      ok: false,
      error: error.message || String(error),
    };
  }
}

function dispatch(method, args) {
  switch (method) {
    case 'getMeta':
      return database.getMeta();
    case 'getTableData':
      return database.getTableData(args[0]);
    case 'updateRow':
      return database.updateRow(args[0]);
    case 'insertRow':
      return database.insertRow(args[0]);
    case 'deleteRow':
      return database.deleteRow(args[0]);
    case 'createBackup':
      return database.createBackup();
    default:
      throw new Error(`Unknown method: ${method}`);
  }
}

function broadcast(event, data) {
  if (client.readyState !== WebSocket.OPEN) {
    return;
  }

  client.send(
    JSON.stringify({
      id: randomUUID(),
      method: 'app.broadcast',
      accessToken: input.nlToken,
      data: { event, data },
    }),
  );
}

function shutdown() {
  database.close();
  client.close();
  process.exit(0);
}
