#!/bin/bash

# ==============================================================================
# DOUTOS - Script de Instalação e Configuração Automatizada Multi-Instância para VPS
# ==============================================================================
# Desenvolvido para sistemas baseados em Debian/Ubuntu.
# Este script gerencia a criação de instâncias isoladas, detecta portas livres,
# cria os diretórios automaticamente e deixa o sistema pronto para uso.
# ==============================================================================

# Cores para saída do terminal
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # Sem cor

# Limpar tela inicial
clear
echo -e "${BLUE}======================================================================${NC}"
echo -e "${GREEN}       BEM-VINDO AO INSTALADOR MULTI-INSTÂNCIA DO DOUTOS              ${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo -e "Este script cria uma instalação isolada e configurada do DOUTOS."
echo -e "----------------------------------------------------------------------"

# 1. Verificar se é usuário root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Erro: Este script deve ser executado como root (use sudo).${NC}"
  exit 1
fi

# 1.5. Instalação de TODAS as dependências do sistema (VPS crua)
echo -e "\n${BLUE}[0/5] PREPARANDO SISTEMA - Instalando dependências...${NC}"
apt update -qq

# Pacotes base necessários para o script funcionar
DEPS_BASE=("curl" "git" "rsync" "openssl" "net-tools" "ca-certificates" "gnupg" "lsb-release" "apt-transport-https" "software-properties-common")
for dep in "${DEPS_BASE[@]}"; do
    if ! command -v "$dep" &>/dev/null && ! dpkg -l "$dep" &>/dev/null; then
        echo -e "${YELLOW}Instalando: $dep${NC}"
        apt install -y "$dep" -qq
    fi
done
echo -e "${GREEN}Pacotes base prontos!${NC}"

# Instalar Docker se não estiver presente
if ! command -v docker &>/dev/null; then
    echo -e "${YELLOW}Docker não encontrado. Instalando Docker Engine...${NC}"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update -qq
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -qq
    systemctl enable docker --now
    echo -e "${GREEN}Docker instalado com sucesso!${NC}"
else
    echo -e "${GREEN}Docker já está instalado: $(docker --version)${NC}"
fi

# Verificar Docker Compose
if ! docker compose version &>/dev/null; then
    echo -e "${YELLOW}Instalando plugin docker-compose...${NC}"
    apt install -y docker-compose-plugin -qq
fi
echo -e "${GREEN}Docker Compose: $(docker compose version)${NC}"

# Garantir que a rede pública do Traefik exista no Docker
docker network create traefik-public 2>/dev/null || true

echo -e "${GREEN}Sistema preparado com sucesso!${NC}"
echo -e "----------------------------------------------------------------------"

# 2. Definição do Nome da Instância
echo -e "${BLUE}[1/5] DEFINIÇÃO DA INSTÂNCIA${NC}"
read -p "Digite o identificador único da instância (ex: cliente1, filial2): " INSTANCE_INPUT
if [ -z "$INSTANCE_INPUT" ]; then
    echo -e "${RED}Erro: O nome da instância é obrigatório.${NC}"
    exit 1
fi

# Sanitizar nome da instância (apenas letras, números, hífen e underline)
INSTANCE_NAME=$(echo "$INSTANCE_INPUT" | tr -cd 'a-zA-Z0-9_-' | tr '[:upper:]' '[:lower:]')

if [ -z "$INSTANCE_NAME" ]; then
    echo -e "${RED}Erro: O nome da instância após sanitização ficou vazio.${NC}"
    exit 1
fi

TARGET_DIR="/var/www/doutos_instances/$INSTANCE_NAME"
CURRENT_DIR=$(pwd)

