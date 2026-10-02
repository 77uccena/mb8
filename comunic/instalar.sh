#!/bin/bash
#
# Comunic - instalacao LIMPA do MagnusBilling 8 customizado em um servidor novo
# (Debian 11, 12 ou 13, sem MagnusBilling instalado).
#
#   1. roda o instalador oficial (script/install.sh deste repositorio): Apache, PHP,
#      MariaDB, Asterisk 20, pacote oficial MagnusBilling8-current e banco vazio;
#   2. aplica as customizacoes (comunic/aplicar.sh);
#   3. NAO reinicia sozinho: mostra os proximos passos (importar o banco de producao).
#
# Uso (como root):
#   apt install -y git
#   git clone git@github.com:77uccena/mb8.git /opt/mb8-comunic
#   cd /opt/mb8-comunic && bash comunic/instalar.sh [--fuso America/Sao_Paulo]
#
# --fuso ZONA  ajusta o fuso do sistema ANTES de instalar (o PHP herda o fuso do sistema
#              na instalacao). Use o MESMO fuso da producao atual (veja com: timedatectl).
#
# Leva de 30 a 60 minutos (compila o Asterisk).
#
set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:${PATH}}"
COM="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$COM/.." && pwd)"
MB=/var/www/html/mbilling
LOG=/root/mb8-comunic-instalacao-$(date +%Y%m%d-%H%M%S).log
FUSO=""
if [ "${1:-}" = "--fuso" ]; then
    FUSO="${2:-}"
    [ -n "$FUSO" ] && [ -f "/usr/share/zoneinfo/$FUSO" ] || { echo "Fuso invalido: '$FUSO' (ex.: America/Sao_Paulo, UTC)"; exit 2; }
fi

[ "$(id -u)" = "0" ] || { echo "Rode como root (su -)."; exit 1; }
[ -f "$REPO/script/install.sh" ] || { echo "script/install.sh nao encontrado em $REPO."; exit 1; }
if [ -f "$MB/index.php" ]; then
    echo "Este servidor ja tem MagnusBilling em $MB."
    echo "Para so aplicar as customizacoes: bash $COM/aplicar.sh"
    exit 1
fi
case "$REPO" in
    $MB|$MB/*) echo "Nao clone o repositorio dentro de $MB (use /opt/mb8-comunic)."; exit 1 ;;
esac

. /etc/os-release 2>/dev/null
echo "Servidor: $(hostname) - ${PRETTY_NAME:-?} - IP $(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$FUSO" ] && echo "Fuso a ser ajustado: $FUSO"
echo "Fuso horario atual: $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)"
echo "  (a rotina da recarga roda 00:00/00:30 de Brasilia em qualquer fuso; os horarios das"
echo "   ligacoes e relatorios seguem o fuso do servidor - use o mesmo da producao atual)"
echo "Log completo: $LOG"
echo
read -r -p "Instalar o MagnusBilling 8 + customizacoes Comunic neste servidor? Digite SIM: " OK
[ "$OK" = "SIM" ] || { echo "Cancelado."; exit 1; }
if [ -n "$FUSO" ]; then
    timedatectl set-timezone "$FUSO" || { echo "Nao consegui ajustar o fuso para $FUSO."; exit 1; }
fi

# O instalador oficial termina com uma janela "pressione uma tecla" e reboot.
# Rodamos uma copia sem essas duas linhas para aplicar as customizacoes antes.
TMP=$(mktemp -d)
cp "$REPO/script/install.sh" "$TMP/install.sh"
sed -i -E '/^whiptail --title "MagnusBilling Instalation Result"/d; /^reboot\s*$/d' "$TMP/install.sh"
if grep -Eq '^reboot\s*$' "$TMP/install.sh"; then
    echo "Nao consegui retirar o reboot do instalador oficial. Nada foi feito."; exit 1
fi

echo "== 1/3 Instalador oficial do MagnusBilling 8"
( cd "$TMP" && bash install.sh ) 2>&1 | tee -a "$LOG"
if [ ! -f "$MB/index.html" ] || [ ! -f "$MB/cron.php" ]; then
    echo "O instalador oficial nao terminou (veja $LOG). Customizacoes nao aplicadas."; exit 1
fi
if [ -z "$(mariadb mbilling -N -e "SELECT config_value FROM pkg_configuration WHERE config_key='version'" 2>/dev/null)" ]; then
    echo "Banco mbilling nao encontrado depois do instalador (veja $LOG)."; exit 1
fi

echo "== 2/3 Customizacoes Comunic"
bash "$COM/aplicar.sh" 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
rm -rf "$TMP"
if [ "$RC" != "0" ]; then
    cat <<FIM

ATENCAO: o MagnusBilling foi instalado, mas as customizacoes NAO ficaram completas
(provavelmente o pacote oficial baixado mudou algo de que a customizacao depende).
Veja as linhas ERRO/FALHA acima e no log $LOG, e rode: bash $COM/compat.sh
FIM
    exit 1
fi

echo "== 3/3 Proximos passos"
cat <<FIM

MagnusBilling 8 + customizacoes Comunic instalados. Banco ainda VAZIO (usuario root / senha magnus).

 1. Reinicie o servidor:            reboot
 2. Copie o dump da producao (MB7 ou MB8) para /root e importe:
      bash $COM/importar-banco.sh /root/mbilling-producao.sql.gz
 3. Configuracoes > Configuracao: E-mail do financeiro, Grupos e Dia da recarga.
    Configuracoes > SMTP. Depois:   bash $COM/conferir-producao.sh

Guia completo: $COM/README.md
Log: $LOG
FIM
