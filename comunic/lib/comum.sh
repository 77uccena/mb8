# shellcheck shell=bash
# Comunic - definicoes compartilhadas pelos scripts de comunic/.
# Uso: . "$(dirname "$0")/lib/comum.sh"   (de dentro de comunic/)

MB=/var/www/html/mbilling
COM="${COM:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO="$(cd "$COM/.." && pwd)"
ESTADO=/var/lib/mb8-comunic          # base validada, ultimo pacote, estado do vigia
LOGF=/var/log/mb8-comunic.log
PACOTE_URL="https://magnusbilling.org/download/MagnusBilling8-current.tar.gz"

# Arquivos do repositorio copiados para o painel (uma linha por arquivo).
lista_manifest() { grep -v '^\s*#' "$COM/MANIFEST" | awk 'NF {print $1}'; }

# Arquivos OFICIAIS em que as customizacoes se apoiam (nao sao alterados por nos).
# Se mudarem numa atualizacao, a atualizacao automatica para e pede revisao.
DEPENDENCIAS="
protected/components/BaseController.php
protected/components/Controller.php
protected/components/Model.php
protected/components/AccessManager.php
protected/models/User.php
protected/models/Configuration.php
protected/controllers/UserController.php
protected/controllers/AuthenticationController.php
"

# Classes/nomes do frontend compilado (app.js) usados pelo custom/mb8-custom.js.
TOKENS_FRONTEND="MBilling.view.user.Form MBilling.view.user.List MBilling.model.User Ext.ux.panel.Module Ext.ux.grid.Panel Ext.ux.form.Panel Ext.ux.app.ViewController Helper.Util mainData moneyfield formatMoneyDecimal"

# Nomes que sao nossos: se aparecerem na migracao oficial do banco, ha conflito.
NOMES_BANCO="plan_type recurring_value pkg_recurring_credit finance_email recurring_credit_groups recurring_credit_day planconsumption"

# Versoes dos 4 arquivos oficiais que a v11 (pacote antigo) substituia. Se o servidor
# ainda tiver estas versoes, o aplicar.sh devolve o arquivo oficial (agora usamos overrides).
V11_ALTERADOS="
9754da15d4e9e27984829ec00da38287494356afcb17c38a20630a7858f2b123  protected/models/User.php
71a678cd54df7ca029535759f71da78da1048b2a1340bfe067f1d5743f95d266  protected/controllers/UserController.php
70d5c2b8197dda814a2344f8aab55881bfca54ebf3a34d31266288c130b6c6db  protected/models/Configuration.php
b1ff83b39c04c17063f50ccd910e242bb63a8a9ad7e600154715ac3e663cbffc  protected/config/permissions.php
"

registrar() {  # registrar NIVEL mensagem...
    local n="$1"; shift
    mkdir -p "$(dirname "$LOGF")" 2>/dev/null
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$n" "$*" >> "$LOGF" 2>/dev/null
}

versao_banco() {
    mariadb mbilling -N -e "SELECT config_value FROM pkg_configuration WHERE config_key='version'" 2>/dev/null
}

dia_recarga() {
    local d
    d=$(mariadb mbilling -N -e "SELECT config_value FROM pkg_configuration WHERE config_key='recurring_credit_day'" 2>/dev/null)
    [[ "$d" =~ ^[0-9]+$ ]] || d=20
    echo "$d"
}

# Verdadeiro se hoje esta na janela proibida para atualizar (2 dias antes ate 1 dia depois
# do dia da recarga, no horario de Brasilia).
janela_da_recarga() {
    local d n
    d=$(dia_recarga)
    # hoje esta a -1..+2 dias do dia da recarga (vale tambem na virada do mes)
    for n in -1 0 1 2; do
        [ "$(TZ=America/Sao_Paulo date -d "today $n days" +%-d)" = "$d" ] && return 0
    done
    return 1
}

# Envia alerta por e-mail (Admin Email, SMTP do admin). Nao falha se nao houver SMTP.
alertar() {  # alertar "assunto" arquivo_ou_texto
    local assunto="$1" corpo="$2" arq
    if [ -f "$corpo" ]; then arq="$corpo"; else arq=$(mktemp); printf '%s\n' "$corpo" > "$arq"; fi
    if [ -f "$MB/protected/commands/ComunicAlertCommand.php" ]; then
        (cd "$MB" && php cron.php ComunicAlert "[$(hostname)] $assunto" "$arq") >> "$LOGF" 2>&1 || true
    fi
    registrar ALERTA "$assunto"
}