# 3. Criação de Diretórios e Cópia de Arquivos (Auto-implantação)
if [ "$CURRENT_DIR" != "$TARGET_DIR" ]; then
    echo -e "\n${YELLOW}Preparando diretório de instalação em: $TARGET_DIR...${NC}"
    mkdir -p "$TARGET_DIR"
    
    # Copiar arquivos do repositório/diretório atual para o destino
    if command -v rsync &> /dev/null; then
        rsync -a --exclude='.git' --exclude='docker/data' ./ "$TARGET_DIR/"
    else
        cp -R ./* "$TARGET_DIR/" 2>/dev/null || true
        rm -rf "$TARGET_DIR/.git" 2>/dev/null || true
    fi
    
    echo -e "${GREEN}Arquivos copiados para $TARGET_DIR com sucesso!${NC}"
    
    # Mudar para o diretório de destino e continuar a execução lá
    cd "$TARGET_DIR"
fi

# 4. Funções para Detecção de Portas Disponíveis
is_port_in_use() {
    local port=$1
    if command -v ss &> /dev/null; then
        ss -tuln | grep -qE ":$port\s"
    elif command -v netstat &> /dev/null; then
        netstat -tuln | grep -qE ":$port\s"
    else
        (echo >/dev/tcp/127.0.0.1/$port) &>/dev/null
    fi
}

get_available_port() {
    local start_port=$1
    local port=$start_port
    while is_port_in_use $port; do
        port=$((port + 1))
    done
    echo $port
}

# 5. Escolha do método de Exposição e SSL (Solicitado no início para calcular as sugestões corretas de portas)
echo -e "\n${BLUE}[2/5] ESCOLHA DO MÉTODO DE EXPOSIÇÃO E SSL${NC}"
echo -e "1) Usar Proxy Reverso Traefik no Docker com SSL Let's Encrypt (Altamente recomendado e 100% dinâmico)"
echo -e "2) Usar Proxy Reverso Nginx na VPS com SSL Let's Encrypt"
echo -e "3) Usar Proxy Reverso Nginx na VPS SEM SSL (HTTP normal)"
echo -e "4) Exposição direta pelo Docker com SSL Let's Encrypt (Standalone - requer liberar portas 80/443 no Docker)"
echo -e "5) Exposição direta pelo Docker SEM SSL (HTTP normal)"
read -p "Selecione a opção desejada [Padrão: 1]: " EXPOSE_OPTION
EXPOSE_OPTION=${EXPOSE_OPTION:-1}

USE_TRAEFIK="n"
USE_HOST_PROXY="n"
SETUP_SSL="n"

if [ "$EXPOSE_OPTION" == "1" ]; then
    USE_TRAEFIK="s"
    SETUP_SSL="s"
elif [ "$EXPOSE_OPTION" == "2" ]; then
    USE_HOST_PROXY="s"
    SETUP_SSL="s"
elif [ "$EXPOSE_OPTION" == "3" ]; then
    USE_HOST_PROXY="s"
    SETUP_SSL="n"
elif [ "$EXPOSE_OPTION" == "4" ]; then
    USE_HOST_PROXY="n"
    SETUP_SSL="s"
else
    USE_HOST_PROXY="n"
    SETUP_SSL="n"
fi

# Detectar portas sugeridas com base na escolha de exposição
if [ "$USE_TRAEFIK" == "s" ] || [ "$USE_HOST_PROXY" == "s" ]; then
    # Proxy Reverso (Traefik ou Nginx VPS) -> Sugerir porta alta para o container
    SUGGESTED_WEB_PORT=$(get_available_port 8000)
else
    # Standalone -> Tentar sugerir porta 80. Se ocupada, sugerir porta alta.
    SUGGESTED_WEB_PORT=$(get_available_port 80)
    if [ "$SUGGESTED_WEB_PORT" -ne 80 ] && [ "$SUGGESTED_WEB_PORT" -lt 8000 ]; then
        SUGGESTED_WEB_PORT=$(get_available_port 8000)
    fi
fi

SUGGESTED_PMA_PORT=$(get_available_port 8081)
SUGGESTED_MYSQL_PORT=$(get_available_port 8989)

# 6. Coleta de Informações Interativa
echo -e "\n${BLUE}[3/5] CONFIGURAÇÃO DO DOMÍNIO E PORTAS${NC}"
read -p "Digite o domínio ou IP da VPS (ex: $INSTANCE_NAME.seudominio.com.br): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}Erro: O domínio é obrigatório.${NC}"
    exit 1
fi

read -p "Porta para a aplicação web (Nginx) [Sugerida livre: $SUGGESTED_WEB_PORT]: " WEB_PORT
WEB_PORT=${WEB_PORT:-$SUGGESTED_WEB_PORT}

read -p "Deseja habilitar o phpMyAdmin para esta instância? (s/n) [Padrão: n]: " ENABLE_PMA
ENABLE_PMA=${ENABLE_PMA:-n}

if [ "$ENABLE_PMA" == "s" ] || [ "$ENABLE_PMA" == "S" ]; then
    read -p "Porta externa do phpMyAdmin [Sugerida livre: $SUGGESTED_PMA_PORT]: " PMA_PORT
    PMA_PORT=${PMA_PORT:-$SUGGESTED_PMA_PORT}
else
    PMA_PORT=$SUGGESTED_PMA_PORT
fi

read -p "Porta externa para o MySQL [Sugerida livre: $SUGGESTED_MYSQL_PORT]: " MYSQL_PORT
MYSQL_PORT=${MYSQL_PORT:-$SUGGESTED_MYSQL_PORT}

echo -e "\n${BLUE}[4/5] CONFIGURAÇÃO DO BANCO DE DADOS (MYSQL)${NC}"
# Banco e usuário padrão baseados no nome da instância para evitar colisões
read -p "Nome do Banco de Dados [Padrão: doutos_$INSTANCE_NAME]: " DB_NAME
DB_NAME=${DB_NAME:-"doutos_$INSTANCE_NAME"}

read -p "Usuário do Banco de Dados [Padrão: user_$INSTANCE_NAME]: " DB_USER
DB_USER=${DB_USER:-"user_$INSTANCE_NAME"}

# Gerar senhas aleatórias robustas por padrão
DEFAULT_DB_PASS=$(openssl rand -hex 12)
DEFAULT_ROOT_PASS=$(openssl rand -hex 16)

read -p "Senha do Banco de Dados [Pressione Enter para auto-gerar]: " DB_PASS
DB_PASS=${DB_PASS:-$DEFAULT_DB_PASS}

read -p "Senha do Root do MySQL [Pressione Enter para auto-gerar]: " ROOT_PASS
ROOT_PASS=${ROOT_PASS:-$DEFAULT_ROOT_PASS}

echo -e "\n${BLUE}[5/5] CONFIGURAÇÃO DA CONTA ADMINISTRADORA DO SISTEMA${NC}"
read -p "Nome do Administrador [Padrão: Admin]: " ADMIN_NAME
ADMIN_NAME=${ADMIN_NAME:-Admin}

read -p "E-mail do Administrador [Padrão: admin@$DOMAIN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$DOMAIN"}

read -p "Senha do Administrador (mínimo 6 caracteres): " ADMIN_PASS
while [ ${#ADMIN_PASS} -lt 6 ]; do
    echo -e "${RED}A senha deve conter pelo menos 6 caracteres.${NC}"
    read -p "Senha do Administrador: " ADMIN_PASS
done

# Configurar as variáveis de portas de acordo com a opção de exposição
if [ "$USE_TRAEFIK" == "s" ]; then
    if [ "$WEB_PORT" -eq 80 ] || [ "$WEB_PORT" -eq 443 ]; then
        WEB_PORT=$(get_available_port 8080)
    fi
    NGINX_PORT_BIND="127.0.0.1:$WEB_PORT:$WEB_PORT"
    NGINX_SSL_PORT_BIND="127.0.0.1:9443:443"
    NGINX_TEMPLATE="default"
    TRAEFIK_ENABLE="true"
elif [ "$USE_HOST_PROXY" == "s" ]; then
    NGINX_PORT_BIND="127.0.0.1:$WEB_PORT:$WEB_PORT"
    NGINX_SSL_PORT_BIND="127.0.0.1:9443:443"
    NGINX_TEMPLATE="default"
    TRAEFIK_ENABLE="false"
else
    TRAEFIK_ENABLE="false"
    if [ "$SETUP_SSL" == "s" ]; then
        NGINX_PORT_BIND="$WEB_PORT:80"
        NGINX_SSL_PORT_BIND="443:443"
        NGINX_TEMPLATE="ssl"
    else
        NGINX_PORT_BIND="$WEB_PORT:$WEB_PORT"
        NGINX_SSL_PORT_BIND="127.0.0.1:9443:443"
        NGINX_TEMPLATE="default"
    fi
fi

# Mostrar resumo das configurações
echo -e "\n${BLUE}======================================================================${NC}"
echo -e "${YELLOW}RESUMO DA CONFIGURAÇÃO DA INSTÂNCIA [ $INSTANCE_NAME ]:${NC}"
echo -e "Diretório: $TARGET_DIR"
echo -e "Domínio: $DOMAIN"
echo -e "Porta Nginx: $WEB_PORT (Tipo: $([ "$USE_TRAEFIK" == "s" ] && echo "Local escutando em 127.0.0.1 (Roteado via Traefik)" || ([ "$USE_HOST_PROXY" == "s" ] && echo "Local escutando em 127.0.0.1 (Proxy Reverso Nginx)" || echo "Exposta Pública no Host")))"
echo -e "phpMyAdmin: $([ "$ENABLE_PMA" == "s" ] && echo "Habilitado na porta $PMA_PORT" || echo "Desabilitado")"
echo -e "MySQL (Porta Host): $MYSQL_PORT"
echo -e "Banco de Dados: $DB_NAME"
echo -e "Usuário MySQL: $DB_USER"
echo -e "Senha MySQL: $DB_PASS"
echo -e "E-mail Admin: $ADMIN_EMAIL"
echo -e "Senha Admin: $ADMIN_PASS"
echo -e "Proxy Reverso Traefik (Docker): $([ "$USE_TRAEFIK" == "s" ] && echo "Sim" || echo "Não")"
echo -e "Proxy Reverso Nginx (VPS): $([ "$USE_HOST_PROXY" == "s" ] && echo "Sim" || echo "Não")"
echo -e "Configurar SSL: $([ "$SETUP_SSL" == "s" ] && echo "Sim" || echo "Não")"
echo -e "======================================================================"
read -p "Confirmar e iniciar a instalação da instância? (s/n) [Padrão: s]: " CONFIRM
CONFIRM=${CONFIRM:-s}

if [ "$CONFIRM" != "s" ] && [ "$CONFIRM" != "S" ]; then
    echo -e "${YELLOW}Instalação cancelada pelo usuário.${NC}"
    exit 0
fi

# 7. Escrever arquivos .env do Docker e da Aplicação
echo -e "\n${YELLOW}Gerando configurações de ambiente (.env)...${NC}"

# Criar docker/.env personalizado com o COMPOSE_PROJECT_NAME
cat <<EOF > docker/.env
COMPOSE_PROJECT_NAME=$INSTANCE_NAME
NGINX_HOST=$DOMAIN
NGINX_PORT=$WEB_PORT
NGINX_TEMPLATE=$NGINX_TEMPLATE
NGINX_PORT_BIND=$NGINX_PORT_BIND
NGINX_SSL_PORT_BIND=$NGINX_SSL_PORT_BIND
TRAEFIK_ENABLE=$TRAEFIK_ENABLE
PHP_MY_ADMIN_PORT=$PMA_PORT

MYSQL_DOUTOS_VERSION=8.4
MYSQL_DOUTOS_HOST=mysql
MYSQL_DOUTOS_PORT=$MYSQL_PORT
MYSQL_DOUTOS_DATABASE=$DB_NAME
MYSQL_DOUTOS_ROOT_PASSWORD=$ROOT_PASS
MYSQL_DOUTOS_USER=$DB_USER
MYSQL_DOUTOS_PASSWORD=$DB_PASS
EOF

# Desativar PMA externamente se não solicitado
if [ "$ENABLE_PMA" != "s" ] && [ "$ENABLE_PMA" != "S" ]; then
    sed -i 's/PHP_MY_ADMIN_PORT=.*/PHP_MY_ADMIN_PORT=127.0.0.1:8081/' docker/.env
