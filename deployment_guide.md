# Guia de Implantação e Execução (DOUTOS)

Este guia orienta sobre como rodar o sistema localmente (usando Docker Desktop) e como implantá-lo em ambiente de produção em uma VPS.

---

## 1. Execução Local (Docker Desktop)

### Pré-requisitos
* **Docker Desktop** instalado e em execução no Windows.
* Porta **8000** (Nginx), **8081** (phpMyAdmin) e **8989** (MySQL) liberadas no sistema.

### Passo a Passo

1. **Subir os Containers:**
   Abra um terminal (PowerShell ou CMD) na pasta raiz do projeto e execute:
   ```powershell
   cd docker
   docker-compose up -d --build
   ```

2. **Ferramentas de Gerenciamento Local:**
   * **Visualizar Banco de Dados:** Acesse o phpMyAdmin em `http://localhost:8081/`.
     * Host: `mysql` | Usuário: `doutos` | Senha: `doutos`
   * **Parar os containers:**
     ```powershell
     docker-compose down
     ```

---

## 2. Implantação em Produção (VPS Linux - Debian/Ubuntu)

Para simplificar a instalação em produção, criamos o script automatizado **`setup_vps.sh`** na raiz do projeto. Ele gerencia a instalação do Docker, configura as variáveis de ambiente, importa o banco de dados e cria o seu usuário administrador automaticamente.

### Passo 1: Configuração do Servidor DNS
Antes de iniciar, aponte o seu domínio (ou subdomínio) para o IP público da sua VPS:
* Criar um registro **A** apontando `doutos.seudominio.com` para o `IP_DA_VPS`.

### Passo 2: Execução do Script Automatizado (Recomendado)
Acesse a sua VPS via SSH e execute os seguintes comandos:

```bash
# 1. Navegue até o diretório onde o código foi clonado
cd /var/www/doutos

# 2. Dê permissão de execução ao script
chmod +x setup_vps.sh

# 3. Execute o script como root/sudo
sudo ./setup_vps.sh
```

**O que o script fará:**
* Validará se o Docker e o Docker Compose estão instalados (e os instalará se necessário).
* Solicitará interativamente os dados do seu domínio, portas da aplicação e credenciais do banco.
* Criará de forma automática as senhas do MySQL e o usuário administrador.
* Importará o arquivo `banco.sql` estruturando as tabelas.
* Oferecerá a opção de instalar e configurar o Certbot para SSL (HTTPS) de graça.

---

## 3. Implantação Manual (Alternativa)

Caso prefira configurar passo a passo de forma manual:

1. **Ajuste o arquivo `docker/.env` na VPS:**
   ```bash
   nano docker/.env
   ```
   Defina as portas de produção e credenciais seguras:
   ```env
   NGINX_HOST=doutos.seudominio.com
   NGINX_PORT=80
   MYSQL_MAPOS_PORT=3306
   MYSQL_MAPOS_DATABASE=doutos
   MYSQL_MAPOS_ROOT_PASSWORD=senha_forte_root
   MYSQL_MAPOS_USER=doutos
   MYSQL_MAPOS_PASSWORD=senha_forte_usuario
   ```

2. **Crie o arquivo `application/.env` na VPS:**
   Copie o template e preencha as credenciais correspondentes ao banco e URL base:
   ```bash
   cp application/.env.example application/.env
   # Edite e configure os campos hostname=mysql, DB_DATABASE, etc.
   ```

3. **Inicie os containers:**
   ```bash
   docker compose -f docker/docker-compose.yml up -d --build
   ```

4. **Importe o banco inicial:**
   ```bash
   docker exec -i mysql mysql -udoutos -pSUA_SENHA doutos < banco.sql
   ```

---

## 4. Comandos Úteis na VPS

* **Subir aplicação:** `docker compose -f docker/docker-compose.yml up -d`
* **Parar aplicação:** `docker compose -f docker/docker-compose.yml down`
* **Ver logs em tempo real:** `docker compose -f docker/docker-compose.yml logs -f`
* **Executar comandos no PHP (ex: rodar migrations do CodeIgniter):**
  ```bash
  docker exec -it php-fpm php index.php migrate
  ```
