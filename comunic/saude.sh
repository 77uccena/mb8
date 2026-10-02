#!/bin/bash
#
# Comunic - confere se as customizacoes estao ativas na instalacao atual. Somente leitura.
#
#   bash comunic/saude.sh              conferencia rapida (usada pelo vigia a cada 5 min)
#   bash comunic/saude.sh --completo   + sintaxe PHP, HTTP do script e simulacao da recarga
#   bash comunic/saude.sh --quieto     so o codigo de saida (0 = tudo certo)
#
# Codigo: 0 = ok; 1 = algo faltando (o vigia corrige com o aplicar.sh).
#
set -u
COM="$(cd "$(dirname "$0")" && pwd)"
. "$COM/lib/comum.sh"
COMPLETO=0; QUIETO=0
for A in "$@"; do
    case "$A" in --completo) COMPLETO=1 ;; --quieto) QUIETO=1 ;; esac
done
FALHAS=0
ok()    { [ $QUIETO -eq 1 ] || echo "OK    $*"; }
falha() { [ $QUIETO -eq 1 ] || echo "FALHA $*"; FALHAS=$((FALHAS+1)); }

[ -f "$MB/index.html" ] || { falha "MagnusBilling nao encontrado em $MB"; exit 1; }

# arquivos nossos presentes (ausente = falha; diferente do repositorio = so aviso, porque
# a atualizacao oficial nao mexe neles: e um git pull ainda nao aplicado)
FALTA=""; DIF=""
for ARQ in $(lista_manifest); do
    if [ ! -f "$MB/$ARQ" ]; then FALTA="$FALTA $ARQ"
    elif ! cmp -s "$REPO/$ARQ" "$MB/$ARQ"; then DIF="$DIF $ARQ"; fi
done
[ -z "$FALTA" ] && ok "arquivos da customizacao presentes" || falha "arquivos da customizacao ausentes:$FALTA"
[ -z "$DIF" ] || { [ $QUIETO -eq 1 ] || echo "AVISO diferentes do repositorio (git pull sem aplicar? rode comunic/aplicar.sh):$DIF"; }

grep -q "custom/mb8-custom.js" "$MB/index.html" && ok "index.html carrega custom/mb8-custom.js" \
    || falha "index.html NAO carrega custom/mb8-custom.js (telas novas sumiram)"
grep -q "'Recurring value'" "$MB/resources/locale/pt_BR.js" && grep -q "'Recurring value'" "$MB/resources/locale/php/pt_BR/zii.php" \
    && ok "traducoes presentes" || falha "traducoes ausentes"

# banco
COLS=$(mariadb mbilling -N -e "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='mbilling' AND TABLE_NAME='pkg_user' AND COLUMN_NAME IN ('plan_type','recurring_value')" 2>/dev/null)
[ "$COLS" = "2" ] && ok "colunas plan_type e recurring_value" || falha "colunas do plano ausentes em pkg_user"
[ -n "$(mariadb mbilling -N -e "SHOW TABLES LIKE 'pkg_recurring_credit'" 2>/dev/null)" ] && ok "tabela pkg_recurring_credit" \
    || falha "tabela pkg_recurring_credit ausente"
[ "$(mariadb mbilling -N -e "SELECT COUNT(*) FROM pkg_module WHERE module='planconsumption'" 2>/dev/null)" = "1" ] \
    && ok "menu Relatorios > Consumo por Plano" || falha "menu planconsumption ausente"

# crontab
CR=$(crontab -l 2>/dev/null)
[ "$(echo "$CR" | grep -v '^\s*#' | grep -c 'cron.php RecurringCredit')" -ge 2 ] && ok "crontab: 2 linhas RecurringCredit" \
    || falha "crontab sem as 2 linhas RecurringCredit"
if echo "$CR" | grep -Eq '^[^#].*protected/commands/update\.sh'; then
    falha "atualizacao automatica oficial (update.sh) LIGADA no crontab"
else
    ok "atualizacao automatica oficial desligada"
fi

if [ $COMPLETO -eq 1 ]; then
    for ARQ in $(lista_manifest | grep '\.php$'); do
        php -l "$MB/$ARQ" >/dev/null 2>&1 || falha "erro de sintaxe PHP: $ARQ"
    done
    ok "sintaxe PHP conferida"
    CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1/mbilling/custom/mb8-custom.js" 2>/dev/null)
    [ "$CODE" = "200" ] && ok "custom/mb8-custom.js responde HTTP 200" || falha "custom/mb8-custom.js -> HTTP ${CODE:-?}"
    if (cd "$MB" && timeout 300 php cron.php RecurringCredit dryrun > /tmp/mb8-comunic-dryrun.txt 2>&1) \
        && grep -Eq "Relatorio_de_Recarga|no user pending" /tmp/mb8-comunic-dryrun.txt; then
        ok "simulacao da recarga (dryrun) roda sem erro"
    else
        falha "simulacao da recarga (dryrun) falhou: veja /tmp/mb8-comunic-dryrun.txt"
    fi
fi

[ $QUIETO -eq 1 ] || echo "Resultado: $FALHAS falha(s)"
[ $FALHAS -eq 0 ]
