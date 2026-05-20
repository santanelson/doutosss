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

## 2. Implantação em Produção (Multi-Instância - VPS Linux Debian/Ubuntu)

Para simplificar a instalação e permitir a execução de **múltiplas instâncias independentes** na mesma VPS, criamos o script automatizado **`setup_vps.sh`** na raiz do projeto. 

O script faz o seguinte:
* Cria automaticamente o diretório de instalação isolado da instância em `/var/www/doutos_instances/<nome_da_instancia>`.
* Copia os arquivos do template para a pasta da instância.
* Varre as portas da VPS para sugerir **portas livres** (Web, MySQL e phpMyAdmin) para evitar conflitos com outras instâncias.
* Nomeia os containers no Docker de forma dinâmica baseados no nome da instância (ex: `cliente1_mysql`, `cliente1_php-fpm`).
* Configura as credenciais de banco, variáveis `.env` e cria a conta admin da instância.
* Permite opcionalmente gerar SSL (HTTPS) automático.

### Passo 1: Configuração do Servidor DNS
Aponte o domínio ou subdomínio específico da instância para o IP da sua VPS:
* Criar registro **A** apontando `cliente1.seudominio.com.br` para o `IP_DA_VPS`.

### Passo 2: Execução do Script Automatizado
Acesse a sua VPS via SSH e execute os seguintes comandos:

```bash
# 1. Navegue até o diretório onde você clonou o repositório base (ex: /var/www/doutos)
cd /var/www/doutos

# 2. Dê permissão de execução ao script
chmod +x setup_vps.sh

# 3. Execute o script como root/sudo
sudo ./setup_vps.sh
```

Durante a execução, o instalador perguntará o identificador único da instância (ex: `cliente1`) e configurará tudo a partir de lá. Você pode rodar o script novamente a qualquer momento com um novo nome para criar uma nova instância independente.

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
   MYSQL_DOUTOS_PORT=3306
   MYSQL_DOUTOS_DATABASE=doutos
   MYSQL_DOUTOS_ROOT_PASSWORD=senha_forte_root
   MYSQL_DOUTOS_USER=doutos
   MYSQL_DOUTOS_PASSWORD=senha_forte_usuario
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