fi

# Criar application/.env baseado no .env.example
ENCRYPTION_KEY=$(openssl rand -hex 16)
JWT_KEY=$(openssl rand -base64 32)
BASE_URL="http://$DOMAIN"
if [ "$WEB_PORT" -ne 80 ] && [ "$WEB_PORT" -ne 443 ] && [ "$USE_HOST_PROXY" != "s" ]; then
    BASE_URL="http://$DOMAIN:$WEB_PORT"
fi

if [ "$SETUP_SSL" == "s" ]; then
    BASE_URL="https://$DOMAIN"
fi

# Copiar .env.example se o .env original não existir
cp application/.env.example application/.env

# Substituir variáveis no application/.env
sed -i "s|enter_baseurl|$BASE_URL/|g" application/.env
sed -i "s|enter_encryption_key|$ENCRYPTION_KEY|g" application/.env
sed -i "s|pre_installation|production|g" application/.env
sed -i "s|enter_db_hostname|mysql|g" application/.env
sed -i "s|enter_db_username|$DB_USER|g" application/.env
sed -i "s|enter_db_password|$DB_PASS|g" application/.env
sed -i "s|enter_db_name|$DB_NAME|g" application/.env
sed -i "s|enter_api_enabled|true|g" application/.env
sed -i "s|enter_jwt_key|$JWT_KEY|g" application/.env
sed -i "s|enter_token_expire_time|86400|g" application/.env

