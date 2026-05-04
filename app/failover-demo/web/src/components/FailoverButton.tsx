import { useEffect, useState } from 'react';
import type { AppState, ClusterId } from '../types';

interface Props {
  state: AppState;
  failoverLog: string[];
  onClearLog: () => void;
}

const PHASE_PROGRESS: Record<string, number> = {
  idle: 0,
  promoting: 25,
  reconfiguring: 60,
  routing: 90,
  complete: 100,
  failed: 100,
};

export function FailoverButton({ state, failoverLog, onClearLog }: Props) {
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [countdown, setCountdown] = useState(5);

  useEffect(() => {
    if (!confirmOpen) {
      setCountdown(5);
      return;
    }
    const t = setInterval(() => setCountdown((c) => Math.max(0, c - 1)), 1000);
    return () => clearInterval(t);
  }, [confirmOpen]);

  const target: ClusterId = state.primary === 'aks' ? 'eks' : 'aks';
  const fromName = state.clusters[state.primary].name;
  const toName = state.clusters[target].name;

  const triggerFailover = async () => {
    setConfirmOpen(false);
    onClearLog();
    await fetch('/api/failover', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ target }),
    });
  };

  if (state.failover.active || state.failover.phase === 'complete' || state.failover.phase === 'failed') {
    const pct = PHASE_PROGRESS[state.failover.phase] ?? 0;
    const isFailed = state.failover.phase === 'failed';
    const isComplete = state.failover.phase === 'complete';
    return (
      <>
        <div className="failover-progress" style={isFailed ? { background: '#5a1f1f' } : isComplete ? { background: '#1f5a3a' } : undefined}>
          <div className="bar" style={{ width: `${pct}%` }} />
          <div className="label">
            {isFailed ? '✗ ' : isComplete ? '✓ ' : ''}
            {state.failover.phase.toUpperCase()}
            {state.failover.message ? ` — ${state.failover.message}` : ''}
          </div>
        </div>
        {failoverLog.length > 0 && (
          <div className="failover-log-pane">
            {failoverLog.map((line, i) => (
              <div key={i}>{line}</div>
            ))}
          </div>
        )}
      </>
    );
  }

  return (
    <>
      <button className="failover-button" onClick={() => setConfirmOpen(true)}>
        🔴 FAILOVER {fromName} → {toName}
      </button>

      {confirmOpen && (
        <div className="modal-backdrop" onClick={() => setConfirmOpen(false)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <h2>Confirm failover</h2>
            <p>
              Failover from <strong>{fromName}</strong> to <strong>{toName}</strong> — this will
              promote the {toName} replica to primary. Writes will be redirected after the
              promotion completes.
            </p>
            <p style={{ color: '#f59e0b' }}>
              Auto-confirm available in {countdown}s.
            </p>
            <div className="modal-actions">
              <button className="cancel" onClick={() => setConfirmOpen(false)}>
                Cancel
              </button>
              <button className="confirm" onClick={triggerFailover}>
                Failover now
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
