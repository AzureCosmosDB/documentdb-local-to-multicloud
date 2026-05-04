import express from 'express';
import { createServer } from 'node:http';
import { pino } from 'pino';
import { loadConfig } from './config.js';
import { StateStore } from './state.js';
import { buildAllClients } from './db.js';
import { startPoller } from './poller.js';
import { Writer } from './writer.js';
import { Broadcaster } from './ws.js';
import { runFailover } from './failover.js';

async function main() {
  const cfg = loadConfig();
  const log = pino({
    level: cfg.logLevel,
    transport:
      process.env.NODE_ENV === 'production'
        ? undefined
        : { target: 'pino-pretty', options: { colorize: true, translateTime: 'SYS:HH:MM:ss' } },
  });

  const store = new StateStore(cfg);
  const clients = buildAllClients(cfg, log);
  startPoller(clients, cfg, store, log);
  const writer = new Writer(clients, cfg, store, log);
  writer.start();

  const app = express();
  app.use(express.json());

  app.get('/api/state', (_req, res) => {
    res.json(store.state);
  });

  app.post('/api/insert', async (_req, res) => {
    const result = await writer.insertOnce();
    if (result.ok) res.json(result);
    else res.status(500).json(result);
  });

  app.post('/api/auto-insert', (req, res) => {
    const enabled = Boolean(req.body?.enabled);
    const rateHz = Number(req.body?.rateHz);
    writer.setAuto(enabled, Number.isFinite(rateHz) ? rateHz : undefined);
    res.json({ ok: true, autoInsert: store.state.autoInsert });
  });

  app.post('/api/failover', async (req, res) => {
    const target = req.body?.target;
    if (target !== 'aks' && target !== 'eks') {
      return res.status(400).json({ ok: false, error: 'target must be "aks" or "eks"' });
    }
    res.json({ ok: true, accepted: true });
    runFailover(target, {
      clients,
      app: cfg,
      store,
      log,
      broadcastLog: (line) => broadcaster.broadcastLog(line),
    }).catch((err) => log.error({ err: err.message }, 'failover failed'));
  });

  app.get('/healthz', (_req, res) => res.json({ ok: true }));

  const server = createServer(app);
  const broadcaster = new Broadcaster(server, store, log);

  store.onEvent(() => {
    /* triggers ws broadcast via Broadcaster */
  });

  server.listen(cfg.port, () => {
    log.info({ port: cfg.port }, 'failover-demo server listening');
    log.info(
      { aks: cfg.clusters.aks.uri.replace(/:\/\/[^@]+@/, '://***@'), eks: cfg.clusters.eks.uri.replace(/:\/\/[^@]+@/, '://***@') },
      'cluster URIs',
    );
  });

  const shutdown = async () => {
    log.info('shutting down');
    writer.stop();
    await Promise.allSettled([clients.aks.close(), clients.eks.close()]);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 5000).unref();
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
