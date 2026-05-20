FROM php:8.4-apache-bookworm

# Instala o instalador de extensões PHP (mlocati) de forma limpa e confiável
COPY --from=ghcr.io/mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

# Instala dependências do sistema e extensões necessárias
RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y \
    unzip \
    git \
    libcap2-bin \
    && install-php-extensions \
    bcmath \
    bz2 \
    calendar \
    exif \
    gettext \
    mysqli \
    opcache \
    pdo_mysql \
    xsl \
    gd \
    imap \
    intl \
    zip \
    sockets \
    xmlrpc \
    redis \
    imagick \
    && apt-get autoremove --purge -y && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Habilita o módulo rewrite do Apache (essencial para URLs limpas do CodeIgniter)
RUN a2enmod rewrite

# Copia nossa configuração do php.ini de produção
COPY docker/php.ini /usr/local/etc/php/conf.d/custom-php.ini

# Define a pasta raiz da aplicação
WORKDIR /var/www/html

# Copia o código fonte (respeitando o .dockerignore)
COPY . /var/www/html

# Copia o Composer do container oficial e instala dependências de produção
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer
RUN composer install --no-dev --optimize-autoloader --ignore-platform-reqs --no-scripts

# Define permissões recomendadas de arquivos e diretórios para o Apache
RUN chown -R www-data:www-data /var/www/html \
    && find /var/www/html -type d -exec chmod 755 {} \; \
    && find /var/www/html -type f -exec chmod 644 {} \;

# Expõe a porta 80 do Apache
EXPOSE 80

# Executa o Apache em primeiro plano
CMD ["apache2-foreground"]
