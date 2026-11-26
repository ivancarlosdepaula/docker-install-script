#!/usr/bin/env bash

# Interrompe o script se ocorrer algum erro
set -e

# Identifica o usuário real (caso o script tenha sido rodado com 'sudo ./script.sh')
REAL_USER=${SUDO_USER:-$USER}

echo "==> Removendo pacotes conflitantes..."
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do 
    sudo apt-get remove -y $pkg || true
done

echo "==> Instalando dependências..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl

echo "==> Adicionando a chave GPG oficial do Docker..."
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "==> Configurando o repositório oficial..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "==> Atualizando o apt e instalando o Docker Engine..."
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> [Pós-instalação] Configurando o grupo 'docker'..."
# Cria o grupo docker caso não exista
sudo groupadd docker || true

# Adiciona o usuário real ao grupo docker
echo "==> Adicionando o usuário '$REAL_USER' ao grupo docker..."
sudo usermod -aG docker "$REAL_USER"

echo "==> [Pós-instalação] Ajustando permissões do diretório ~/.docker para evitar erros futuros..."
# Previne o erro "permission denied" no config.json se o Docker foi rodado antes com sudo
if [ -d "/home/$REAL_USER/.docker" ]; then
    sudo chown "$REAL_USER":"$REAL_USER" /home/"$REAL_USER"/.docker -R
    sudo chmod g+rwx "/home/$REAL_USER/.docker" -R
fi

echo "==> [Pós-instalação] Habilitando o Docker para iniciar com o sistema (boot)..."
sudo systemctl enable docker.service
sudo systemctl enable containerd.service

echo "==> Concluído!"
echo "======================================================================="
echo "AVISO IMPORTANTE:"
echo "As permissões de grupo foram aplicadas ao usuário '$REAL_USER'."
echo "Para que você possa rodar 'docker run ...' SEM o sudo, é necessário:"
echo "1. Fazer LOGOUT e LOGIN novamente no seu usuário."
echo "2. OU executar o comando agora mesmo:  newgrp docker"
echo "======================================================================="