# Ajustar permissões para que o php-fpm (www-data com UID 1000) possa atualizar as configurações
chown 1000:1000 application/.env 2>/dev/null || true
chmod 664 application/.env

echo -e "${GREEN}Configurações de ambiente geradas com sucesso!${NC}"

# 8. Subir os containers do Docker para esta instância
echo -e "\n${YELLOW}Subindo os containers do Docker da instância (pode demorar na primeira execução)...${NC}"
cd docker
docker compose up -d --build
cd ..

# 9. Aguardar inicialização do MySQL e importar banco.sql
echo -e "\n${YELLOW}Aguardando o banco MySQL (${INSTANCE_NAME}_mysql) iniciar...${NC}"
until docker exec ${INSTANCE_NAME}_mysql mysqladmin ping -uroot -p"$ROOT_PASS" -h"127.0.0.1" --silent 2>/dev/null; do
    echo -n "."
    sleep 2
done
echo -e "\n${GREEN}MySQL pronto!${NC}"

echo -e "${YELLOW}Importando a estrutura e dados iniciais do banco (banco.sql)...${NC}"
docker exec -i ${INSTANCE_NAME}_mysql mysql -uroot -p"$ROOT_PASS" -h"127.0.0.1" "$DB_NAME" < banco.sql
echo -e "${GREEN}Banco de dados importado com sucesso!${NC}"

