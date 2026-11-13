#!/usr/bin/env bash
set -euo pipefail

# Phase 1: Setup Public Ingestion Architecture with PostgreSQL Analytics DB
RESOURCE_GROUP="${1:-rg-data-ingestion}"
LOCATION="${2:-eastus}"
STORAGE_ACCOUNT="${3:-stdataingest$RANDOM}"
CONTAINER_NAME="${4:-raw-landing}"
QUEUE_NAME="${5:-file-ingestion-queue}"
SUBSCRIPTION_NAME="${6:-sub-blob-to-queue}"
POSTGRES_SERVER="${7:-pg-analytics-$RANDOM}"
POSTGRES_USER="${8:-pgadmin}"
POSTGRES_PASSWORD="${9:-SecurePassword123!}"

echo "=== Phase 1: Setting up Event-Driven Storage Ingestion into PostgreSQL (Public Mode) ==="

# 1. Create Resource Group
echo "Creating Resource Group '$RESOURCE_GROUP'..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

# 2. Create Storage Account (Public Access Enabled initially)
echo "Creating Storage Account '$STORAGE_ACCOUNT'..."
az storage account create \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --allow-blob-public-access false \
    --public-network-access Enabled

STORAGE_ID=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query id --output tsv)

# 3. Create Blob Container
echo "Creating Blob Container '$CONTAINER_NAME'..."
az storage container create \
    --name "$CONTAINER_NAME" \
    --account-name "$STORAGE_ACCOUNT" \
    --auth-mode login

# 4. Create Storage Queue
echo "Creating Storage Queue '$QUEUE_NAME'..."
az storage queue create \
    --name "$QUEUE_NAME" \
    --account-name "$STORAGE_ACCOUNT" \
    --auth-mode login

# 5. Create Event Grid Subscription routing to the Storage Queue
echo "Creating Event Grid Subscription..."
az eventgrid event-subscription create \
    --name "$SUBSCRIPTION_NAME" \
    --source-resource-id "$STORAGE_ID" \
    --endpoint-type storagequeue \
    --endpoint "$STORAGE_ID/services/queues/$QUEUE_NAME" \
    --included-event-types Microsoft.Storage.BlobCreated \
    --subject-begins-with "/blobServices/default/containers/$CONTAINER_NAME/blobs/"

# 6. Create Azure Database for PostgreSQL Flexible Server (Burstable tier for cost efficiency)
echo "Creating Azure Database for PostgreSQL Flexible Server '$POSTGRES_SERVER'..."
az postgres flexible-server create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$POSTGRES_SERVER" \
    --location "$LOCATION" \
    --admin-user "$POSTGRES_USER" \
    --admin-password "$POSTGRES_PASSWORD" \
    --sku-name Standard_B1ms \
    --tier Burstable \
    --storage-size 32 \
    --public-access "0.0.0.0" \
    --yes

# 7. Create Analytics Database inside PostgreSQL
echo "Creating database 'analyticsdb' in PostgreSQL..."
az postgres flexible-server db create \
    --resource-group "$RESOURCE_GROUP" \
    --server-name "$POSTGRES_SERVER" \
    --database-name "analyticsdb"

echo "=== Phase 1 Setup Complete! ==="
echo "Storage Account: $STORAGE_ACCOUNT"
echo "Container:       $CONTAINER_NAME"
echo "Queue:           $QUEUE_NAME"
echo "PostgreSQL Host: $POSTGRES_SERVER.postgres.database.azure.com"
echo "Database Name:   analyticsdb"
