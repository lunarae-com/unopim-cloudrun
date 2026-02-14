#!/usr/bin/env bash
set -euo pipefail

# Generates the project skeleton + Docker/nginx/supervisor configs + helper scripts.
# Usage:
#   ./generate-files.sh              # creates $HOME/unopim-cloudrun
#   ./generate-files.sh /path/to/dir # creates the specified directory

ROOT_DIR="${1:-$HOME/unopim-cloudrun}"

mkdir -p "$ROOT_DIR/docker"
cd "$ROOT_DIR"

cat > Dockerfile <<'EOF'
# ---------- PHP + Composer build stage ----------
FROM php:8.2-cli-alpine AS vendor

RUN apk add --no-cache     bash git unzip curl     icu-dev libzip-dev oniguruma-dev     postgresql-dev mariadb-dev     freetype-dev libjpeg-turbo-dev libpng-dev libwebp-dev   && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp   && docker-php-ext-install     intl calendar     pdo pdo_mysql pdo_pgsql     zip gd

RUN curl -sS https://getcomposer.org/installer | php --     --install-dir=/usr/local/bin --filename=composer

WORKDIR /app

RUN composer create-project unopim/unopim . --no-interaction  && composer require unopim/shopify-connector unopim/dam --no-interaction  && composer install --no-dev --optimize-autoloader

# ---------- Node/Vite build stage ----------
FROM node:20-alpine AS assets
WORKDIR /app
COPY --from=vendor /app /app

RUN set -eux;   THEME_DIR="$(find /app -type d -path '*/public/themes/shopify' 2>/dev/null | head -n 1 || true)";   if [ -z "$THEME_DIR" ]; then     echo "ERROR: Could not find public/themes/shopify inside /app";     exit 1;   fi;   cd "$THEME_DIR";   if [ -f package-lock.json ]; then npm ci; else npm install; fi;   npm run build;   test -f build/manifest.json

# ---------- Runtime stage ----------
FROM php:8.2-fpm-alpine

RUN apk add --no-cache nginx supervisor bash     icu-dev libzip-dev oniguruma-dev     postgresql-dev mariadb-dev     freetype-dev libjpeg-turbo-dev libpng-dev libwebp-dev   && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp   && docker-php-ext-install     pdo pdo_pgsql pdo_mysql     intl gd zip opcache calendar

WORKDIR /var/www/html
COPY --from=vendor /app /var/www/html
COPY --from=assets /app/public/themes /var/www/html/public/themes

COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/supervisord.conf /etc/supervisord.conf
COPY docker/php-fpm.conf /usr/local/etc/php-fpm.d/zz-cloudrun.conf

RUN chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache  && mkdir -p /run/php  && chown -R www-data:www-data /run/php

ENV APP_ENV=production
ENV APP_DEBUG=false

EXPOSE 8080
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
EOF

cat > docker/nginx.conf <<'EOF'
worker_processes 1;

events { worker_connections 1024; }

http {
  access_log /dev/stdout;
  error_log /dev/stderr info;

  server {
    listen 8080;
    root /var/www/html/public;
    index index.php;

    location / {
      try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
      include fastcgi_params;
      fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
      fastcgi_pass 127.0.0.1:9000;
    }
  }
}
EOF

cat > docker/supervisord.conf <<'EOF'
[supervisord]
nodaemon=true

[program:php-fpm]
command=php-fpm -F
stdout_logfile=/dev/stdout
stderr_logfile=/dev/stderr

[program:nginx]
command=nginx -g "daemon off;"
stdout_logfile=/dev/stdout
stderr_logfile=/dev/stderr
EOF

cat > docker/php-fpm.conf <<'EOF'
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /dev/stderr
EOF

cat > env.sh <<'EOF'
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
EOF

cat > setup.sh <<'EOF'
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
EOF

cat > deploy.sh <<'EOF'
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
EOF

cat > jobs.sh <<'EOF'
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
EOF

chmod +x env.sh setup.sh deploy.sh jobs.sh generate-files.sh

echo "Generated project in: $ROOT_DIR"
echo ""
echo "Next steps:"
echo "  1) Edit env.sh and set PROJECT_ID"
echo "  2) source env.sh"
echo "  3) ./setup.sh"
echo "  4) ./deploy.sh"
echo "  5) ./jobs.sh"
