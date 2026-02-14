#!/usr/bin/env bash
set -euo pipefail

# Load environment variables
source ./env.sh

# ---- sanity checks ----
if [[ -z "${PROJECT_ID:-}" || "${PROJECT_ID}" == "YOUR_PROJECT_ID" ]]; then
  echo "ERROR: PROJECT_ID is not set. Edit env.sh and set PROJECT_ID, then: source env.sh"
  exit 1
fi

if [[ -z "${REGION:-}" ]]; then
  echo "ERROR: REGION is not set in env.sh"
  exit 1
fi

if [[ -z "${AR_REPO:-}" || -z "${IMAGE_URI:-}" ]]; then
  echo "ERROR: AR_REPO / IMAGE_URI not set in env.sh"
  exit 1
fi

if [[ -z "${CLOUDSQL_INSTANCE:-}" ]]; then
  echo "ERROR: CLOUDSQL_INSTANCE not set in env.sh"
  exit 1
fi

echo "Deploying with:"
echo "  PROJECT_ID=${PROJECT_ID}"
echo "  REGION=${REGION}"
echo "  IMAGE_URI=${IMAGE_URI}"
echo "  CLOUDSQL_INSTANCE=${CLOUDSQL_INSTANCE}"
echo "  BUCKET=${BUCKET:-}"
echo ""

# Ensure we are targeting the right project
gcloud config set project "${PROJECT_ID}" >/dev/null

# ---- build image ----
echo "Building container with Cloud Build..."
gcloud builds submit --tag "${IMAGE_URI}"

# ---- deploy web ----
echo "Deploying Cloud Run service: unopim-web"
gcloud run deploy unopim-web \
  --image "${IMAGE_URI}" \
  --region "${REGION}" \
  --platform managed \
  --service-account "${RUN_SA}" \
  --allow-unauthenticated \
  --port 8080 \
  --add-cloudsql-instances "${CLOUDSQL_INSTANCE}" \
  --set-secrets "DB_PASSWORD=unopim-db-password:latest,APP_KEY=unopim-app-key:latest" \
  --set-env-vars "APP_ENV=production,APP_DEBUG=false,LOG_CHANNEL=stderr,LOG_LEVEL=info" \
  --set-env-vars "DB_CONNECTION=pgsql,DB_HOST=/cloudsql/${CLOUDSQL_INSTANCE},DB_PORT=5432,DB_DATABASE=${DB_NAME},DB_USERNAME=${DB_USER}" \
  ${BUCKET:+--set-env-vars "GCS_BUCKET=${BUCKET}"}

# ---- deploy worker ----
echo "Creating/Updating Cloud Run Job: unopim-worker"

gcloud run jobs delete unopim-worker --region "${REGION}" --quiet 2>/dev/null || true

gcloud run jobs create unopim-worker \
  --image "${IMAGE_URI}" \
  --region "${REGION}" \
  --service-account "${RUN_SA}" \
  --add-cloudsql-instances "${CLOUDSQL_INSTANCE}" \
  --set-secrets "DB_PASSWORD=unopim-db-password:latest,APP_KEY=unopim-app-key:latest" \
  --set-env-vars "APP_ENV=production,APP_DEBUG=false,LOG_CHANNEL=stderr,LOG_LEVEL=info" \
  --set-env-vars "DB_CONNECTION=pgsql,DB_HOST=/cloudsql/${CLOUDSQL_INSTANCE},DB_PORT=5432,DB_DATABASE=${DB_NAME},DB_USERNAME=${DB_USER}" \
  --command php \
  --args artisan,queue:work,--sleep=3,--tries=3,--timeout=120


echo ""
WEB_URL="$(gcloud run services describe unopim-web --region "${REGION}" --format='value(status.url)')"
echo "Done."
echo "unopim-web URL: ${WEB_URL}"
