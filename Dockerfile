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

# Build Laravel/Vite frontend assets
RUN set -eux; \
  if [ -f /app/package.json ]; then \
    cd /app; \
    if [ -f package-lock.json ]; then npm ci; else npm install; fi; \
    npm run build; \
    test -f /app/public/build/manifest.json; \
  else \
    echo "No package.json found; skipping asset build."; \
  fi

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