# 10. Atualizar as credenciais do Administrador no banco
echo -e "${YELLOW}Configurando o usuário Administrador no banco de dados...${NC}"

# Gerar o hash da senha usando o container php-fpm
ADMIN_HASH=$(docker exec ${INSTANCE_NAME}_php-fpm php -r "echo password_hash('$ADMIN_PASS', PASSWORD_DEFAULT);")

# Executar a query SQL de atualização
docker exec -i ${INSTANCE_NAME}_mysql mysql -uroot -p"$ROOT_PASS" -h"127.0.0.1" "$DB_NAME" -e "UPDATE usuarios SET email='$ADMIN_EMAIL', nome='$ADMIN_NAME', senha='$ADMIN_HASH', dataCadastro=NOW() WHERE idUsuarios=1;"
echo -e "${GREEN}Administrador configurado!${NC}"

# 11. Configuração do Proxy Reverso na VPS e/ou SSL
if [ "$USE_TRAEFIK" == "s" ]; then
    echo -e "\n${YELLOW}Configurando Proxy Reverso Traefik no Docker...${NC}"
    
    # 1. Verificar se o Traefik já está rodando
    if ! docker ps --format '{{.Names}}' | grep -Eq "^traefik$"; then
        echo -e "${YELLOW}Traefik não está rodando na VPS. Configurando Traefik global...${NC}"
        
        TRAEFIK_DIR="/var/www/traefik"
        mkdir -p "$TRAEFIK_DIR/letsencrypt"
        touch "$TRAEFIK_DIR/letsencrypt/acme.json"
        chmod 600 "$TRAEFIK_DIR/letsencrypt/acme.json"
        
        # Gerar o docker-compose.yml do Traefik
        cat <<EOF > "$TRAEFIK_DIR/docker-compose.yml"
