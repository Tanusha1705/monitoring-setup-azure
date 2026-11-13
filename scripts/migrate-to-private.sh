#!/usr/bin/env bash
set -euo pipefail

# Phase 2: Migrate Storage & Function Ingestion to Private Architecture
RESOURCE_GROUP="${1:-rg-data-ingestion}"
LOCATION="${2:-eastus}"
STORAGE_ACCOUNT="${3:-stdataingest1234}"
VNET_NAME="${4:-vnet-ingestion}"
FUNCTION_SUBNET="${5:-snet-function}"
ENDPOINT_SUBNET="${6:-snet-private-endpoints}"

echo "=== Phase 2: Transitioning Storage Account to Private Endpoints & VNet ==="

# 1. Create Virtual Network
echo "Creating Virtual Network '$VNET_NAME'..."
az network vnet create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VNET_NAME" \
    --address-prefix 10.0.0.0/16 \
    --subnet-name "$ENDPOINT_SUBNET" \
    --subnet-prefix 10.0.1.0/24

# 2. Create Subnet dedicated for Function App VNet Integration
echo "Creating Function Subnet '$FUNCTION_SUBNET'..."
az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$FUNCTION_SUBNET" \
    --address-prefixes 10.0.2.0/24 \
    --delegations Microsoft.App/environments Microsoft.Web/serverFarms

# 3. Disable private endpoint network policies on endpoint subnet
az network vnet subnet update \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$ENDPOINT_SUBNET" \
    --disable-private-endpoint-network-policies true

STORAGE_ID=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query id --output tsv)

# 4. Create Private Endpoint for Blob Service
echo "Creating Private Endpoint for Blob storage..."
az network private-endpoint create \
    --name "pe-$STORAGE_ACCOUNT-blob" \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --subnet "$ENDPOINT_SUBNET" \
    --private-connection-resource-id "$STORAGE_ID" \
    --group-id blob \
    --connection-name "conn-blob"

# 5. Create Private Endpoint for Queue Service
echo "Creating Private Endpoint for Queue storage..."
az network private-endpoint create \
    --name "pe-$STORAGE_ACCOUNT-queue" \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --subnet "$ENDPOINT_SUBNET" \
    --private-connection-resource-id "$STORAGE_ID" \
    --group-id queue \
    --connection-name "conn-queue"

# 6. Configure Private DNS Zones for Blob and Queue
echo "Configuring Private DNS Zones..."
az network private-dns zone create --resource-group "$RESOURCE_GROUP" --name "privatelink.blob.core.windows.net"
az network private-dns zone create --resource-group "$RESOURCE_GROUP" --name "privatelink.queue.core.windows.net"

az network private-dns link vnet create \
    --resource-group "$RESOURCE_GROUP" \
    --zone-name "privatelink.blob.core.windows.net" \
    --name "link-blob-$VNET_NAME" \
    --virtual-network "$VNET_NAME" \
    --registration-enabled false

az network private-dns link vnet create \
    --resource-group "$RESOURCE_GROUP" \
    --zone-name "privatelink.queue.core.windows.net" \
    --name "link-queue-$VNET_NAME" \
    --virtual-network "$VNET_NAME" \
    --registration-enabled false

# 7. Disable Public Network Access on Storage Account
echo "Locking down Storage Account: Disabling Public Network Access..."
az storage account update \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --public-network-access Disabled

echo "Private Transition Complete! All traffic is now isolated inside $VNET_NAME."
