import type { DemoEvent } from '../types';

function fmtTs(ts: number) {
  const d = new Date(ts);
  return d.toLocaleTimeString([], { hour12: false }) + '.' + String(d.getMilliseconds()).padStart(3, '0');
}

export function EventLog({ events }: { events: DemoEvent[] }) {
  return (
    <div className="event-log">
      <h3>Event log</h3>
      {events.length === 0 && <div style={{ color: '#8b949e', fontSize: 13 }}>(no events yet)</div>}
      {events.map((e) => (
        <div key={e.id} className="row">
          <span className="ts">{fmtTs(e.ts)}</span>
          <span className={`kind-${e.kind}`}>{e.kind}</span>
          <span>{e.message}</span>
        </div>
      ))}
    </div>
  );
}