services:
  traefik:
    image: traefik:v3.0
    container_name: traefik
    restart: always
    command:
      - "--api.insecure=false"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.letsencrypt.acme.email=$ADMIN_EMAIL"
      - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "./letsencrypt:/letsencrypt"
    networks:
      - traefik-public

networks:
  traefik-public:
    external: true
EOF

        # Se ufw estiver ativo, liberar portas 80 e 443
        if command -v ufw &>/dev/null && ufw status | grep -q 'active'; then
            ufw allow 80/tcp
            ufw allow 443/tcp
        fi

        # Se houver Nginx na porta 80 do Host, avisa e para ele
        if systemctl is-active --quiet nginx 2>/dev/null; then
            echo -e "${YELLOW}Aviso: Nginx local está rodando na VPS. Parando e desativando ele para liberar as portas 80/443 para o Traefik...${NC}"
            systemctl stop nginx
            systemctl disable nginx
        fi

        # Subir o Traefik
        cd "$TRAEFIK_DIR"
        docker compose up -d
        cd - &>/dev/null
        echo -e "${GREEN}Traefik global iniciado com sucesso!${NC}"
    else
        echo -e "${GREEN}Traefik global já está rodando na VPS.${NC}"
    fi

elif [ "$USE_HOST_PROXY" == "s" ]; then
    echo -e "\n${YELLOW}Configurando Proxy Reverso Nginx na VPS...${NC}"
    
    # 1. Instalar Nginx na VPS se não estiver instalado
    if ! command -v nginx &>/dev/null; then
        echo -e "${YELLOW}Nginx não encontrado na VPS. Instalando...${NC}"
        apt update -qq
        apt install -y nginx -qq
        systemctl enable nginx --now
    fi
    
    # 2. Criar configuração do site no Nginx da VPS
    NGINX_CONF="/etc/nginx/sites-available/$INSTANCE_NAME"
    cat <<EOF > "$NGINX_CONF"
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$WEB_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 20M;
    }
}
EOF

    # 3. Ativar o site no Nginx
    ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/"
    
    # Remover o site default do Nginx se ele existir e for conflitar
    if [ -f "/etc/nginx/sites-enabled/default" ]; then
        rm -f "/etc/nginx/sites-enabled/default"
    fi
    
    # Testar Nginx e recarregar
    nginx -t &>/dev/null
    if [ $? -eq 0 ]; then
        systemctl reload nginx
        echo -e "${GREEN}Proxy Reverso Nginx configurado com sucesso!${NC}"
    else
        echo -e "${RED}Erro na configuração do Nginx da VPS. Verifique manualmente com 'nginx -t'.${NC}"
    fi

    # 4. Configurar SSL se selecionado
    if [ "$SETUP_SSL" == "s" ]; then
        echo -e "\n${YELLOW}Configurando SSL (HTTPS) com Let's Encrypt no Nginx da VPS...${NC}"
        
        # Instalar certbot e plugin se necessário
        if ! command -v certbot &>/dev/null; then
            apt update -qq
            apt install -y certbot python3-certbot-nginx -qq
        fi
        
        # Liberar portas no firewall (se ufw estiver ativo)
        if command -v ufw &>/dev/null && ufw status | grep -q 'active'; then
            ufw allow 80/tcp
            ufw allow 443/tcp
            echo -e "${GREEN}Portas 80 e 443 liberadas no firewall.${NC}"
        fi
        
        # Gerar certificado usando o plugin nginx
        certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$ADMIN_EMAIL" --redirect
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}SSL gerado e configurado com sucesso no Nginx da VPS!${NC}"
            BASE_URL="https://$DOMAIN"
            # Atualizar BASE_URL no application/.env
            sed -i "s|http://$DOMAIN|https://$DOMAIN|g" application/.env
        else
            echo -e "${RED}Falha ao gerar SSL pelo Certbot. Verifique se o domínio $DOMAIN aponta para este IP.${NC}"
            BASE_URL="http://$DOMAIN"
        fi
    fi
    
    # Recarregar o Nginx da VPS por segurança
    systemctl reload nginx 2>/dev/null || true

