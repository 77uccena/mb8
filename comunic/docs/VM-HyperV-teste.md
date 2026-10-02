# MB8 customizado – VM de teste no Hyper-V (Debian 13)

> **Desde o repositório:** as seções 3 e 4 (instalador oficial + pacote `mb8-custom.tar.gz`) foram trocadas por `git clone ... /opt/mb8-comunic && bash comunic/instalar.sh`. Para importar a base de produção na VM: `bash comunic/importar-banco.sh DUMP --teste`. Os scripts de teste estão em `comunic/testes/`.


Customizações deste pacote: tipo de plano e valor recorrente no cadastro do usuário,
relatório "Consumo por Plano", e a rotina do dia 20 (backup às 00:00, recarga às 00:30,
relatórios por e-mail para o financeiro).

## 1. Criar a VM (PowerShell como Administrador, no Windows)

Ajuste os caminhos, o nome da placa de rede e o nome do ISO.

```powershell
# Switch externo (a VM recebe IP da sua rede; necessário para testar ramais SIP)
Get-NetAdapter                         # veja o nome da sua placa (ex.: "Ethernet")
New-VMSwitch -Name "Externo" -NetAdapterName "Ethernet" -AllowManagementOS $true

New-VM -Name "MB8-Teste" -Generation 2 -MemoryStartupBytes 4GB `
  -NewVHDPath "C:\Hyper-V\MB8-Teste.vhdx" -NewVHDSizeBytes 40GB -SwitchName "Externo"
Set-VMProcessor -VMName "MB8-Teste" -Count 4
Set-VMMemory    -VMName "MB8-Teste" -DynamicMemoryEnabled $false
Set-VMFirmware  -VMName "MB8-Teste" -SecureBootTemplate "MicrosoftUEFICertificateAuthority"
Add-VMDvdDrive  -VMName "MB8-Teste" -Path "C:\ISOs\debian-13.x.x-amd64-netinst.iso"
Set-VMFirmware  -VMName "MB8-Teste" -FirstBootDevice (Get-VMDvdDrive -VMName "MB8-Teste")
Start-VM -Name "MB8-Teste"; vmconnect localhost "MB8-Teste"
```

Se preferir o Gerenciador do Hyper-V: Geração 2, 4 GB de RAM **sem** memória dinâmica,
4 processadores, disco de 40 GB, rede no switch Externo e, em Segurança, modelo de
Inicialização Segura **"Autoridade de Certificação UEFI da Microsoft"** (com o modelo
"Microsoft Windows" o Debian não inicia).

## 2. Instalar o Debian 13

- ISO: `debian-13.x.x-amd64-netinst.iso` (versão 13 mais recente em debian.org).
- Idioma/teclado à vontade. **Fuso horário: São Paulo** (a rotina roda às 00:00 e 00:30).
- Defina a senha de root e crie um usuário comum (ex.: `pedro`).
- Particionamento: guiado, disco inteiro.
- Seleção de software: **somente** "Servidor SSH" e "Utilitários standard do sistema"
  (sem ambiente gráfico).

Depois do primeiro boot, entre como root (`su -`) e rode:

```bash
apt update && apt full-upgrade -y
apt install -y hyperv-daemons curl
timedatectl set-timezone America/Sao_Paulo
timedatectl                 # confira: Time zone America/Sao_Paulo
ip -4 addr                  # anote o IP da VM
```

Tire um **ponto de verificação** (checkpoint) da VM: "Debian limpo".

## 3. Instalar o MagnusBilling 8 (instalador oficial)

Como root:

```bash
cd /root
curl -O https://raw.githubusercontent.com/magnussolution/magnusbilling/source/script/install.sh
bash install.sh
```

Leva de 30 a 60 minutos (compila o Asterisk) e reinicia no fim. Acesse
`http://IP_DA_VM` com usuário `root` e senha `magnus` e troque a senha.
Tire outro checkpoint: "MB8 oficial".

## 4. Aplicar as customizações

No Windows, copie o pacote para a VM (o Debian não aceita login SSH de root com senha,
por isso vai para o usuário comum):

```powershell
scp "C:\caminho\mb8-custom.tar.gz" pedro@IP_DA_VM:/home/pedro/
```

Na VM, como root:

