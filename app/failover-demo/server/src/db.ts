import { MongoClient, type Collection } from 'mongodb';
import type { AppConfig, ClusterConfig, ClusterId } from './config.js';
import type { Logger } from 'pino';

export interface ClusterClients {
  id: ClusterId;
  cfg: ClusterConfig;
  client: MongoClient;
  collection(): Collection;
  close(): Promise<void>;
}

export function buildClient(cfg: ClusterConfig, app: AppConfig, log: Logger): ClusterClients {
  const client = new MongoClient(cfg.uri, {
    serverSelectionTimeoutMS: 5000,
    connectTimeoutMS: 5000,
    socketTimeoutMS: 8000,
    directConnection: true,
    retryWrites: false,
    appName: 'failover-demo',
  });

  client.on('serverHeartbeatFailed', (ev) => {
    log.debug({ cluster: cfg.id, err: ev.failure?.message }, 'heartbeat failed');
  });

  return {
    id: cfg.id,
    cfg,
    client,
    collection() {
      return client.db(app.demoDb).collection(app.demoCollection);
    },
    async close() {
      try {
        await client.close(true);
      } catch {
        /* ignore */
      }
    },
  };
}

export function buildAllClients(app: AppConfig, log: Logger): Record<ClusterId, ClusterClients> {
  return {
    aks: buildClient(app.clusters.aks, app, log),
    eks: buildClient(app.clusters.eks, app, log),
  };
}
