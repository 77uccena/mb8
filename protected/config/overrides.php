<?php

/**
 * Comunic - overrides do MagnusBilling (mecanismo oficial do BaseController).
 *
 * 'models'      => modulos cujo model e trocado por protected/models/overrides/<Nome>OR.php
 * 'controllers' => (nao usado) acoes redirecionadas para protected/controllers/overrides/
 *
 * Este arquivo e as pastas overrides/ nao existem no pacote oficial, entao a
 * atualizacao do MagnusBilling nao os sobrescreve. Instalado por comunic/aplicar.sh.
 */
$GLOBALS['overrides'] = [
    'controllers' => [],
    'models'      => ['User', 'Configuration'],
];
