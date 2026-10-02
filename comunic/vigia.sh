#!/bin/bash
#
# Comunic - vigia (crontab do root, a cada 5 minutos; instalado pelo aplicar.sh).
#
# Se alguma parte da customizacao sumir (por exemplo, alguem rodou a atualizacao
# oficial e o index.html/traducoes voltaram ao original), reaplica sozinho com
# comunic/aplicar.sh --silencioso e manda um e-mail de alerta.
# Se nao conseguir corrigir, alerta de novo no maximo a cada 6 horas.
#
set -u
COM="$(cd "$(dirname "$0")" && pwd)"
. "$COM/lib/comum.sh"
mkdir -p "$ESTADO"
EST="$ESTADO/vigia.estado"

bash "$COM/saude.sh" --quieto && { rm -f "$EST"; exit 0; }

ANTES=$(bash "$COM/saude.sh" 2>&1 | grep FALHA)
registrar AVISO "vigia: customizacao incompleta: $(echo "$ANTES" | tr '\n' ' ')"

# nao mexe durante a rotina da recarga (00:00-01:00 de Brasilia no dia da recarga)
if [ "$(TZ=America/Sao_Paulo date +%-d)" = "$(dia_recarga)" ] && [ "$(TZ=America/Sao_Paulo date +%-H)" = "0" ]; then
    registrar AVISO "vigia: horario da recarga, correcao adiada"
    exit 0
fi

SAIDA=$(bash "$COM/aplicar.sh" --silencioso 2>&1); RC=$?
DEPOIS=$(bash "$COM/saude.sh" 2>&1)
if bash "$COM/saude.sh" --quieto; then
    registrar OK "vigia: corrigido automaticamente"
    alertar "MagnusBilling: customizacao Comunic restaurada automaticamente" "O vigia encontrou partes da customizacao faltando e reaplicou (aplicar.sh --silencioso).

O que estava faltando:
$ANTES

Conferencia depois da correcao:
$DEPOIS

Causa mais comum: a atualizacao oficial do MagnusBilling foi executada fora do
comunic/atualizar-mb8.sh. Log: $LOGF"
    rm -f "$EST"
    exit 0
fi

# nao corrigiu: alerta (no maximo a cada 6 horas)
AGORA=$(date +%s); ULT=$(cat "$EST" 2>/dev/null || echo 0)
if [ $((AGORA - ULT)) -ge 21600 ]; then
    echo "$AGORA" > "$EST"
    alertar "URGENTE MagnusBilling: customizacao Comunic com falha" "O vigia NAO conseguiu restaurar a customizacao.

Conferencia:
$DEPOIS

Saida do aplicar.sh (codigo $RC):
$SAIDA

Rode manualmente:  bash $COM/aplicar.sh   e   bash $COM/saude.sh --completo"
fi
exit 1