```bash
cd /root && cp /home/pedro/mb8-custom.tar.gz . && tar xzf mb8-custom.tar.gz
cd mb8-custom && bash aplicar.sh
```

O script:
1. confere se os arquivos PHP do servidor são da mesma versão esperada
   (se não forem, **para sem alterar nada** e lista os arquivos diferentes);
2. confere o frontend pré-compilado (`app.js` dos temas);
3. faz backup em `/root/mb8-custom-backup-DATA/` (arquivos, `index.html`, traduções,
   crontab e as tabelas envolvidas);
4. copia os arquivos, acrescenta as traduções e inclui no `index.html` o script
   `custom/mb8-custom.js`, que carrega as telas novas **sem recompilar o frontend**;
5. roda `php cron.php PlanConsumptionSetup`: colunas novas, menu, configurações e as
   2 linhas do crontab. **Não altera a versão do banco** (não conflita com as
   atualizações oficiais do MagnusBilling);
6. mostra uma conferência final.

Pode rodar de novo quando quiser (reaplica os arquivos sem duplicar nada).

## 5. Depois de aplicar

Saia do painel e entre de novo, com **Ctrl+F5** para o navegador buscar o `index.html`
novo. Se as telas novas não aparecerem, abra o console do navegador (F12) e procure a
mensagem `[mb8-custom]`.

## 6. E-mail de teste sem enviar para ninguém (opcional, recomendado)

O Mailpit recebe os e-mails e mostra no navegador.

```bash
curl -sL https://raw.githubusercontent.com/axllent/mailpit/develop/install.sh | bash
cat > /etc/systemd/system/mailpit.service <<'EOF'
[Unit]
Description=Mailpit
After=network.target
[Service]
ExecStart=/usr/local/bin/mailpit --smtp 127.0.0.1:1025 --listen 0.0.0.0:8025 --smtp-auth-accept-any --smtp-auth-allow-insecure
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now mailpit
firewall-cmd --permanent --add-port=8025/tcp && firewall-cmd --reload
```

No painel, Configurações > SMTP (usuário root): host `127.0.0.1`, porta `1025`,
usuário `teste@teste.local`, senha `teste`, criptografia nenhuma.
Os e-mails aparecem em `http://IP_DA_VM:8025`.

## 7. Roteiro de validação

1. **Cadastro**: Clientes > Usuários > um usuário > aba Geral: "Tipo de plano" e
   "Valor recorrente". Salve 3 clientes (Franquia, Minutos, Ilimitado) no grupo Cliente.
2. **Configurações > Configuração**: "E-mail do financeiro", "Grupos da recarga
   recorrente" (3) e "Dia da recarga recorrente" (20).
3. **Relatório**: Relatórios > Consumo por Plano — escolha o **Ciclo** (mês da recarga).
   Colunas: Cliente | Usuário | Tipo de plano | Valor recorrente | Saldo (na recarga) |
   Recarga | Valor a pagar | Situação. Totais no painel lateral. "Exportar CSV" gera o mesmo
   Relatorio_de_Recarga do e-mail (sem total).
4. **Simulação sem gravar nada**:
   `php /var/www/html/mbilling/cron.php RecurringCredit dryrun`
5. **Rotina manual** (a partir do dia 20 do mês):
   ```bash
   php /var/www/html/mbilling/cron.php RecurringCredit backup   # 00:00
   php /var/www/html/mbilling/cron.php RecurringCredit          # 00:30
   ```
   Confira: e-mail do backup; e-mail com os 2 anexos; Faturamento > Recargas com
   "Crédito recorrente ... [RC-AAAAMM]"; arquivos em
   `/var/www/html/mbilling/protected/runtime/recurring_credit/`.
6. Rodar a recarga de novo **não** pode recarregar ninguém outra vez.
7. Log da rotina: `ls -lt /var/www/html/mbilling/protected/runtime/ | head` (arquivo com "recurring" no nome).

Para refazer um teste do zero, volte ao checkpoint "MB8 oficial".

## Atenção

A rotina age "a partir do dia 20". Se as customizações forem aplicadas entre o dia 21 e o
fim do mês, a recarga daquele mês roda **na mesma madrugada**. Na VM isso ajuda a testar;
em produção, aplique antes do dia 20 ou combine o primeiro mês.
