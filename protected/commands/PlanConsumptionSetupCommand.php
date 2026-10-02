<?php

/**
 * Instala/atualiza no banco as customizacoes de:
 *   - tipo de plano e valor recorrente (pkg_user)
 *   - tabela pkg_recurring_credit (saldo antes de cada recarga recorrente)
 *   - menu Relatorios > Consumo por Plano
 *   - configuracoes da recarga recorrente
 *   - linhas do crontab (00:00 backup / 00:30 recarga, horario de Brasilia)
 *
 * NAO usa o controle de versao do MagnusBilling (pkg_configuration.version),
 * para nao conflitar com as atualizacoes oficiais (UpdateMysql).
 * Pode ser executado quantas vezes quiser: so cria o que estiver faltando.
 *
 *   php /var/www/html/mbilling/cron.php PlanConsumptionSetup
 */
class PlanConsumptionSetupCommand extends CConsoleCommand
{
    public function run($args)
    {
        $this->log('Iniciando.');

        if (! $this->columnExists('pkg_user', 'plan_type')) {
            $this->execute('ALTER TABLE `pkg_user` ADD `plan_type` VARCHAR(20) NULL DEFAULT NULL');
            $this->log('Coluna pkg_user.plan_type criada.');
        }
        if (! $this->columnExists('pkg_user', 'recurring_value')) {
            $this->execute("ALTER TABLE `pkg_user` ADD `recurring_value` DECIMAL(15,4) NOT NULL DEFAULT '0.0000'");
            $this->log('Coluna pkg_user.recurring_value criada.');
        }
        if (! $this->indexExists('pkg_user', 'idx_pkg_user_plan_type')) {
            $this->execute('ALTER TABLE `pkg_user` ADD KEY `idx_pkg_user_plan_type` (`plan_type`)');
        }

        // foto de cada recarga recorrente (saldo antes, recarga) - base do relatorio de recarga
        $this->execute(
            "CREATE TABLE IF NOT EXISTS `pkg_recurring_credit` (
               `id` INT NOT NULL AUTO_INCREMENT,
               `id_user` INT NOT NULL,
               `month` CHAR(6) NOT NULL,
               `plan_type` VARCHAR(20) NOT NULL,
               `recurring_value` DECIMAL(15,4) NOT NULL,
               `credit_before` DECIMAL(15,4) NOT NULL,
               `refill` DECIMAL(15,4) NOT NULL,
               `id_refill` INT NULL,
               `date` DATETIME NOT NULL,
               PRIMARY KEY (`id`),
               UNIQUE KEY `uk_recurring_credit_user_month` (`id_user`, `month`),
               KEY `idx_recurring_credit_month` (`month`)
             ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3"
        );

        // menu Relatorios > Consumo por Plano (id_module 9 = Relatorios)
        $parent = (int) Yii::app()->db->createCommand(
            "SELECT id FROM pkg_module WHERE text = 't(''Reports'')' AND module IS NULL ORDER BY id LIMIT 1"
        )->queryScalar();
        $parent = $parent > 0 ? $parent : 9;

        $this->execute(
            "INSERT INTO pkg_module (text, module, icon_cls, id_module, priority)
             SELECT 't(''Consumption per Plan'')', 'planconsumption', 'x-fa fa-desktop', :parent, 15
             WHERE NOT EXISTS (SELECT 1 FROM pkg_module WHERE module = 'planconsumption')",
            [':parent' => $parent]
        );
        // permissao de leitura para o grupo Administrator (id 1)
        $this->execute(
            "INSERT INTO pkg_group_module (id_group, id_module, action, show_menu, createShortCut, createQuickStart)
             SELECT 1, m.id, 'r', 1, 0, 0 FROM pkg_module m
             WHERE m.module = 'planconsumption'
               AND NOT EXISTS (SELECT 1 FROM pkg_group_module gm WHERE gm.id_group = 1 AND gm.id_module = m.id)"
        );

        // configuracoes (Configuracoes > Configuracao)
        $settings = [
            ['E-mail do financeiro', 'finance_email', '',
                'E-mail(s) que recebem os relatorios mensais da recarga recorrente (separe varios com ;). Vazio = Admin Email.'],
            ['Grupos da recarga recorrente', 'recurring_credit_groups', '3',
                'IDs dos grupos de usuarios que recebem a recarga do valor recorrente, separados por virgula. 3 = Cliente.'],
            ['Dia da recarga recorrente', 'recurring_credit_day', '20',
                'Dia do mes (1 a 28) da rotina da recarga recorrente: backup as 00:00 e recarga as 00:30.'],
            ['E-mail de alertas tecnicos', 'comunic_alert_email', '',
                'E-mail(s) que recebem os alertas do vigia e da atualizacao do MagnusBilling (separe varios com ;). Vazio = Admin Email.'],
        ];
        foreach ($settings as $s) {
            $this->execute(
                "INSERT INTO pkg_configuration (config_title, config_key, config_value, config_description, config_group_title, status)
                 SELECT :title, :k, :v, :d, 'global', 1
                 WHERE NOT EXISTS (SELECT 1 FROM pkg_configuration WHERE config_key = :k2)",
                [':title' => $s[0], ':k' => $s[1], ':v' => $s[2], ':d' => $s[3], ':k2' => $s[1]]
            );
        }

        // crontab do root
        $cronPath = null;
        foreach (['/var/spool/cron/crontabs/root', '/var/spool/cron/root'] as $path) {
            if (file_exists($path)) {
                $cronPath = $path;
                break;
            }
        }
        if ($cronPath) {
            // a rotina roda as 00:00 / 00:30 no horario de Brasilia, qualquer que seja o fuso do
            // servidor (ex.: servidor em UTC -> 03:00 / 03:30). O fuso do PHP deve ser o do sistema.
            $local = new DateTime('today 00:00', new DateTimeZone('America/Sao_Paulo'));
            $local->setTimezone(new DateTimeZone(date_default_timezone_get()));
            $h     = (int) $local->format('G');
            $m     = (int) $local->format('i');
            $half  = (clone $local)->modify('+30 minutes');
            $lines = [
                'backup' => $m . ' ' . $h . ' * * * php /var/www/html/mbilling/cron.php RecurringCredit backup',
                'refill' => (int) $half->format('i') . ' ' . (int) $half->format('G') . ' * * * php /var/www/html/mbilling/cron.php RecurringCredit',
            ];
            $cron = file_get_contents($cronPath);
            $out  = [];
            foreach (preg_split('/\r?\n/', rtrim($cron, "\n")) as $row) {
                // remove linhas RecurringCredit com horario antigo (sao recolocadas abaixo)
                if (! preg_match('/^\s*#/', $row) && preg_match('/cron\.php RecurringCredit(\s+backup)?\s*$/', $row)
                    && ! in_array(trim($row), $lines, true)) {
                    $this->log('Crontab: removida linha antiga: ' . trim($row));
                    continue;
                }
                $out[] = $row;
            }
            foreach ($lines as $line) {
                if (! in_array($line, array_map('trim', $out), true)) {
                    $out[] = $line;
                    $this->log('Crontab: ' . $line);
                }
            }
            $new = implode("\n", $out) . "\n";
            if ($new !== $cron) {
                file_put_contents($cronPath, $new);
            }
            $this->log('Rotina agendada para 00:00 e 00:30 de Brasilia (' . sprintf('%02d:%02d', $h, $m)
                . ' no fuso do servidor, ' . date_default_timezone_get() . ').');
        } else {
            $this->log('Crontab do root nao encontrado. Adicione manualmente as linhas RecurringCredit.');
        }

        $this->log('Concluido.');
    }

    private function execute($sql, $params = [])
    {
        return Yii::app()->db->createCommand($sql)->execute($params);
    }

    private function columnExists($table, $column)
    {
        return (int) Yii::app()->db->createCommand(
            'SELECT COUNT(*) FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = :t AND COLUMN_NAME = :c'
        )->queryScalar([':t' => $table, ':c' => $column]) > 0;
    }

    private function indexExists($table, $index)
    {
        return (int) Yii::app()->db->createCommand(
            'SELECT COUNT(*) FROM information_schema.STATISTICS
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = :t AND INDEX_NAME = :i'
        )->queryScalar([':t' => $table, ':i' => $index]) > 0;
    }

    private function log($message)
    {
        echo '[PlanConsumptionSetup] ' . $message . PHP_EOL;
    }
}
