import { randomUUID } from 'node:crypto';
import type { Logger } from 'pino';
import type { AppConfig, ClusterId } from './config.js';
import type { ClusterClients } from './db.js';
import type { StateStore } from './state.js';

const CITIES = ['Antwerp', 'Bruges', 'Ghent', 'Brussels', 'Leuven', 'Liege', 'Namur', 'Mechelen'];
const QUERY_TIMEOUT_MS = 5000;
const MAX_RETRIES = 3;

function pickCity() {
  return CITIES[Math.floor(Math.random() * CITIES.length)];
}

function buildDoc(seq: number) {
  return {
    _id: randomUUID(),
    seq,
    source: 'demo-writer',
    ts: new Date(),
    payload: {
      city: pickCity(),
      beds: 1 + Math.floor(Math.random() * 5),
      price: 100 + Math.floor(Math.random() * 401),
    },
  };
}

export class Writer {
  private seq = 0;
  private timer: NodeJS.Timeout | null = null;
  private inflight = false;

  constructor(
    private clients: Record<ClusterId, ClusterClients>,
    private app: AppConfig,
    private store: StateStore,
    private log: Logger,
  ) {}

  start() {
    this.reschedule();
  }

  stop() {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  }

  setAuto(enabled: boolean, rateHz?: number) {
    this.store.state.autoInsert.enabled = enabled;
    if (typeof rateHz === 'number' && rateHz > 0) {
      this.store.state.autoInsert.rateHz = Math.max(1, Math.min(20, rateHz));
    }
    this.store.state.autoInsert.consecutiveFailures = 0;
    this.store.emit();
    this.reschedule();
  }

  private reschedule() {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    if (!this.store.state.autoInsert.enabled) return;
    const interval = Math.max(50, Math.floor(1000 / this.store.state.autoInsert.rateHz));
    this.timer = setTimeout(() => this.tick(), interval);
  }

  private async tick() {
    if (this.inflight) {
      this.reschedule();
      return;
    }
    this.inflight = true;
    try {
      await this.insertOnce();
    } finally {
      this.inflight = false;
      this.reschedule();
    }
  }

  async insertOnce(): Promise<{ ok: true; cluster: ClusterId; seq: number } | { ok: false; error: string }> {
    const target = this.store.state.primary;
    const cc = this.clients[target];
    const doc = buildDoc(++this.seq);
    let lastErr: string = '';
    for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
      try {
        await cc.collection().insertOne(doc as any, { maxTimeMS: QUERY_TIMEOUT_MS });
        this.store.state.autoInsert.consecutiveFailures = 0;
        this.store.pushEvent('insert', `insert seq=${doc.seq} → ${cc.cfg.name}`, target);
        return { ok: true, cluster: target, seq: doc.seq };
      } catch (err) {
        lastErr = err instanceof Error ? err.message : String(err);
        this.log.warn({ attempt, cluster: target, err: lastErr }, 'insert failed');
        await new Promise((r) => setTimeout(r, 100 * attempt));
      }
    }
    this.store.state.autoInsert.consecutiveFailures++;
    if (this.store.state.autoInsert.consecutiveFailures >= 3 && this.store.state.autoInsert.enabled) {
      this.store.state.autoInsert.enabled = false;
      this.store.pushEvent('error', `auto-insert paused after repeated failures: ${lastErr.slice(0, 80)}`, target);
    } else {
      this.store.pushEvent('error', `insert failed (${target}): ${lastErr.slice(0, 80)}`, target);
    }
    return { ok: false, error: lastErr };
  }
}
