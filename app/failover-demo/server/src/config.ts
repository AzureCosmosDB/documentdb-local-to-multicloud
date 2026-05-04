import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import 'dotenv/config';

export type ClusterId = 'aks' | 'eks';

export interface ClusterConfig {
  id: ClusterId;
  name: string;
  region: string;
  uri: string;
  kubeContext: string;
  namespace: string;
  documentdbResource: string;
}

export interface AppConfig {
  port: number;
  clusters: Record<ClusterId, ClusterConfig>;
  hubContext: string;
  initialPrimary: ClusterId;
  demoDb: string;
  demoCollection: string;
  logLevel: string;
}

interface RawClustersFile {
  aks: Omit<ClusterConfig, 'id'>;
  eks: Omit<ClusterConfig, 'id'>;
  hubContext?: string;
  initialPrimary?: ClusterId;
}

function loadClustersFile(path: string): RawClustersFile | null {
  if (!existsSync(path)) return null;
  const raw = readFileSync(path, 'utf8');
  return JSON.parse(raw) as RawClustersFile;
}

export function loadConfig(): AppConfig {
  const cwd = process.cwd();
  const configPath = resolve(cwd, process.env.CLUSTERS_CONFIG ?? './clusters.json');
  const file = loadClustersFile(configPath);

  const merge = (id: ClusterId, defaults: Partial<ClusterConfig>): ClusterConfig => {
    const base = file?.[id] ?? ({} as Partial<ClusterConfig>);
    const envUri = id === 'aks' ? process.env.AKS_URI : process.env.EKS_URI;
    const envCtx = id === 'aks' ? process.env.AKS_KUBE_CONTEXT : process.env.EKS_KUBE_CONTEXT;
    return {
      id,
      name: base.name ?? defaults.name ?? id.toUpperCase(),
      region: base.region ?? defaults.region ?? 'unknown',
      uri: envUri ?? base.uri ?? defaults.uri ?? '',
      kubeContext: envCtx ?? base.kubeContext ?? defaults.kubeContext ?? '',
      namespace: process.env.DOCUMENTDB_NAMESPACE ?? base.namespace ?? 'documentdb-preview-ns',
      documentdbResource:
        process.env.DOCUMENTDB_RESOURCE ?? base.documentdbResource ?? 'documentdb-preview',
    };
  };

  const aks = merge('aks', { name: 'AKS', region: 'eastus2', kubeContext: 'azure-documentdb' });
  const eks = merge('eks', { name: 'EKS', region: 'us-west-2', kubeContext: 'aws-documentdb' });

  if (!aks.uri || !eks.uri) {
    throw new Error(
      `Missing cluster URI. Provide ${configPath} (copy clusters.example.json) or set AKS_URI / EKS_URI env vars.`,
    );
  }

  return {
    port: Number(process.env.PORT ?? 4000),
    clusters: { aks, eks },
    hubContext: process.env.HUB_KUBE_CONTEXT ?? file?.hubContext ?? 'hub',
    initialPrimary:
      (process.env.INITIAL_PRIMARY as ClusterId | undefined) ?? file?.initialPrimary ?? 'aks',
    demoDb: process.env.DEMO_DB ?? 'demodb',
    demoCollection: process.env.DEMO_COLLECTION ?? 'failover_demo_events',
    logLevel: process.env.LOG_LEVEL ?? 'info',
  };
}
