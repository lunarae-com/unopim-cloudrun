#!/usr/bin/env bash
set -e

source ./env.sh

echo "Enabling APIs..."
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com sqladmin.googleapis.com secretmanager.googleapis.com

echo "Creating Artifact Registry..."
gcloud artifacts repositories create "$AR_REPO" --repository-format=docker --location="$REGION" 2>/dev/null || true

echo "Creating Cloud SQL (Postgres 18)..."
gcloud sql instances create "$SQL_INSTANCE_NAME" --database-version=POSTGRES_18 --region="$REGION" --cpu=2 --memory=8GB --storage-type=SSD --storage-size=50 2>/dev/null || true
gcloud sql databases create "$DB_NAME" --instance="$SQL_INSTANCE_NAME" 2>/dev/null || true

echo "Generating DB password..."
export DB_PASS="$(openssl rand -base64 32)"

gcloud sql users create "$DB_USER" --instance="$SQL_INSTANCE_NAME" --password="$DB_PASS" 2>/dev/null || gcloud sql users set-password "$DB_USER" --instance="$SQL_INSTANCE_NAME" --password="$DB_PASS"

printf %s "$DB_PASS" | gcloud secrets create unopim-db-password --data-file=- 2>/dev/null || printf %s "$DB_PASS" | gcloud secrets versions add unopim-db-password --data-file=-

echo "Creating APP_KEY..."
export APP_KEY="base64:$(openssl rand -base64 32)"
printf %s "$APP_KEY" | gcloud secrets create unopim-app-key --data-file=- 2>/dev/null || printf %s "$APP_KEY" | gcloud secrets versions add unopim-app-key --data-file=-

echo "Creating GCS bucket..."
gsutil mb -l "$REGION" -b on "gs://$BUCKET" 2>/dev/null || true

echo "Creating Cloud Run service account..."
gcloud iam service-accounts create unopim-run-sa 2>/dev/null || true

gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$RUN_SA" --role="roles/cloudsql.client" >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$RUN_SA" --role="roles/secretmanager.secretAccessor" >/dev/null

gsutil iam ch "serviceAccount:$RUN_SA:objectAdmin" "gs://$BUCKET"

echo "Setup complete."
