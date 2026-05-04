import { useEffect, useRef, useState } from 'react';
import type { AppState, WsMessage } from '../types';

export function useWsState() {
  const [state, setState] = useState<AppState | null>(null);
  const [connected, setConnected] = useState(false);
  const [failoverLog, setFailoverLog] = useState<string[]>([]);
  const wsRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    let cancelled = false;
    let reconnectTimer: number | null = null;

    const connect = () => {
      const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      const url = `${proto}//${window.location.host}/ws`;
      const ws = new WebSocket(url);
      wsRef.current = ws;
      ws.onopen = () => {
        if (cancelled) return;
        setConnected(true);
      };
      ws.onclose = () => {
        if (cancelled) return;
        setConnected(false);
        reconnectTimer = window.setTimeout(connect, 1500);
      };
      ws.onerror = () => ws.close();
      ws.onmessage = (ev) => {
        try {
          const msg: WsMessage = JSON.parse(ev.data);
          if (msg.type === 'state') setState(msg.state);
          else if (msg.type === 'failover-log') {
            setFailoverLog((prev) => [...prev.slice(-100), msg.line]);
          }
        } catch {
          /* ignore */
        }
      };
    };

    connect();
    return () => {
      cancelled = true;
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      wsRef.current?.close();
    };
  }, []);

  const clearFailoverLog = () => setFailoverLog([]);

  return { state, connected, failoverLog, clearFailoverLog };
}
