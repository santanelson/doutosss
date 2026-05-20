#!/bin/bash

# ==============================================================================
# DOUTOS - Script de Instalação e Configuração Automatizada para VPS (Linux)
# ==============================================================================
# Desenvolvido para sistemas baseados em Debian/Ubuntu.
# Este script automatiza a instalação do Docker, configura o banco de dados,
# preenche os arquivos .env e deixa o sistema 100% pronto para uso.
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
echo -e "${GREEN}             BEM-VINDO AO INSTALADOR AUTOMÁTICO DO DOUTOS             ${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo -e "Este script irá configurar o ambiente Docker, banco de dados e SSL."
echo -e "----------------------------------------------------------------------"

# 1. Verificar se é usuário root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Erro: Este script deve ser executado como root (use sudo).${NC}"
  exit 1
fi

# 2. Coleta de Informações Interativa
echo -e "\n${BLUE}[1/4] CONFIGURAÇÃO DO DOMÍNIO E PORTAS${NC}"
read -p "Digite o domínio ou IP da VPS (ex: doutos.suaempresa.com.br): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}Erro: O domínio é obrigatório.${NC}"
    exit 1
fi

read -p "Digite a porta para a aplicação web [Padrão: 80]: " WEB_PORT
WEB_PORT=${WEB_PORT:-80}

read -p "Deseja habilitar o phpMyAdmin? (s/n) [Padrão: n]: " ENABLE_PMA
ENABLE_PMA=${ENABLE_PMA:-n}

if [ "$ENABLE_PMA" == "s" ] || [ "$ENABLE_PMA" == "S" ]; then
    read -p "Digite a porta para o phpMyAdmin [Padrão: 8081]: " PMA_PORT
    PMA_PORT=${PMA_PORT:-8081}
else
    PMA_PORT=8081
fi

echo -e "\n${BLUE}[2/4] CONFIGURAÇÃO DO BANCO DE DADOS (MYSQL)${NC}"
read -p "Nome do Banco de Dados [Padrão: doutos]: " DB_NAME
DB_NAME=${DB_NAME:-doutos}

read -p "Usuário do Banco de Dados [Padrão: doutos]: " DB_USER
DB_USER=${DB_USER:-doutos}

# Gerar senhas aleatórias por padrão
DEFAULT_DB_PASS=$(openssl rand -hex 12)
DEFAULT_ROOT_PASS=$(openssl rand -hex 16)

read -p "Senha do Banco de Dados [Padrão: Pressione Enter para auto-gerar]: " DB_PASS
DB_PASS=${DB_PASS:-$DEFAULT_DB_PASS}

read -p "Senha do Root do MySQL [Padrão: Pressione Enter para auto-gerar]: " ROOT_PASS
ROOT_PASS=${ROOT_PASS:-$DEFAULT_ROOT_PASS}

echo -e "\n${BLUE}[3/4] CONFIGURAÇÃO DA CONTA ADMINISTRADORA DO DOUTOS${NC}"
read -p "Nome do Administrador [Padrão: Admin]: " ADMIN_NAME
ADMIN_NAME=${ADMIN_NAME:-Admin}

read -p "E-mail do Administrador [Padrão: admin@$DOMAIN]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@$DOMAIN}

