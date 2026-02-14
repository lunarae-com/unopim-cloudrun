#!/usr/bin/env bash
set -euo pipefail

# Load env vars
source ./env.sh

echo "======================================="
echo "Starting UnoPim infrastructure setup..."
echo "PROJECT_ID=$PROJECT_ID"
echo "REGION=$REGION"
echo "======================================="

# Enable APIs
echo "Enabling required APIs..."
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  sqladmin.googleapis.com \
  secretmanager.googleapis.com

# Create Artifact Registry
echo "Ensuring Artifact Registry repo exists..."
gcloud artifacts repositories create "$AR_REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --description="UnoPim images" 2>/dev/null || true

# Create Cloud SQL instance
echo "Creating Cloud SQL instance (if not exists)..."
gcloud sql instances create "$SQL_INSTANCE_NAME" \
  --database-version=POSTGRES_18 \
  --region="$REGION" \
  --cpu=2 --memory=8GB \
  --storage-type=SSD --storage-size=50 2>/dev/null || true

# Wait for SQL instance to be RUNNABLE
echo "Waiting for Cloud SQL instance to be RUNNABLE..."
STATE=""
for i in $(seq 1 60); do
  STATE="$(gcloud sql instances describe "$SQL_INSTANCE_NAME" \
    --format="value(state)" 2>/dev/null || true)"
  echo "  state=$STATE"
  if [ "$STATE" = "RUNNABLE" ]; then
    break
  fi
  sleep 10
done

if [ "$STATE" != "RUNNABLE" ]; then
  echo "ERROR: Cloud SQL instance '$SQL_INSTANCE_NAME' is not RUNNABLE."
  exit 1
fi

echo "Cloud SQL is RUNNABLE."

# Create database
echo "Ensuring database exists..."
gcloud sql databases create "$DB_NAME" \
  --instance="$SQL_INSTANCE_NAME" 2>/dev/null || true

# Generate DB password
echo "Generating DB password..."
DB_PASS="$(openssl rand -base64 32)"

# Create or update DB user
echo "Ensuring DB user exists..."
gcloud sql users create "$DB_USER" \
  --instance="$SQL_INSTANCE_NAME" \
  --password="$DB_PASS" 2>/dev/null || \
gcloud sql users set-password "$DB_USER" \
  --instance="$SQL_INSTANCE_NAME" \
  --password="$DB_PASS"

# Store DB password in Secret Manager
echo "Storing DB password in Secret Manager..."
printf %s "$DB_PASS" | \
gcloud secrets create unopim-db-password --data-file=- 2>/dev/null || \
printf %s "$DB_PASS" | \
gcloud secrets versions add unopim-db-password --data-file=-

# Create APP_KEY
echo "Generating APP_KEY..."
APP_KEY="base64:$(openssl rand -base64 32)"

printf %s "$APP_KEY" | \
gcloud secrets create unopim-app-key --data-file=- 2>/dev/null || \
printf %s "$APP_KEY" | \
gcloud secrets versions add unopim-app-key --data-file=-

# Create GCS bucket
echo "Ensuring GCS bucket exists..."
gsutil mb -l "$REGION" -b on "gs://$BUCKET" 2>/dev/null || true

# Create runtime service account
echo "Ensuring runtime service account exists..."
gcloud iam service-accounts create unopim-run-sa \
  --display-name "UnoPim Cloud Run runtime" 2>/dev/null || true

# Grant IAM permissions to runtime SA
echo "Granting IAM permissions..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$RUN_SA" \
  --role="roles/cloudsql.client" \
  --condition=None

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$RUN_SA" \
  --role="roles/secretmanager.secretAccessor" \
  --condition=None

gsutil iam ch "serviceAccount:$RUN_SA:objectAdmin" "gs://$BUCKET"

echo "======================================="
echo "Infrastructure setup complete!"
echo "======================================="
