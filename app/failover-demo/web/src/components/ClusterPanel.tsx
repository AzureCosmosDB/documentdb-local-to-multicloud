import { useEffect, useState } from 'react';
import type { ClusterStatus } from '../types';

interface Props {
  cluster: ClusterStatus;
  isPrimary: boolean;
  replicationLagMs: number | null;
}

function relativeTime(ts: number | null): string {
  if (!ts) return '—';
  const diff = Date.now() - ts;
  if (diff < 1000) return `${diff}ms ago`;
  if (diff < 60_000) return `${(diff / 1000).toFixed(1)}s ago`;
  return `${Math.floor(diff / 60_000)}m ago`;
}

export function ClusterPanel({ cluster, isPrimary, replicationLagMs }: Props) {
  const [pulse, setPulse] = useState(false);
  const [prevCount, setPrevCount] = useState<number | null>(cluster.docCount);

  useEffect(() => {
    if (cluster.docCount !== null && prevCount !== null && cluster.docCount > prevCount) {
      setPulse(true);
      const t = setTimeout(() => setPulse(false), 500);
      return () => clearTimeout(t);
    }
    setPrevCount(cluster.docCount);
  }, [cluster.docCount, prevCount]);

  const roleClass = cluster.role.toLowerCase();
  const reachableDot = cluster.reachable ? 'ok' : 'bad';

  return (
    <div className={`panel ${roleClass} ${pulse ? 'pulse' : ''}`}>
      <div className="panel-head">
        <div>
          <div className="panel-name">{cluster.name}</div>
          <div className="panel-region">{cluster.region}</div>
        </div>
        <div>
          <span className={`status-dot ${reachableDot}`}></span>
          {cluster.reachable ? 'reachable' : 'unreachable'}
        </div>
      </div>

      <span className={`role-badge role-${cluster.role}`}>{cluster.role}</span>

      <div className="big-number">
        {cluster.docCount === null ? '—' : cluster.docCount.toLocaleString()}
      </div>
      <div style={{ color: '#8b949e', fontSize: 14 }}>documents in failover_demo_events</div>

      <div className="meta-grid">
        <div className="label">Last write</div>
        <div className="value">{relativeTime(cluster.lastEventTs)}</div>

        <div className="label">Round-trip</div>
        <div className="value">
          {cluster.latencyMs === null ? '—' : `${cluster.latencyMs} ms`}
        </div>

        {!isPrimary && (
          <>
            <div className="label">Replication lag</div>
            <div className="value">
              {replicationLagMs === null ? '—' : `${replicationLagMs} ms`}
            </div>
          </>
        )}

        {cluster.lastError && (
          <>
            <div className="label" style={{ color: '#ef4444' }}>Error</div>
            <div className="value" style={{ color: '#ef4444', fontSize: 12 }}>
              {cluster.lastError.slice(0, 60)}
            </div>
          </>
        )}
      </div>
    </div>
  );
}
