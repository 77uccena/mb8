# shellcheck shell=bash
# Incluido no inicio dos scripts de teste: eles CRIAM/ALTERAM clientes e saldos.
# Bloqueia se a maquina parecer producao (troncos ativos) e pede o nome da maquina.
_TR=$(mariadb mbilling -N -e "SELECT COUNT(*) FROM pkg_trunk WHERE status=1" 2>/dev/null || echo 0)
if [ "${_TR:-0}" -gt 0 ]; then
    echo "BLOQUEADO: $_TR tronco(s) ativo(s). Scripts de teste so rodam em VM de teste"
    echo "(importe a base com: bash comunic/importar-banco.sh DUMP --teste)."
    exit 1
fi
echo "SCRIPT DE TESTE: altera clientes/saldos de $(hostname) ($(hostname -I | awk '{print $1}'))."
read -r -p "Digite o nome desta maquina para continuar: " _OK
[ "$_OK" = "$(hostname)" ] || { echo "Cancelado."; exit 1; }
