# Monitoring (optional / advanced)

Run `bash monitoring/deploy.sh` with the same topology environment used for
`infra/multi-cloud/deploy.sh`. It installs the pinned Prometheus/Grafana chart on
every enabled member, including the second regional AKS cluster, and loads the
failover dashboard and CNPG PodMonitor. The launcher discovers each member's
Grafana service; it never identifies two Azure members as one provider.

`queries.yaml` configures the bundled CNPG chart's default monitoring queries
during operator installation. Dashboard expressions use their `cnpg_`-prefixed
names. `pg_target` identifies the **local** instance role (a regional standby
leader also has local role `primary`); `cnpg_pg_wal_position_in_recovery` identifies
the actual global PostgreSQL role. The native exporter does not require the old
standalone `pg-exporter` credentials or unresolved host placeholders.

The files `manifests/pg-exporter.yaml` and
`manifests/cnpg-techorama-queries.yaml` are historical preview alternatives, not
part of the GA deploy script. Do not apply every manifest in this directory
indiscriminately. The demo values expose Grafana with anonymous viewing; restrict
access before using non-demo data.

- `prometheus-alerts.yaml`: sample alert rules

## Prometheus examples

Example query (average latency):

```promql
rate(documentdb_query_duration_seconds_sum[5m])
/ rate(documentdb_query_duration_seconds_count[5m])
```

Metrics names and availability depend on the runtime/deployment mode.
Use these as a template and align them to the metrics you expose in your environment.
