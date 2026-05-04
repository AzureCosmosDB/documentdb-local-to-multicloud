import { useWsState } from './hooks/useWsState';
import { ClusterPanel } from './components/ClusterPanel';
import { FailoverButton } from './components/FailoverButton';
import { ControlBar } from './components/ControlBar';
import { EventLog } from './components/EventLog';

export default function App() {
  const { state, connected, failoverLog, clearFailoverLog } = useWsState();

  if (!state) {
    return (
      <div className="app">
        <div className="header">
          <h1>DocumentDB Cross-Cloud Failover Demo</h1>
          <span className="sub">
            <span className={`status-dot ${connected ? 'ok' : 'bad'}`}></span>
            {connected ? 'connecting…' : 'disconnected'}
          </span>
        </div>
        <div style={{ padding: 40, textAlign: 'center', color: '#8b949e' }}>Waiting for state…</div>
      </div>
    );
  }

  return (
    <div className="app">
      <div className="header">
        <h1>DocumentDB Cross-Cloud Failover Demo</h1>
        <span className="sub">
          <span className={`status-dot ${connected ? 'ok' : 'bad'}`}></span>
          {connected ? 'live' : 'reconnecting…'} · primary: <strong>{state.clusters[state.primary].name}</strong>
        </span>
      </div>

      <ControlBar autoInsert={state.autoInsert} />

      <FailoverButton state={state} failoverLog={failoverLog} onClearLog={clearFailoverLog} />

      <div className="panels">
        <ClusterPanel
          cluster={state.clusters.aks}
          isPrimary={state.primary === 'aks'}
          replicationLagMs={state.primary === 'aks' ? null : state.replicationLagMs}
        />
        <ClusterPanel
          cluster={state.clusters.eks}
          isPrimary={state.primary === 'eks'}
          replicationLagMs={state.primary === 'eks' ? null : state.replicationLagMs}
        />
      </div>

      <EventLog events={state.events} />
    </div>
  );
}
