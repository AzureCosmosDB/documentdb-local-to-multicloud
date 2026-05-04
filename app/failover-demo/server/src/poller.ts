import type { Logger } from 'pino';
import type { AppConfig, ClusterId } from './config.js';
import type { ClusterClients } from './db.js';
import type { StateStore } from './state.js';

const POLL_INTERVAL_MS = 500;
const QUERY_TIMEOUT_MS = 5000;

async function pollOne(
  cc: ClusterClients,
  app: AppConfig,
  store: StateStore,
  log: Logger,
): Promise<void> {
  const start = Date.now();
  try {
    const coll = cc.collection();
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), QUERY_TIMEOUT_MS);
    try {
      const docCount = await coll.estimatedDocumentCount({ maxTimeMS: QUERY_TIMEOUT_MS });
      const latest = await coll
        .find({}, { projection: { ts: 1 } })
        .sort({ ts: -1 })
        .limit(1)
        .maxTimeMS(QUERY_TIMEOUT_MS)
        .toArray();
      const lastEventTs =
        latest.length > 0 && latest[0].ts instanceof Date
          ? (latest[0].ts as Date).getTime()
          : latest.length > 0 && typeof latest[0].ts === 'number'
            ? (latest[0].ts as number)
            : null;
      const latency = Date.now() - start;
      const wasReachable = store.state.clusters[cc.id].reachable;
      store.updateCluster(cc.id, {
        reachable: true,
        docCount,
        lastEventTs,
        latencyMs: latency,
        lastError: null,
        role:
          store.state.failover.active && store.state.failover.fromCluster === cc.id
            ? 'DEMOTING'
            : store.state.failover.active && store.state.failover.toCluster === cc.id
              ? 'PROMOTING'
              : store.state.primary === cc.id
                ? 'PRIMARY'
                : 'REPLICA',
      });
      if (!wasReachable) {
        store.pushEvent('info', `${cc.cfg.name} reachable`, cc.id);
      }
    } finally {
      clearTimeout(t);
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const wasReachable = store.state.clusters[cc.id].reachable;
    store.updateCluster(cc.id, {
      reachable: false,
      role: 'UNREACHABLE',
      lastError: msg,
      latencyMs: null,
    });
    if (wasReachable) {
      store.pushEvent('error', `${cc.cfg.name} unreachable: ${truncate(msg)}`, cc.id);
    }
    log.debug({ cluster: cc.id, err: msg }, 'poll failed');
  }
}

function truncate(s: string, n = 80) {
  return s.length > n ? s.slice(0, n) + '…' : s;
}

export function startPoller(
  clients: Record<ClusterId, ClusterClients>,
  app: AppConfig,
  store: StateStore,
  log: Logger,
) {
  let stopped = false;
  const tick = async () => {
    if (stopped) return;
    await Promise.allSettled([
      pollOne(clients.aks, app, store, log),
      pollOne(clients.eks, app, store, log),
    ]);
    if (!stopped) setTimeout(tick, POLL_INTERVAL_MS);
  };
  tick();
  return () => {
    stopped = true;
  };
}
