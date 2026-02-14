#!/usr/bin/env bash

# ===== CORE PROJECT SETTINGS =====
export PROJECT_ID="YOUR_PROJECT_ID"
export REGION="us-central1"

# ===== ARTIFACT REGISTRY =====
export AR_REPO="unopim"
export IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/unopim:latest"

# ===== CLOUD SQL =====
export SQL_INSTANCE_NAME="unopim-pg"
export CLOUDSQL_INSTANCE="${PROJECT_ID}:${REGION}:${SQL_INSTANCE_NAME}"
export DB_NAME="unopim"
export DB_USER="unopim"

# ===== STORAGE =====
export BUCKET="${PROJECT_ID}-unopim-assets"

# ===== CLOUD RUN SERVICE ACCOUNT =====
export RUN_SA="unopim-run-sa@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Environment loaded."
echo "PROJECT_ID=$PROJECT_ID"
echo "REGION=$REGION"
echo "IMAGE_URI=$IMAGE_URI"
echo "CLOUDSQL_INSTANCE=$CLOUDSQL_INSTANCE"
echo "BUCKET=$BUCKET"
