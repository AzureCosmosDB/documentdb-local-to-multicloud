import { randomUUID } from 'node:crypto';
import type { AppConfig, ClusterId } from './config.js';
import type { AppState, ClusterStatus, DemoEvent } from './types.js';

const MAX_EVENTS = 20;

function emptyClusterStatus(id: ClusterId, name: string, region: string): ClusterStatus {
  return {
    id,
    name,
    region,
    role: 'UNREACHABLE',
    reachable: false,
    docCount: null,
    lastEventTs: null,
    latencyMs: null,
    lastError: null,
    lastPolledAt: 0,
  };
}

export class StateStore {
  state: AppState;
  private listeners = new Set<(s: AppState) => void>();
  private eventListeners = new Set<(e: DemoEvent) => void>();

  constructor(cfg: AppConfig) {
    const aks = emptyClusterStatus('aks', cfg.clusters.aks.name, cfg.clusters.aks.region);
    const eks = emptyClusterStatus('eks', cfg.clusters.eks.name, cfg.clusters.eks.region);
    aks.role = cfg.initialPrimary === 'aks' ? 'PRIMARY' : 'REPLICA';
    eks.role = cfg.initialPrimary === 'eks' ? 'PRIMARY' : 'REPLICA';

    this.state = {
      primary: cfg.initialPrimary,
      clusters: { aks, eks },
      replicationLagMs: null,
      autoInsert: { enabled: true, rateHz: 2, consecutiveFailures: 0 },
      failover: {
        active: false,
        fromCluster: null,
        toCluster: null,
        phase: 'idle',
        startedAt: null,
        finishedAt: null,
        message: null,
      },
      events: [],
    };
  }

  onChange(fn: (s: AppState) => void) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  onEvent(fn: (e: DemoEvent) => void) {
    this.eventListeners.add(fn);
    return () => this.eventListeners.delete(fn);
  }

  emit() {
    for (const fn of this.listeners) fn(this.state);
  }

  pushEvent(kind: DemoEvent['kind'], message: string, cluster?: ClusterId) {
    const event: DemoEvent = {
      id: randomUUID(),
      ts: Date.now(),
      kind,
      message,
      cluster,
    };
    this.state.events = [event, ...this.state.events].slice(0, MAX_EVENTS);
    for (const fn of this.eventListeners) fn(event);
    this.emit();
  }

  updateCluster(id: ClusterId, patch: Partial<ClusterStatus>) {
    this.state.clusters[id] = { ...this.state.clusters[id], ...patch, lastPolledAt: Date.now() };
    this.recomputeLag();
  }

  setPrimary(id: ClusterId) {
    this.state.primary = id;
    const other: ClusterId = id === 'aks' ? 'eks' : 'aks';
    if (this.state.clusters[id].reachable) {
      this.state.clusters[id].role = 'PRIMARY';
    }
    if (this.state.clusters[other].reachable) {
      this.state.clusters[other].role = 'REPLICA';
    }
    this.recomputeLag();
  }

  private recomputeLag() {
    const primary = this.state.clusters[this.state.primary];
    const other: ClusterId = this.state.primary === 'aks' ? 'eks' : 'aks';
    const replica = this.state.clusters[other];
    if (primary.lastEventTs && replica.lastEventTs) {
      this.state.replicationLagMs = Math.max(0, primary.lastEventTs - replica.lastEventTs);
    } else {
      this.state.replicationLagMs = null;
    }
  }
}
