# docker-install-script

🇺🇸 [English](README.md) | 🇧🇷 Português

Um único script Bash, idempotente, que **instala o Docker Engine pelo repositório oficial do Docker** no Debian, Ubuntu e derivados — ou, se o Docker já estiver instalado, **verifica cada item da configuração, corrige apenas o que estiver faltando e gera um relatório**.

## Uso rápido

No servidor Linux, execute:

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosdepaula/docker-install-script/main/install.sh | bash
```

Somente relatório (não altera nada):

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosdepaula/docker-install-script/main/install.sh | bash -s -- --check
```

> Rode com seu usuário comum (ele vai pedir a senha do `sudo`) ou como `root`.
> Se rodar como root e quiser que um usuário comum entre no grupo `docker`, use `--user NOME`.

## O que ele verifica (e corrige)

| # | Item | Correção aplicada se faltar |
|---|------|-----------------------------|
| 1 | Sistema suportado (Debian / Ubuntu / derivados via `ID_LIKE`) | — (encerra se não for suportado) |
| 2 | systemd presente | — (apenas aviso) |
| 3 | Pacotes conflitantes (`docker.io`, `docker-compose`, `podman-docker`, `containerd`, `runc`…) | Remove apenas os que estiverem instalados |
| 4 | Repositório APT oficial do Docker (`.list` ou `.sources`) | Cria `/etc/apt/sources.list.d/docker.list` |
| 5 | Chave GPG do repositório existe e tem leitura para todos | Baixa em `/etc/apt/keyrings/docker.asc` / `chmod a+r` |
| 6 | Pacotes `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` | Instala apenas os que faltam |
| 7 | Serviços `docker` e `containerd` habilitados no boot e em execução | `systemctl enable` / `start` |
| 8 | Grupo `docker` existe | `groupadd docker` |
| 9 | Usuário pertence ao grupo `docker` | `usermod -aG docker USUARIO` |
| 10 | `~/.docker` pertence ao usuário | `chown -R` + `chmod -R g+rwx` |
| 11 | Daemon do Docker respondendo (mostra versões do Engine, Compose e Buildx) | — (resultado das etapas acima) |

Se estiver tudo certo, ele informa e **não altera nada**. Rodar de novo é sempre seguro.

## Opções

```text
-c, --check        Somente verifica e gera o relatório (não altera nada)
-u, --user NOME    Usuário a ser adicionado ao grupo docker (padrão: $SUDO_USER ou o usuário atual)
-t, --test         Ao final, executa "docker run --rm hello-world"
    --report-dir D Diretório do arquivo de relatório (padrão: /tmp)
    --no-color     Desativa as cores
-v, --version      Mostra a versão
-h, --help         Mostra a ajuda
```

Ao usar via `curl`, passe as opções depois de `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosdepaula/docker-install-script/main/install.sh | sudo bash -s -- --user deploy --test
```

Variáveis de ambiente equivalentes: `DOCKER_CHECK_ONLY=1`, `DOCKER_USER=nome`, `DOCKER_RUN_TEST=1`, `REPORT_DIR=/caminho`, `NO_COLOR=1`.

**Código de saída:** `0` = ambiente OK · `1` = há itens pendentes ou ocorreu erro. Útil para automação e monitoramento:

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosdepaula/docker-install-script/main/install.sh | bash -s -- --check --no-color || echo "Docker precisa de atenção"
```

## Relatório

O relatório aparece na tela e é salvo em texto puro em `/tmp/docker-report-<host>-<data>.txt`:

```text
-----------------------------------------------------------------------
 ESTADO ATUAL
-----------------------------------------------------------------------
[  OK  ] Sistema operacional             Ubuntu 24.04 LTS (repo: ubuntu/noble, amd64)
[  OK  ] Pacotes conflitantes            nenhum instalado
[  OK  ] Repositório oficial do Docker   /etc/apt/sources.list.d/docker.list
[  OK  ] Pacote docker-ce                5:29.x
[ FALTA] Usuário no grupo 'docker'       ivan não pertence ao grupo
[  OK  ] Docker daemon                   respondendo (Engine 29.x | compose v5.x | buildx v0.x)

Resumo: 13 OK | 1 pendente(s) | 0 aviso(s)
```

Quando há correções, o script mostra também o **ESTADO FINAL** e a lista de **Ações executadas**.

## Depois de instalar

Se o seu usuário foi adicionado ao grupo `docker`, faça logout e login novamente (ou rode `newgrp docker`) para usar o `docker` sem `sudo`.

## Nota de segurança

Enviar um script da internet direto para o `bash` executa esse script com as suas permissões. Se preferir ler antes:

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosdepaula/docker-install-script/main/install.sh -o install.sh
less install.sh
bash install.sh
```

O script inteiro fica dentro da função `main`, que só é chamada na última linha — um download interrompido nunca executa o script pela metade.

## Requisitos

- Debian, Ubuntu ou derivado (Linux Mint, Pop!_OS, Zorin etc.) em uma versão suportada pelo Docker
- Acesso `root` ou `sudo`
- Acesso à internet para `download.docker.com`
