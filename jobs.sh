#!/usr/bin/env bash
set -e

source ./env.sh

echo "Running migrations..."
gcloud run jobs create unopim-migrate --image "$IMAGE_URI" --region "$REGION" --service-account "$RUN_SA" --add-cloudsql-instances "$CLOUDSQL_INSTANCE" --command php --args artisan,migrate,--force --set-env-vars "APP_ENV=production,DB_CONNECTION=pgsql,DB_HOST=/cloudsql/$CLOUDSQL_INSTANCE,DB_PORT=5432,DB_DATABASE=$DB_NAME,DB_USERNAME=$DB_USER" --set-secrets "DB_PASSWORD=unopim-db-password:latest,APP_KEY=unopim-app-key:latest" 2>/dev/null || true

gcloud run jobs execute unopim-migrate --region "$REGION"

echo "Installing DAM + Shopify..."
gcloud run jobs create unopim-install-packages --image "$IMAGE_URI" --region "$REGION" --service-account "$RUN_SA" --add-cloudsql-instances "$CLOUDSQL_INSTANCE" --command bash --args -lc,"php artisan dam-package:install && php artisan shopify-package:install && php artisan optimize:clear" --set-secrets "DB_PASSWORD=unopim-db-password:latest,APP_KEY=unopim-app-key:latest" 2>/dev/null || true

gcloud run jobs execute unopim-install-packages --region "$REGION"

echo "Jobs complete."
