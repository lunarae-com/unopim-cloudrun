#!/usr/bin/env bash
set -e

source ./env.sh

echo "Building container with Cloud Build..."
gcloud builds submit --tag "$IMAGE_URI"

echo "Deploying WEB service..."
gcloud run deploy unopim-web --image "$IMAGE_URI" --region "$REGION" --service-account "$RUN_SA" --allow-unauthenticated --port 8080 --add-cloudsql-instances "$CLOUDSQL_INSTANCE" --set-env-vars "APP_ENV=production,APP_DEBUG=false,DB_CONNECTION=pgsql,DB_HOST=/cloudsql/$CLOUDSQL_INSTANCE,DB_PORT=5432,DB_DATABASE=$DB_NAME,DB_USERNAME=$DB_USER,GCS_BUCKET=$BUCKET" --set-secrets "DB_PASSWORD=unopim-db-password:latest,APP_KEY=unopim-app-key:latest"

echo "Deploying WORKER service..."
gcloud run deploy unopim-worker --image "$IMAGE_URI" --region "$REGION" --service-account "$RUN_SA" --no-allow-unauthenticated --min-instances 1 --add-cloudsql-instances "$CLOUDSQL_INSTANCE" --command php --args artisan,queue:work,--sleep=3,--tries=3,--timeout=120 --set-env-vars "APP_ENV=production,APP_DEBUG=false,DB_CONNECTION=pgsql,DB_HOST=/cloudsql/$CLOUDSQL_INSTANCE,DB_PORT=5432,DB_DATABASE=$DB_NAME,DB_USERNAME=$DB_USER,GCS_BUCKET=$BUCKET" --set-secrets "DB_PASSWORD=unopim-db-password:latest,APP_KEY=unopim-app-key:latest"

echo "Deployment complete."