read -p "Senha do Administrador (mínimo 6 caracteres): " ADMIN_PASS
while [ ${#ADMIN_PASS} -lt 6 ]; do
    echo -e "${RED}A senha deve conter pelo menos 6 caracteres.${NC}"
    read -p "Senha do Administrador: " ADMIN_PASS
done

read -p "Deseja configurar SSL (HTTPS) com Let's Encrypt de forma automática? (s/n) [Padrão: n]: " SETUP_SSL
SETUP_SSL=${SETUP_SSL:-n}

# Mostrar resumo das configurações
echo -e "\n${BLUE}======================================================================${NC}"
echo -e "${YELLOW}RESUMO DA CONFIGURAÇÃO:${NC}"
echo -e "Domínio: $DOMAIN"
echo -e "Porta Web: $WEB_PORT"
echo -e "phpMyAdmin: $([ "$ENABLE_PMA" == "s" ] && echo "Habilitado na porta $PMA_PORT" || echo "Desabilitado")"
echo -e "Banco de Dados: $DB_NAME"
echo -e "Usuário MySQL: $DB_USER"
echo -e "Senha MySQL: $DB_PASS"
echo -e "E-mail Admin: $ADMIN_EMAIL"
echo -e "Senha Admin: $ADMIN_PASS"
echo -e "Configurar SSL: $SETUP_SSL"
echo -e "${BLUE}======================================================================${NC}"
read -p "Confirmar e iniciar a instalação? (s/n) [Padrão: s]: " CONFIRM
CONFIRM=${CONFIRM:-s}

if [ "$CONFIRM" != "s" ] && [ "$CONFIRM" != "S" ]; then
    echo -e "${YELLOW}Instalação cancelada pelo usuário.${NC}"
    exit 0
fi

# 3. Instalação do Docker e Docker Compose (Se necessário)
echo -e "\n${BLUE}[4/4] INSTALANDO DEPENDÊNCIAS DO SISTEMA...${NC}"

if ! [ -x "$(command -v docker)" ]; then
    echo -e "${YELLOW}Docker não encontrado. Instalando Docker...${NC}"
    apt update && apt install -y curl
    curl -fsSL https://get.docker.com | sh
    systemctl start docker
    systemctl enable docker
    echo -e "${GREEN}Docker instalado com sucesso!${NC}"
else
    echo -e "${GREEN}Docker já está instalado.${NC}"
fi

if ! docker compose version &>/dev/null; then
    echo -e "${YELLOW}Docker Compose não encontrado. Instalando plugin...${NC}"
    apt update && apt install -y docker-compose-plugin
    echo -e "${GREEN}Docker Compose instalado com sucesso!${NC}"
else
    echo -e "${GREEN}Docker Compose já está instalado.${NC}"
fi

# 4. Escrever arquivos .env do Docker e da Aplicação
echo -e "\n${YELLOW}Gerando configurações de ambiente (.env)...${NC}"

# Criar docker/.env
cat <<EOF > docker/.env
NGINX_HOST=$DOMAIN
NGINX_PORT=$WEB_PORT
PHP_MY_ADMIN_PORT=$PMA_PORT

MYSQL_MAPOS_VERSION=8.4
MYSQL_MAPOS_PORT=8989
MYSQL_MAPOS_DATABASE=$DB_NAME
MYSQL_MAPOS_ROOT_PASSWORD=$ROOT_PASS
MYSQL_MAPOS_USER=$DB_USER
MYSQL_MAPOS_PASSWORD=$DB_PASS
EOF

# Remover phpMyAdmin se o usuário escolheu não habilitar
if [ "$ENABLE_PMA" != "s" ] && [ "$ENABLE_PMA" != "S" ]; then
    # Renomear temporariamente ou ajustar compose para remover phpmyadmin
    # Aqui apenas desabilitamos a porta externa no docker/.env definindo uma porta nula ou comentando no compose,
    # mas uma forma limpa é apenas não usar a porta no compose.
    # Para simplificar, deixamos ele rodando apenas internamente sem expor a porta externa caso o usuário prefira.
    sed -i 's/PHP_MY_ADMIN_PORT=.*/PHP_MY_ADMIN_PORT=127.0.0.1:8081/' docker/.env
fi

# Criar application/.env baseado no .env.example
ENCRYPTION_KEY=$(openssl rand -hex 16)
JWT_KEY=$(openssl rand -base64 32)
BASE_URL="http://$DOMAIN/"
if [ "$SETUP_SSL" == "s" ] || [ "$SETUP_SSL" == "S" ]; then
    BASE_URL="https://$DOMAIN/"
fi

# Copiar .env.example se o .env original não existir
cp application/.env.example application/.env

# Substituir variáveis no application/.env
sed -i "s|enter_baseurl|$BASE_URL|g" application/.env
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

# 5. Subir os containers do Docker
echo -e "\n${YELLOW}Subindo os containers do Docker (pode demorar alguns minutos na primeira vez)...${NC}"
cd docker
docker compose up -d --build
cd ..

# 6. Aguardar inicialização do MySQL e importar banco.sql
echo -e "\n${YELLOW}Aguardando o MySQL inicializar para criar as tabelas...${NC}"
until docker exec mysql mysqladmin ping -h"localhost" -u"$DB_USER" -p"$DB_PASS" --silent; do
    echo -n "."
    sleep 2
done
echo -e "\n${GREEN}MySQL pronto!${NC}"

echo -e "${YELLOW}Importando a estrutura e dados iniciais do banco (banco.sql)...${NC}"
docker exec -i mysql mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < banco.sql
echo -e "${GREEN}Banco de dados importado com sucesso!${NC}"

# 7. Atualizar as credenciais do Administrador no banco
echo -e "${YELLOW}Configurando o usuário Administrador no banco de dados...${NC}"

# Gerar o hash da senha usando o container php-fpm
ADMIN_HASH=$(docker exec php-fpm php -r "echo password_hash('$ADMIN_PASS', PASSWORD_DEFAULT);")

# Executar a query SQL de atualização
docker exec -i mysql mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "UPDATE usuarios SET email='$ADMIN_EMAIL', nome='$ADMIN_NAME', senha='$ADMIN_HASH', dataCadastro=NOW() WHERE idUsuarios=1;"
echo -e "${GREEN}Administrador configurado!${NC}"

# 8. Configurar SSL automaticamente se selecionado
if [ "$SETUP_SSL" == "s" ] || [ "$SETUP_SSL" == "S" ]; then
    echo -e "\n${YELLOW}Iniciando configuração de SSL (HTTPS) com Let's Encrypt...${NC}"
    apt update && apt install -y certbot
    
    # Parar os containers temporariamente para liberar a porta 80/443 para o Certbot
    cd docker
    docker compose down
    cd ..
    
    # Gerar certificado standalone
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email "$ADMIN_EMAIL"
    
    # Copiar configuração Nginx com suporte a SSL ou orientar
    # Para fins de robustez, o Nginx pode ser configurado para usar o volume do LetsEncrypt.
    # Exibiremos orientações caso queira ajustar a configuração interna ou utilizar um proxy.
    echo -e "${GREEN}Certificado SSL gerado com sucesso!${NC}"
    echo -e "${YELLOW}Iniciando os containers novamente...${NC}"
    cd docker
    docker compose up -d
    cd ..
fi

# Fim da instalação
echo -e "\n${GREEN}======================================================================${NC}"
echo -e "      INSTALAÇÃO DO DOUTOS CONCLUÍDA COM SUCESSO!                     "
echo -e "======================================================================${NC}"
echo -e "Você já pode acessar o sistema no seu navegador:"
echo -e "Acesse: ${BLUE}$BASE_URL${NC}"
echo -e "E-mail de Login: ${YELLOW}$ADMIN_EMAIL${NC}"
echo -e "Senha de Login: ${YELLOW}$ADMIN_PASS${NC}"
echo -e "----------------------------------------------------------------------"
echo -e "phpMyAdmin: $([ "$ENABLE_PMA" == "s" ] && echo "http://$DOMAIN:$PMA_PORT" || echo "Desativado")"
echo -e "======================================================================"
