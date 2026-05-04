import { WebSocketServer, WebSocket } from 'ws';
import type { Server } from 'node:http';
import type { Logger } from 'pino';
import type { StateStore } from './state.js';
import type { WsMessage } from './types.js';

export class Broadcaster {
  private wss: WebSocketServer;

  constructor(server: Server, private store: StateStore, private log: Logger) {
    this.wss = new WebSocketServer({ server, path: '/ws' });
    this.wss.on('connection', (ws) => {
      this.send(ws, { type: 'state', state: this.store.state });
      ws.on('error', (err) => this.log.debug({ err: err.message }, 'ws error'));
    });
    store.onEvent((event) => this.broadcast({ type: 'event', event }));
    setInterval(() => this.broadcast({ type: 'state', state: this.store.state }), 1000);
  }

  broadcast(msg: WsMessage) {
    const data = JSON.stringify(msg);
    for (const client of this.wss.clients) {
      if (client.readyState === WebSocket.OPEN) {
        client.send(data);
      }
    }
  }

  broadcastLog(line: string) {
    this.broadcast({ type: 'failover-log', line });
  }

  private send(ws: WebSocket, msg: WsMessage) {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
  }
}
