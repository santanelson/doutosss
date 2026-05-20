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

# Detectar portas sugeridas
SUGGESTED_WEB_PORT=$(get_available_port 80)
# Se a porta 80 já estiver em uso, sugerimos a primeira porta a partir de 8000
if [ "$SUGGESTED_WEB_PORT" -ne 80 ] && [ "$SUGGESTED_WEB_PORT" -lt 8000 ]; then
    SUGGESTED_WEB_PORT=$(get_available_port 8000)
fi

SUGGESTED_PMA_PORT=$(get_available_port 8081)
SUGGESTED_MYSQL_PORT=$(get_available_port 8989)

# 5. Coleta de Informações Interativa
echo -e "\n${BLUE}[2/5] CONFIGURAÇÃO DO DOMÍNIO E PORTAS${NC}"
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

echo -e "\n${BLUE}[3/5] CONFIGURAÇÃO DO BANCO DE DADOS (MYSQL)${NC}"
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

echo -e "\n${BLUE}[4/5] CONFIGURAÇÃO DA CONTA ADMINISTRADORA DO SISTEMA${NC}"
read -p "Nome do Administrador [Padrão: Admin]: " ADMIN_NAME
ADMIN_NAME=${ADMIN_NAME:-Admin}

read -p "E-mail do Administrador [Padrão: admin@$DOMAIN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$DOMAIN"}

read -p "Senha do Administrador (mínimo 6 caracteres): " ADMIN_PASS
while [ ${#ADMIN_PASS} -lt 6 ]; do
    echo -e "${RED}A senha deve conter pelo menos 6 caracteres.${NC}"
    read -p "Senha do Administrador: " ADMIN_PASS
done

# Alerta sobre SSL em instalações multi-instâncias
echo -e "\n${YELLOW}Nota sobre SSL (HTTPS): Se você estiver rodando múltiplas instâncias com portas diferentes"
echo -e "(ex: 8000, 8001) atrás de um Reverse Proxy (como Nginx Proxy Manager), selecione 'n' aqui e configure"
echo -e "o SSL diretamente no seu Reverse Proxy principal.${NC}"
read -p "Deseja configurar SSL (HTTPS) com Let's Encrypt de forma automática? (s/n) [Padrão: n]: " SETUP_SSL
SETUP_SSL=${SETUP_SSL:-n}

# Mostrar resumo das configurações
echo -e "\n${BLUE}======================================================================${NC}"
echo -e "${YELLOW}RESUMO DA CONFIGURAÇÃO DA INSTÂNCIA [ $INSTANCE_NAME ]:${NC}"
echo -e "Diretório: $TARGET_DIR"
echo -e "Domínio: $DOMAIN"
echo -e "Porta Nginx: $WEB_PORT"
echo -e "phpMyAdmin: $([ "$ENABLE_PMA" == "s" ] && echo "Habilitado na porta $PMA_PORT" || echo "Desabilitado")"
echo -e "MySQL (Porta Host): $MYSQL_PORT"
echo -e "Banco de Dados: $DB_NAME"
echo -e "Usuário MySQL: $DB_USER"
echo -e "Senha MySQL: $DB_PASS"
echo -e "E-mail Admin: $ADMIN_EMAIL"
echo -e "Senha Admin: $ADMIN_PASS"
echo -e "Configurar SSL: $SETUP_SSL"
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
PHP_MY_ADMIN_PORT=$PMA_PORT

MYSQL_MAPOS_VERSION=8.4
MYSQL_MAPOS_HOST=mysql
MYSQL_MAPOS_PORT=$MYSQL_PORT
MYSQL_MAPOS_DATABASE=$DB_NAME
MYSQL_MAPOS_ROOT_PASSWORD=$ROOT_PASS
MYSQL_MAPOS_USER=$DB_USER
MYSQL_MAPOS_PASSWORD=$DB_PASS
EOF

# Desativar PMA externamente se não solicitado
if [ "$ENABLE_PMA" != "s" ] && [ "$ENABLE_PMA" != "S" ]; then
    sed -i 's/PHP_MY_ADMIN_PORT=.*/PHP_MY_ADMIN_PORT=127.0.0.1:8081/' docker/.env
fi

# Criar application/.env baseado no .env.example
ENCRYPTION_KEY=$(openssl rand -hex 16)
JWT_KEY=$(openssl rand -base64 32)
BASE_URL="http://$DOMAIN"
if [ "$WEB_PORT" -ne 80 ] && [ "$WEB_PORT" -ne 443 ]; then
    BASE_URL="http://$DOMAIN:$WEB_PORT"
fi

if [ "$SETUP_SSL" == "s" ] || [ "$SETUP_SSL" == "S" ]; then
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

# 11. Configurar SSL automaticamente se selecionado
if [ "$SETUP_SSL" == "s" ] || [ "$SETUP_SSL" == "S" ]; then
    echo -e "\n${YELLOW}Iniciando configuração de SSL (HTTPS) com Let's Encrypt...${NC}"
    apt install -y certbot -qq
    
    # Parar os containers para liberar a porta 80 para o Certbot standalone
    cd docker
    docker compose down
    cd ..
    
    # Gerar certificado
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email "$ADMIN_EMAIL"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Certificado SSL gerado com sucesso!${NC}"
        
        # Ativar template SSL no docker-compose (troca default.template por ssl.template)
        # O nginx já tem /etc/letsencrypt montado via docker-compose.yml
        # Atualizamos o command do nginx para usar o ssl.template.conf
        sed -i 's|envsubst.*default.template.*default.conf|envsubst '\''$$NGINX_HOST$$NGINX_PORT'\'' < /etc/nginx/conf.d/ssl.template > /etc/nginx/conf.d/default.conf|g' docker/docker-compose.yml
        
        echo -e "${YELLOW}Re-iniciando os containers com SSL ativo...${NC}"
        cd docker
        docker compose up -d
        cd ..
        
        BASE_URL="https://$DOMAIN"
    else
        echo -e "${RED}Falha ao gerar certificado SSL. Verifique se o domínio aponta para este IP e a porta 80 está acessível.${NC}"
        echo -e "${YELLOW}Re-iniciando containers sem SSL...${NC}"
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
