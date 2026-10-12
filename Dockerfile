# syntax=docker/dockerfile:1.7
# Both applications are fetched at build time; no git/npm/composer in the running web service.
FROM node:24-bookworm-slim AS frontend
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ARG CLIENT_REPO=https://github.com/Zefling/classement-client.git
ARG CLIENT_REF=master
ARG UPSTREAM_REFRESH=initial
WORKDIR /build
RUN echo "Upstream refresh: ${UPSTREAM_REFRESH}" \
    && git clone --depth 1 --branch "$CLIENT_REF" "$CLIENT_REPO" client \
    && git -C client rev-parse HEAD > /build/client-revision
WORKDIR /build/client
# apiPath() adds api/<endpoint>; using '/' keeps Angular and Symfony on the same origin.
RUN grep -Fq "path: 'https://api.classement.ikilote.net/'" src/environments/environment.prod.ts \
    && sed -i "s#path: 'https://api.classement.ikilote.net/'#path: '/'#" src/environments/environment.prod.ts \
    && grep -Fq "path: '/'" src/environments/environment.prod.ts
# Upstream postinstall runs 'npm audit fix': don't mutate resolution during image builds.
# Upstream does not commit a package-lock.json, so npm ci is not possible as-is.
RUN --mount=type=cache,target=/root/.npm \
    npm install --ignore-scripts --no-audit --no-fund \
    && node ./node_modules/@angular/cli/bin/ng.js build --configuration production

FROM php:8.4-apache-bookworm AS php-base
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates imagemagick \
        libicu-dev libzip-dev libpng-dev libjpeg62-turbo-dev \
        libfreetype6-dev libwebp-dev libavif-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp --with-avif \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql intl gd zip opcache \
    && pecl install apcu \
    && docker-php-ext-enable apcu \
    && a2enmod rewrite headers setenvif \
    && printf 'ServerName localhost\nServerTokens Prod\nServerSignature Off\n' > /etc/apache2/conf-available/classement-security.conf \
    && a2enconf classement-security \
    && rm -rf /var/lib/apt/lists/* /tmp/pear

FROM php-base AS backend
RUN apt-get update && apt-get install -y --no-install-recommends git unzip \
    && rm -rf /var/lib/apt/lists/*
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
ARG SERVER_REPO=https://github.com/Zefling/classement-server.git
ARG SERVER_REF=main
ARG UPSTREAM_REFRESH=initial
RUN echo "Upstream refresh: ${UPSTREAM_REFRESH}" \
    && git clone --depth 1 --branch "$SERVER_REF" "$SERVER_REPO" /var/www/classement \
    && git -C /var/www/classement rev-parse HEAD > /tmp/server-revision
WORKDIR /var/www/classement
# Keep the original Symfony source unchanged. No PHP patches.
RUN --mount=type=cache,target=/root/.cache/composer \
    COMPOSER_ALLOW_SUPERUSER=1 composer install \
        --no-dev --no-scripts --no-interaction --prefer-dist --optimize-autoloader \
    && APP_ENV=prod APP_DEBUG=0 APP_SECRET=build-only \
       APP_PREFERENCES_ENCRYPTION_KEY=build-only MAILER_DSN=null://null \
       php bin/console assets:install public

FROM php-base AS runtime
ENV APP_ENV=prod APP_DEBUG=0
WORKDIR /var/www/classement
COPY --from=backend /var/www/classement/ /var/www/classement/
COPY --from=backend /tmp/server-revision /etc/classement/server-revision
COPY --from=frontend /build/client-revision /etc/classement/client-revision
COPY --from=frontend /build/client/dist/classement/browser/ /var/www/classement/public/
COPY docker/apache.conf /etc/apache2/sites-available/000-default.conf
COPY docker/router.htaccess /var/www/classement/public/.htaccess
COPY docker/php.ini /usr/local/etc/php/conf.d/classement.ini
RUN rm -rf /var/www/classement/.git \
    && mkdir -p /var/www/classement/public/images /var/www/classement/var \
    && chown -R www-data:www-data /var/www/classement/public/images /var/www/classement/var \
    && chmod 755 /var/www/classement/public
EXPOSE 80
CMD ["apache2-foreground"]
