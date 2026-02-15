# ---------- PHP + Composer build stage ----------
FROM php:8.2-cli-alpine AS vendor

RUN apk add --no-cache \
    bash git unzip curl \
    icu-dev libzip-dev oniguruma-dev \
    postgresql-dev mariadb-dev \
    freetype-dev libjpeg-turbo-dev libpng-dev libwebp-dev \
  && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
  && docker-php-ext-install \
    intl calendar \
    pdo pdo_mysql pdo_pgsql \
    zip gd

RUN curl -sS https://getcomposer.org/installer | php -- \
  --install-dir=/usr/local/bin --filename=composer

WORKDIR /app

RUN composer create-project unopim/unopim . --no-interaction \
  && composer require unopim/shopify-connector unopim/dam --no-interaction \
  && composer install --no-dev --optimize-autoloader


# ---------- Node/Vite build stage ----------
FROM node:20-alpine AS assets
WORKDIR /app
COPY --from=vendor /app /app

RUN set -eux; \
  # Build root assets (if exist)
  if [ -f /app/package.json ]; then \
    cd /app; \
    if [ -f package-lock.json ]; then npm ci; else npm install; fi; \
    npm run build || true; \
  fi; \
  \
  # Build installer theme
  if [ -f /app/public/themes/installer/default/package.json ]; then \
    cd /app/public/themes/installer/default; \
    if [ -f package-lock.json ]; then npm ci; else npm install; fi; \
    npm run build; \
  fi; \
  \
  # Build admin theme
  if [ -f /app/public/themes/admin/default/package.json ]; then \
    cd /app/public/themes/admin/default; \
    if [ -f package-lock.json ]; then npm ci; else npm install; fi; \
    npm run build; \
  fi


# ---------- Runtime stage ----------
FROM php:8.2-fpm-alpine

RUN apk add --no-cache \
    nginx supervisor bash busybox-extras \
    icu-dev libzip-dev oniguruma-dev \
    postgresql-dev mariadb-dev \
    freetype-dev libjpeg-turbo-dev libpng-dev libwebp-dev \
  && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
  && docker-php-ext-install \
    pdo pdo_pgsql pdo_mysql \
    intl gd zip opcache calendar \
  \
  # ✅ Make php-fpm listen on TCP 127.0.0.1:9000 (matches nginx fastcgi_pass 127.0.0.1:9000)
  && sed -i 's|^listen = .*|listen = 127.0.0.1:9000|' /usr/local/etc/php-fpm.d/www.conf \
  \
  # ✅ Ensure Cloud Run env vars are available to PHP
  && sed -i 's|^;clear_env = no|clear_env = no|' /usr/local/etc/php-fpm.d/www.conf

WORKDIR /var/www/html

# Copy FULL built app (including built theme assets)
COPY --from=assets /app /var/www/html

# Your configs
COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/supervisord.conf /etc/supervisord.conf

RUN chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache

ENV APP_ENV=production
ENV APP_DEBUG=false
ENV TRUSTED_PROXIES="*"

EXPOSE 8080
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
