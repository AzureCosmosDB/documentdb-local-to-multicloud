import type { ClusterId } from './config.js';

export type ClusterRole = 'PRIMARY' | 'REPLICA' | 'READ-ONLY' | 'UNREACHABLE' | 'DEMOTING' | 'PROMOTING';

export interface ClusterStatus {
  id: ClusterId;
  name: string;
  region: string;
  role: ClusterRole;
  reachable: boolean;
  docCount: number | null;
  lastEventTs: number | null;
  latencyMs: number | null;
  lastError: string | null;
  lastPolledAt: number;
}

export interface FailoverProgress {
  active: boolean;
  fromCluster: ClusterId | null;
  toCluster: ClusterId | null;
  phase: 'idle' | 'promoting' | 'reconfiguring' | 'routing' | 'complete' | 'failed';
  startedAt: number | null;
  finishedAt: number | null;
  message: string | null;
}

export interface AutoInsertState {
  enabled: boolean;
  rateHz: number;
  consecutiveFailures: number;
}

export interface DemoEvent {
  id: string;
  ts: number;
  kind: 'insert' | 'failover' | 'error' | 'info';
  message: string;
  cluster?: ClusterId;
}

export interface AppState {
  primary: ClusterId;
  clusters: Record<ClusterId, ClusterStatus>;
  replicationLagMs: number | null;
  autoInsert: AutoInsertState;
  failover: FailoverProgress;
  events: DemoEvent[];
}

export type WsMessage =
  | { type: 'state'; state: AppState }
  | { type: 'event'; event: DemoEvent }
  | { type: 'failover-log'; line: string };