elif [ "$SETUP_SSL" == "s" ]; then
    # SETUP_SSL="s" mas USE_HOST_PROXY="n" (Instalação standalone antiga)
    echo -e "\n${YELLOW}Iniciando configuração de SSL Standalone (no Docker)...${NC}"
    apt install -y certbot -qq

    # Liberar portas no firewall (se ufw estiver ativo)
    if command -v ufw &>/dev/null && ufw status | grep -q 'active'; then
        ufw allow 80/tcp
        ufw allow 443/tcp
    fi

    # Parar os containers para liberar a porta 80
    cd docker
    docker compose down
    cd ..

    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email "$ADMIN_EMAIL"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Certificado SSL standalone gerado com sucesso!${NC}"
        # Ajustar variáveis no .env da instância
        sed -i 's/NGINX_TEMPLATE=default/NGINX_TEMPLATE=ssl/' docker/.env
        sed -i 's|NGINX_SSL_PORT_BIND=.*|NGINX_SSL_PORT_BIND=443:443|' docker/.env
        sed -i "s|NGINX_PORT_BIND=.*|NGINX_PORT_BIND=$WEB_PORT:80|" docker/.env
        BASE_URL="https://$DOMAIN"
        # Atualizar BASE_URL no application/.env
        sed -i "s|http://$DOMAIN|https://$DOMAIN|g" application/.env

        cd docker
        docker compose up -d
        cd ..
    else
        echo -e "${RED}Falha ao gerar SSL standalone. Iniciando sem SSL...${NC}"
        cd docker
        docker compose up -d
        cd ..
    fi
fi

# Fim da instalação
echo -e "\n${GREEN}======================================================================${NC}"
echo -e "  INSTALAÇÃO DA INSTÂNCIA [ $INSTANCE_NAME ] CONCLUÍDA COM SUCESSO!  "
echo -e "======================================================================${NC}"
echo -e "Você já pode acessar a instância no seu navegador:"
echo -e "Acesse: ${BLUE}$BASE_URL${NC}"
echo -e "E-mail de Login: ${YELLOW}$ADMIN_EMAIL${NC}"
echo -e "Senha de Login: ${YELLOW}$ADMIN_PASS${NC}"
echo -e "----------------------------------------------------------------------"
echo -e "Diretório físico: $TARGET_DIR"
echo -e "MySQL Exposto no Host: 127.0.0.1:$MYSQL_PORT"
echo -e "phpMyAdmin: $([ "$ENABLE_PMA" == "s" ] && echo "http://$DOMAIN:$PMA_PORT" || echo "Desativado")"
echo -e "======================================================================"
