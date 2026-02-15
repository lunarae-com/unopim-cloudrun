#!/usr/bin/env bash
set -euo pipefail

# Load environment variables
source ./env.sh

SERVICE_NAME="${SERVICE_NAME:-unopim-web}"
JOB_NAME="${JOB_NAME:-unopim-worker}"

# ---- sanity checks ----
if [[ -z "${PROJECT_ID:-}" || "${PROJECT_ID}" == "YOUR_PROJECT_ID" ]]; then
  echo "ERROR: PROJECT_ID is not set. Edit env.sh and set PROJECT_ID, then: source env.sh"
  exit 1
fi

if [[ -z "${REGION:-}" ]]; then
  echo "ERROR: REGION is not set in env.sh"
  exit 1
fi

# Ensure we are targeting the right project
gcloud config set project "${PROJECT_ID}" >/dev/null

# ---- auto-discover from existing service if not provided ----
if [[ -z "${IMAGE_URI:-}" ]]; then
  IMAGE_URI="$(gcloud run services describe "${SERVICE_NAME}" \
    --region "${REGION}" \
    --format="value(spec.template.spec.containers[0].image)" 2>/dev/null || true)"
fi

if [[ -z "${RUN_SA:-}" ]]; then
  RUN_SA="$(gcloud run services describe "${SERVICE_NAME}" \
    --region "${REGION}" \
    --format="value(spec.template.spec.serviceAccountName)" 2>/dev/null || true)"
fi

if [[ -z "${CLOUDSQL_INSTANCE:-}" ]]; then
  CLOUDSQL_INSTANCE="$(gcloud run services describe "${SERVICE_NAME}" \
    --region "${REGION}" \
    --format="value(spec.template.metadata.annotations.'run.googleapis.com/cloudsql-instances')" 2>/dev/null || true)"
fi

# Validate required vars after discovery
if [[ -z "${IMAGE_URI:-}" ]]; then
  echo "ERROR: IMAGE_URI is not set and could not be discovered from ${SERVICE_NAME}."
  echo "Set IMAGE_URI in env.sh (example: us-central1-docker.pkg.dev/<PROJECT>/<REPO>/<IMAGE>:latest)"
  exit 1
fi

if [[ -z "${RUN_SA:-}" ]]; then
  echo "ERROR: RUN_SA is not set and could not be discovered from ${SERVICE_NAME}."
  echo "Set RUN_SA in env.sh (example: something@${PROJECT_ID}.iam.gserviceaccount.com)"
  exit 1
fi

if [[ -z "${CLOUDSQL_INSTANCE:-}" ]]; then
  echo "ERROR: CLOUDSQL_INSTANCE is not set and could not be discovered from ${SERVICE_NAME}."
  echo "Set CLOUDSQL_INSTANCE in env.sh (example: ${PROJECT_ID}:${REGION}:unopim-pg)"
  exit 1
fi

# DB sanity checks (these are used for app env vars)
if [[ -z "${DB_NAME:-}" || -z "${DB_USER:-}" ]]; then
  echo "ERROR: DB_NAME / DB_USER not set in env.sh"
  exit 1
fi

echo "Deploying with:"
echo "  PROJECT_ID=${PROJECT_ID}"
echo "  REGION=${REGION}"
echo "  SERVICE_NAME=${SERVICE_NAME}"
echo "  IMAGE_URI=${IMAGE_URI}"
echo "  RUN_SA=${RUN_SA}"
echo "  CLOUDSQL_INSTANCE=${CLOUDSQL_INSTANCE}"
echo "  DB_NAME=${DB_NAME}"
echo "  DB_USER=${DB_USER}"
echo "  BUCKET=${BUCKET:-}"
echo ""

# ---- build image (optional toggle) ----
if [[ "${SKIP_BUILD:-false}" != "true" ]]; then
  echo "Building container with Cloud Build..."
  gcloud builds submit --tag "${IMAGE_URI}"
else
  echo "Skipping build (SKIP_BUILD=true)"
fi

# ---- deploy web ----
echo "Deploying Cloud Run service: ${SERVICE_NAME}"
gcloud run deploy "${SERVICE_NAME}" \
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
echo "Creating/Updating Cloud Run Job: ${JOB_NAME}"

gcloud run jobs delete "${JOB_NAME}" --region "${REGION}" --quiet 2>/dev/null || true

gcloud run jobs create "${JOB_NAME}" \
  --image "${IMAGE_URI}" \
  --region "${REGION}" \
  --service-account "${RUN_SA}" \
  --set-cloudsql-instances "${CLOUDSQL_INSTANCE}" \
  --set-secrets "DB_PASSWORD=unopim-db-password:latest,APP_KEY=unopim-app-key:latest" \
  --set-env-vars "APP_ENV=production,APP_DEBUG=false,LOG_CHANNEL=stderr,LOG_LEVEL=info" \
  --set-env-vars "DB_CONNECTION=pgsql,DB_HOST=/cloudsql/${CLOUDSQL_INSTANCE},DB_PORT=5432,DB_DATABASE=${DB_NAME},DB_USERNAME=${DB_USER}" \
  --command php \
  --args artisan,queue:work,--sleep=3,--tries=3,--timeout=120

echo ""
WEB_URL="$(gcloud run services describe "${SERVICE_NAME}" --region "${REGION}" --format='value(status.url)')"
echo "Done."
echo "${SERVICE_NAME} URL: ${WEB_URL}"
