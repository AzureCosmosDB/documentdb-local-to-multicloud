#!/usr/bin/env bash
# Shared topology for provisioning, placement, monitoring, and cleanup.
RESOURCE_GROUP="${RESOURCE_GROUP:-docdb-multicloud-rg}"
RG_LOCATION="${RG_LOCATION:-eastus2}"
HUB_REGION="${HUB_REGION:-$RG_LOCATION}"
HUB_CONTEXT="${HUB_CONTEXT:-hub}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-azure-documentdb}"
AKS_REGION="${AKS_REGION:-eastus2}"
INCLUDE_AKS_REPLICA="${INCLUDE_AKS_REPLICA:-false}"
AKS_REPLICA_NAME="${AKS_REPLICA_NAME:-azure-documentdb-secondary}"
AKS_REPLICA_REGION="${AKS_REPLICA_REGION:-}"
INCLUDE_EKS="${INCLUDE_EKS:-true}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-aws-documentdb}"
EKS_REGION="${EKS_REGION:-us-west-2}"
INCLUDE_GKE="${INCLUDE_GKE:-false}"
GKE_CLUSTER_NAME="${GKE_CLUSTER_NAME:-gcp-documentdb}"

for flag in INCLUDE_AKS_REPLICA INCLUDE_EKS INCLUDE_GKE; do
  case "${!flag}" in true|false) ;; *) echo "ERROR: $flag must be true or false" >&2; return 1 ;; esac
done
MEMBER_CLUSTER_NAMES=("$AKS_CLUSTER_NAME")
AKS_MEMBER_NAMES=("$AKS_CLUSTER_NAME")
MEMBER_ENVIRONMENTS=(aks)
if [ "$INCLUDE_AKS_REPLICA" = true ]; then
  if [ -z "$AKS_REPLICA_REGION" ] || [ "$AKS_REPLICA_REGION" = "$AKS_REGION" ]; then
    echo "ERROR: AKS_REPLICA_REGION must name a different Azure region from AKS_REGION." >&2
    return 1
  fi
  MEMBER_CLUSTER_NAMES+=("$AKS_REPLICA_NAME")
  AKS_MEMBER_NAMES+=("$AKS_REPLICA_NAME")
  MEMBER_ENVIRONMENTS+=(aks)
fi
if [ "$INCLUDE_EKS" = true ]; then
  MEMBER_CLUSTER_NAMES+=("$EKS_CLUSTER_NAME")
  MEMBER_ENVIRONMENTS+=(eks)
fi
if [ "$INCLUDE_GKE" = true ]; then
  MEMBER_CLUSTER_NAMES+=("$GKE_CLUSTER_NAME")
  MEMBER_ENVIRONMENTS+=(gke)
fi
if [ "${#MEMBER_CLUSTER_NAMES[@]}" -lt 2 ]; then
  echo "ERROR: enable at least one replica (AKS, EKS, or GKE)." >&2
  return 1
fi
seen=" "
for member in "${MEMBER_CLUSTER_NAMES[@]}"; do
  if [[ ! "$member" =~ ^[a-z][a-z0-9-]{0,62}$ ]] || [[ "$seen" == *" $member "* ]] || [ "$member" = "$HUB_CONTEXT" ]; then
    echo "ERROR: member names must be distinct DNS labels, separate from the hub: $member" >&2
    return 1
  fi
  seen+="$member "
done
PRIMARY_CLUSTER="${PRIMARY_CLUSTER:-$AKS_CLUSTER_NAME}"
if [[ "$seen" != *" $PRIMARY_CLUSTER "* ]]; then
  echo "ERROR: PRIMARY_CLUSTER must be an enabled member." >&2
  return 1
fi
