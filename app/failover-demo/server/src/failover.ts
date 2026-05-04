import { spawn } from 'node:child_process';
import type { Logger } from 'pino';
import type { AppConfig, ClusterId } from './config.js';
import type { ClusterClients } from './db.js';
import type { StateStore } from './state.js';

const FAILOVER_TIMEOUT_MS = 60_000;
const POLL_INTERVAL_MS = 1000;

export interface FailoverDeps {
  clients: Record<ClusterId, ClusterClients>;
  app: AppConfig;
  store: StateStore;
  log: Logger;
  broadcastLog: (line: string) => void;
}

export async function runFailover(target: ClusterId, deps: FailoverDeps): Promise<void> {
  const { app, store, log, broadcastLog } = deps;
  if (store.state.failover.active) {
    throw new Error('failover already in progress');
  }
  const from = store.state.primary;
  if (from === target) {
    throw new Error(`${target} is already the primary`);
  }
  const targetCfg = app.clusters[target];
  const fromCfg = app.clusters[from];

  store.state.failover = {
    active: true,
    fromCluster: from,
    toCluster: target,
    phase: 'promoting',
    startedAt: Date.now(),
    finishedAt: null,
    message: `Promoting ${targetCfg.name} (${target})…`,
  };
  store.updateCluster(from, { role: 'DEMOTING' });
  store.updateCluster(target, { role: 'PROMOTING' });
  store.pushEvent('failover', `failover initiated: ${fromCfg.name} → ${targetCfg.name}`);

  // Build the kubectl-documentdb plugin command. Confirmed against upstream README:
  //   kubectl documentdb promote --documentdb <name> --namespace <ns>
  //     --hub-context <hub> --target-cluster <ctx> --cluster-context <ctx>
  const args = [
    'documentdb',
    'promote',
    '--documentdb',
    targetCfg.documentdbResource,
    '--namespace',
    targetCfg.namespace,
    '--hub-context',
    app.hubContext,
    '--target-cluster',
    targetCfg.kubeContext,
    '--cluster-context',
    targetCfg.kubeContext,
  ];

  broadcastLog(`$ kubectl ${args.join(' ')}`);
  log.info({ args }, 'spawning kubectl documentdb promote');

  try {
    await runKubectl(args, broadcastLog, log);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    broadcastLog(`! plugin failed: ${msg}`);
    broadcastLog('… falling back to: kubectl patch documentdb');
    const patchArgs = [
      '--context',
      app.hubContext,
      'patch',
      'documentdb',
      targetCfg.documentdbResource,
      '-n',
      targetCfg.namespace,
      '--type',
      'merge',
      '-p',
      JSON.stringify({ spec: { failover: { targetMember: target } } }),
    ];
    broadcastLog(`$ kubectl ${patchArgs.join(' ')}`);
    try {
      await runKubectl(patchArgs, broadcastLog, log);
    } catch (err2) {
      const msg2 = err2 instanceof Error ? err2.message : String(err2);
      store.state.failover = {
        ...store.state.failover,
        active: false,
        phase: 'failed',
        finishedAt: Date.now(),
        message: msg2,
      };
      store.pushEvent('error', `failover failed: ${msg2.slice(0, 100)}`);
      store.emit();
      throw err2;
    }
  }

  store.state.failover.phase = 'reconfiguring';
  store.state.failover.message = 'Waiting for new primary to come online…';
  broadcastLog('… waiting for new primary to come online');
  store.emit();

  const start = Date.now();
  while (Date.now() - start < FAILOVER_TIMEOUT_MS) {
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
    const targetStatus = store.state.clusters[target];
    // Heuristic: target is reachable + we can write. The poller updates reachable;
    // we'll attempt a tiny write probe to confirm primary acceptance.
    if (targetStatus.reachable) {
      try {
        await deps.clients[target]
          .collection()
          .insertOne({ _id: `failover-probe-${Date.now()}`, source: 'failover-probe', ts: new Date() } as any);
        broadcastLog(`✓ probe write succeeded on ${targetCfg.name}`);
        break;
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        broadcastLog(`… probe rejected (${msg.slice(0, 80)}), waiting…`);
      }
    } else {
      broadcastLog(`… ${targetCfg.name} not yet reachable`);
    }
  }

  if (Date.now() - start >= FAILOVER_TIMEOUT_MS) {
    store.state.failover = {
      ...store.state.failover,
      active: false,
      phase: 'failed',
      finishedAt: Date.now(),
      message: 'timed out waiting for new primary',
    };
    store.pushEvent('error', `failover timed out after ${FAILOVER_TIMEOUT_MS / 1000}s`);
    store.emit();
    throw new Error('failover timed out');
  }

  store.state.failover.phase = 'routing';
  store.state.failover.message = 'Routing writes to new primary…';
  broadcastLog('… routing writer to new primary');
  store.setPrimary(target);
  store.emit();

  store.state.failover = {
    active: false,
    fromCluster: from,
    toCluster: target,
    phase: 'complete',
    startedAt: store.state.failover.startedAt,
    finishedAt: Date.now(),
    message: `Promoted ${targetCfg.name}`,
  };
  store.pushEvent('failover', `failover complete: ${targetCfg.name} is PRIMARY`);
  store.emit();
}

function runKubectl(args: string[], onLine: (s: string) => void, log: Logger): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn('kubectl', args, { shell: false });
    let stderrBuf = '';
    const pipe = (stream: NodeJS.ReadableStream, prefix: string) => {
      let buf = '';
      stream.on('data', (chunk: Buffer) => {
        buf += chunk.toString();
        const lines = buf.split(/\r?\n/);
        buf = lines.pop() ?? '';
        for (const line of lines) {
          if (line) onLine(`${prefix} ${line}`);
        }
      });
      stream.on('end', () => {
        if (buf) onLine(`${prefix} ${buf}`);
      });
    };
    pipe(proc.stdout, '·');
    proc.stderr.on('data', (c: Buffer) => {
      stderrBuf += c.toString();
    });
    pipe(proc.stderr, '!');
    proc.on('error', (err) => {
      log.error({ err: err.message }, 'kubectl spawn failed');
      reject(err);
    });
    proc.on('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`kubectl exited ${code}: ${stderrBuf.slice(-200)}`));
    });
  });
}
