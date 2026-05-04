import type { AutoInsertState } from '../types';

interface Props {
  autoInsert: AutoInsertState;
}

export function ControlBar({ autoInsert }: Props) {
  const setAuto = async (enabled: boolean, rateHz?: number) => {
    await fetch('/api/auto-insert', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ enabled, rateHz: rateHz ?? autoInsert.rateHz }),
    });
  };

  const manualInsert = async () => {
    await fetch('/api/insert', { method: 'POST' });
  };

  return (
    <div className="control-bar">
      <label>
        <input
          type="checkbox"
          checked={autoInsert.enabled}
          onChange={(e) => setAuto(e.target.checked)}
        />
        ▶ Auto-insert
      </label>
      <label>
        Rate: <strong>{autoInsert.rateHz} Hz</strong>
        <input
          type="range"
          min={1}
          max={20}
          value={autoInsert.rateHz}
          onChange={(e) => setAuto(autoInsert.enabled, Number(e.target.value))}
        />
      </label>
      <button className="manual" onClick={manualInsert}>
        + Insert one
      </button>
      {autoInsert.consecutiveFailures > 0 && (
        <span style={{ color: '#ef4444', fontSize: 13 }}>
          {autoInsert.consecutiveFailures} consecutive write failures
        </span>
      )}
    </div>
  );
}
