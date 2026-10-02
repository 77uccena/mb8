<?php

/**
 * Recarga mensal do "Valor recorrente" - roda no dia configurado (padrao dia 20).
 *
 * Duas etapas, em horarios separados para dar tempo habil de conferencia:
 *
 *   00:00  php cron.php RecurringCredit backup
 *          BACKUP DE SEGURANCA: grava o saldo de TODOS os usuarios dos grupos
 *          configurados (backup_saldo_antes_recarga_AAAAMM.csv) e envia ao financeiro.
 *          Nao altera nenhum saldo.
 *
 *   00:30  php cron.php RecurringCredit
 *          RECARGA: confere se o backup do dia existe (se nao existir, gera na hora,
 *          antes de recarregar; se nao conseguir gravar, nao recarrega ninguem).
 *          Para cada usuario ATIVO dos grupos configurados (padrao: grupo Cliente),
 *          com tipo de plano e valor recorrente > 0, COMPLETA o saldo ate o valor
 *          recorrente e registra em Faturamento > Recargas.
 *            saldo 30,00 / recorrente 49,90    -> recarga 19,90  -> saldo 49,90
 *            saldo 120,00 / recorrente 100,00  -> recarga 0,00 (so registra)
 *            saldo -150,45 / recorrente 100,00 -> recarga 250,45 -> saldo 100,00
 *          Cada recarga grava uma foto (pkg_recurring_credit: saldo antes, recarga).
 *          Depois envia ao financeiro o Relatorio_de_Recarga-DDMMAAAA.csv + o backup:
 *            Cliente;tipo de plano;valor recorrente;saldo;recarga;valor a pagar
 *          saldo = saldo no momento da recarga; valor a pagar = saldo negativo
 *          (Ilimitado: 0). Regras em PlanConsumption (as mesmas da tela Consumo por Plano).
 *
 * Configuracoes (Configuracoes > Configuracao):
 *   finance_email            e-mail(s) do financeiro (separe varios com ;); vazio = "Admin Email"
 *   recurring_credit_groups  IDs dos grupos que recebem a recarga (padrao 3 = Cliente)
 *   recurring_credit_day     dia do mes da rotina (1 a 28, padrao 20)
 *
 * Cron (diario; so age a partir do dia configurado e uma vez por mes por usuario):
 *   0 0 * * * php /var/www/html/mbilling/cron.php RecurringCredit backup
 *   30 0 * * * php /var/www/html/mbilling/cron.php RecurringCredit
 * Se o servidor estiver fora do ar no dia 20, as duas etapas rodam no dia seguinte,
 * mantendo o intervalo de 30 minutos. Cada recarga leva a marca [RC-AAAAMM].
 * Usuarios inativos/bloqueados sao ignorados ate serem reativados.
 * Os arquivos ficam em protected/runtime/recurring_credit/.
 *
 * Teste sem gravar nem enviar nada:
 *   php /var/www/html/mbilling/cron.php RecurringCredit dryrun
 */
class RecurringCreditCommand extends ConsoleCommand
{
    private $global = [];
    private $day    = 20;
    private $dir;

    public function run($args)
    {
        $mode   = isset($args[0]) ? strtolower($args[0]) : 'refill';
        $dryRun = $mode === 'dryrun';

        // garante as traducoes (pt_BR) nas descricoes das recargas geradas pelo cron
        $localeDir = dirname(__FILE__) . '/../../resources/locale/php';
        if (is_dir($localeDir) && Yii::app()->getComponent('coreMessages')) {
            Yii::app()->getComponent('coreMessages')->basePath = realpath($localeDir);
        }

        $config       = LoadConfig::getConfig();
        $this->global = isset($config['global']) ? $config['global'] : [];
        $this->dir    = Yii::app()->getRuntimePath() . '/recurring_credit';

        $day       = isset($this->global['recurring_credit_day']) ? (int) $this->global['recurring_credit_day'] : 20;
        $this->day = $day < 1 || $day > 28 ? 20 : $day;
        // dryrun funciona em qualquer dia (previsao do ciclo do mes); backup/recarga so a partir do dia
        if ((int) date('j') < $this->day && ! $dryRun) {
            $this->log('day ' . date('j') . ' < configured day ' . $this->day . ', nothing to do', $dryRun);
            return;
        }

        $groups = $this->groupIds(isset($this->global['recurring_credit_groups']) ? $this->global['recurring_credit_groups'] : '3');
        if (! count($groups)) {
            $this->log('no valid group configured in recurring_credit_groups', $dryRun);
            return;
        }
        $inGroups = implode(',', $groups); // somente inteiros (validado em groupIds)

        $month  = date('Ym');
        $marker = '[RC-' . $month . ']';
        $labels = PlanConsumption::planTypes();

        list($rows, $pending) = $this->loadRows($inGroups, $marker);
        if (! count($pending)) {
            $this->log('no user pending for ' . $month, $dryRun);
            return;
        }

        if ($dryRun) {
            echo "=== BACKUP (saldo antes da recarga)\n" . $this->buildBackupCsv($this->loadBackupUsers($inGroups), $rows) . "\n";
            echo "=== " . PlanConsumption::reportFileName() . " (recarga PREVISTA com o saldo de agora)\n"
                . PlanConsumption::routineCsv(PlanConsumption::cycleRows($month));
            return;
        }

        if ($mode === 'backup') {
            $this->runBackup($inGroups, $rows, $month);
            return;
        }

        $this->runRefill($inGroups, $rows, $pending, $month, $marker, $labels);
    }

    /** 00:00 - backup de seguranca, sem alterar saldos */
    private function runBackup($inGroups, $rows, $month)
    {
        if ($this->todayBackup($month)) {
            $this->log('backup already created today for ' . $month);
            return;
        }

        $file = $this->writeBackup($inGroups, $rows, $month);
        if ($file === false) {
            $this->sendMail(
                '[MagnusBilling] ERRO no backup de segurança da recarga ' . $this->monthLabel($month),
                '<p><b>Não foi possível gravar o backup de segurança.</b> A recarga das 00:30 vai tentar gerar o backup novamente e só recarrega se conseguir.</p>',
                []
            );
            return;
        }

        $this->sendMail(
            '[MagnusBilling] Backup de segurança - saldo antes da recarga ' . $this->monthLabel($month),
            '<p>Backup de segurança do saldo de todos os clientes, gerado em ' . date('d/m/Y H:i') . '.</p>'
            . '<p>A recarga recorrente será executada às 00:30. Nenhum saldo foi alterado até agora.</p>'
            . '<p>RECARGA PREVISTA = valor para completar o recorrente, calculado com o saldo deste momento.</p>',
            [$file => 'backup_saldo_antes_recarga_' . $month . '.csv']
        );
    }

    /** 00:30 - recarga + relatorio de rotina */
    private function runRefill($inGroups, $rows, $pending, $month, $marker, $labels)
    {
        $fileBackup = $this->todayBackup($month);
        $backupNote = '';
        if (! $fileBackup) {
            // o backup das 00:00 nao existe: gera agora, antes de qualquer recarga
            $fileBackup = $this->writeBackup($inGroups, $rows, $month);
            if ($fileBackup === false) {
                $this->log('ABORTED: unable to write backup. No refill was made.');
                $this->sendMail(
                    '[MagnusBilling] ERRO - recarga recorrente NÃO executada ' . $this->monthLabel($month),
                    '<p><b>O backup de segurança não pôde ser gravado, por isso nenhuma recarga foi feita.</b> Verifique o servidor; a rotina tenta de novo amanhã.</p>',
                    []
                );
                return;
            }
            $backupNote = '<li><b>O backup das 00:00 não foi encontrado; ele foi gerado agora, imediatamente antes da recarga.</b></li>';
        }

        $done    = 0;
        $total   = 0;
        $credits = 0;
        $debits  = 0;
        $errors  = [];
        foreach ($pending as $user) {
            $id     = (int) $user['id'];
            $result = $this->refillUser($user, $labels, $month, $marker);
            if ($result === false) {
                $errors[] = $user['username'];
            } elseif ($result !== null) {
                $done++;
                $total += $result['amount'];
                if ($result['amount'] > 0) {
                    $credits += $result['amount'];
                } else {
                    $debits += $result['amount'];
                }
            }
        }
        $this->log('RECURRING CREDIT ' . $month . ': ' . $done . ' refill(s), total ' . $total . ', errors: ' . count($errors));

        $reportName  = PlanConsumption::reportFileName();
        $fileFinal   = $this->dir . '/' . basename($reportName, '.csv') . '_' . date('His') . '.csv';
        $attachments = [];
        // relatorio de recarga: mesma regra da tela (PlanConsumption), com a foto desta recarga
        $report = PlanConsumption::routineCsv(PlanConsumption::cycleRows($month));
        if (@file_put_contents($fileFinal, $report) !== false) {
            $attachments[$fileFinal] = $reportName;
        } else {
            $this->log('unable to write ' . $fileFinal);
        }
        $attachments[$fileBackup] = 'backup_saldo_antes_recarga_' . $month . '.csv';

        $this->sendMail(
            '[MagnusBilling] Relatório da recarga recorrente ' . $this->monthLabel($month),
            '<p>Relatório da recarga recorrente de ' . $this->monthLabel($month) . ', executada em ' . date('d/m/Y H:i') . '.</p>'
            . '<ul>'
            . '<li>Clientes processados: ' . $done . '</li>'
            . '<li>Total recarregado: R$ ' . PlanConsumption::money($total) . '</li>'
            . $backupNote
            . (count($errors) ? '<li><b>Falha na recarga: ' . CHtml::encode(implode(', ', $errors)) . '</b></li>' : '')
            . '</ul>'
            . '<p>Anexos:</p><ul>'
            . '<li><b>' . $reportName . '</b> - relatório de recarga (valor a pagar de cada cliente).</li>'
            . '<li><b>backup_saldo_antes_recarga_' . $month . '.csv</b> - backup do saldo de todos os clientes antes da recarga.</li>'
            . '</ul>'
            . '<p><b>saldo</b> = saldo do cliente no momento da recarga (o mês começa com o valor recorrente e as ligações vão descontando). '
            . '<b>recarga</b> = valor para o saldo voltar ao valor recorrente (saldo negativo: recorrente + saldo devedor; saldo igual ou acima do recorrente: 0). '
            . '<b>valor a pagar</b> = quanto o saldo ficou negativo (Plano de Minutos e Franquia; Ilimitado não paga). '
            . 'O valor recorrente já é cobrado todo mês e aparece só para explicar o cálculo.</p>',
            $attachments
        );
    }

    /** @return array [rows por id, usuarios pendentes de recarga] */
    private function loadRows($inGroups, $marker)
    {
        $users = Yii::app()->db->createCommand(
            "SELECT u.id, u.username, u.active, u.credit, u.plan_type, u.recurring_value,
                    (SELECT COUNT(*) FROM pkg_refill r WHERE r.id_user = u.id AND r.description LIKE :marker) AS done
             FROM pkg_user u
             WHERE u.id_group IN ($inGroups)
               AND u.plan_type IN ('unlimited','franchise','minutes')
             ORDER BY FIELD(u.plan_type, 'franchise', 'minutes', 'unlimited'), u.username"
        )->queryAll(true, [':marker' => '%' . $marker . '%']);

        $rows    = [];
        $pending = [];
        foreach ($users as $user) {
            $eligible = (int) $user['active'] === 1
                && (float) $user['recurring_value'] > 0
                && (int) $user['done'] === 0;
            $id = (int) $user['id'];
            $rows[$id] = [
                'username'        => $user['username'],
                'plan_type'       => $user['plan_type'],
                'recurring_value' => PlanConsumption::num($user['recurring_value']),
                'credit_before'   => PlanConsumption::num($user['credit']),
                'refill'          => $eligible ? PlanConsumption::refillAmount($user['recurring_value'], $user['credit']) : 0,
            ];
            if ($eligible) {
                $pending[] = $user;
            }
        }
        return [$rows, $pending];
    }

    private function loadBackupUsers($inGroups)
    {
        return Yii::app()->db->createCommand(
            "SELECT u.id, u.username, u.firstname, u.lastname, u.company_name, u.active, u.typepaid,
                    u.creditlimit, u.credit, u.plan_type, u.recurring_value, g.name AS group_name
             FROM pkg_user u
             JOIN pkg_group_user g ON g.id = u.id_group
             WHERE u.id_group IN ($inGroups)
             ORDER BY u.username"
        )->queryAll();
    }

    /** @return string|false caminho do arquivo gravado */
    private function writeBackup($inGroups, $rows, $month)
    {
        $file = $this->dir . '/backup_saldo_antes_recarga_' . $month . '_' . date('Ymd-His') . '.csv';
        if ((! is_dir($this->dir) && ! @mkdir($this->dir, 0750, true))
            || @file_put_contents($file, $this->buildBackupCsv($this->loadBackupUsers($inGroups), $rows)) === false) {
            $this->log('unable to write backup ' . $file);
            return false;
        }
        $this->log('backup written ' . $file);
        return $file;
    }

    /** backup gerado hoje para o mes (o mais recente), ou false */
    private function todayBackup($month)
    {
        $files = glob($this->dir . '/backup_saldo_antes_recarga_' . $month . '_' . date('Ymd') . '-*.csv');
        if (! $files) {
            return false;
        }
        sort($files);
        return end($files);
    }

    private function sendMail($subject, $html, array $attachments)
    {
        $to = FinanceReportMailer::parseAddresses(isset($this->global['finance_email']) ? $this->global['finance_email'] : '');
        if (! count($to)) {
            $to = FinanceReportMailer::parseAddresses(isset($this->global['admin_email']) ? $this->global['admin_email'] : '');
        }
        $sent = FinanceReportMailer::send($to, $subject, $html, $attachments);
        $this->log($sent === true
            ? 'email "' . $subject . '" sent to ' . implode(', ', $to)
            : 'EMAIL NOT SENT "' . $subject . '" (' . $sent . '). Files kept in ' . $this->dir);
    }

    private function monthLabel($month)
    {
        return substr($month, 4, 2) . '/' . substr($month, 0, 4);
    }

    /** @return array|null|false ['amount','before'], null se ja recarregado, false em erro */
    private function refillUser($user, $labels, $month, $marker)
    {
        $idUser = (int) $user['id'];
        $tx     = Yii::app()->db->beginTransaction();
        try {
            // trava a linha e confere de novo (evita recarga dupla com execucoes simultaneas)
            $credit = (float) Yii::app()->db->createCommand(
                'SELECT credit FROM pkg_user WHERE id = :id FOR UPDATE'
            )->queryScalar([':id' => $idUser]);

            if (Refill::model()->count(
                'id_user = :id AND description LIKE :marker',
                [':id' => $idUser, ':marker' => '%' . $marker . '%']
            ) > 0) {
                $tx->rollback();
                return null;
            }

            $recurring = PlanConsumption::num($user['recurring_value']);
            $amount    = PlanConsumption::refillAmount($recurring, $credit);

            $description = Yii::t('zii', 'Recurring credit') . ' ' . substr($month, 4, 2) . '/' . substr($month, 0, 4)
                . ' - ' . $labels[$user['plan_type']]
                . ' (' . Yii::t('zii', 'Recurring value') . ' ' . PlanConsumption::money($recurring) . ') '
                . $marker;

            $refill              = new Refill;
            $refill->id_user     = $idUser;
            $refill->date        = date('Y-m-d H:i:s'); // mesmo relogio da rotina (consumo "desde a ultima recarga")
            $refill->credit      = $amount;
            $refill->description = $description;
            $refill->payment     = 1;
            if (! $refill->save()) {
                throw new RuntimeException(json_encode($refill->getErrors()));
            }

            // foto da recarga: base do relatorio (saldo antes da recarga)
            Yii::app()->db->createCommand(
                'INSERT INTO pkg_recurring_credit (id_user, month, plan_type, recurring_value, credit_before, refill, id_refill, date)
                 VALUES (:id, :month, :plan, :rec, :before, :refill, :id_refill, :date)'
            )->execute([
                ':id'        => $idUser,
                ':month'     => $month,
                ':plan'      => $user['plan_type'],
                ':rec'       => $recurring,
                ':before'    => PlanConsumption::num($credit),
                ':refill'    => $amount,
                ':id_refill' => $refill->id ? (int) $refill->id : null,
                ':date'      => $refill->date,
            ]);

            if ($amount != 0) {
                // atualizacao atomica: nao sobrescreve debitos de chamadas em andamento
                Yii::app()->db->createCommand(
                    'UPDATE pkg_user SET credit = credit + :amount WHERE id = :id'
                )->execute([':amount' => $amount, ':id' => $idUser]);
            }

            $tx->commit();
        } catch (Exception $e) {
            $tx->rollback();
            $this->log('RECURRING CREDIT ERROR user ' . $idUser . ': ' . $e->getMessage());
            return false;
        }

        if ($amount > 0) {
            try {
                $mail = new Mail(Mail::$TYPE_REFILL, $idUser);
                $mail->replaceInEmail(Mail::$ITEM_ID_KEY, $refill->id);
                $mail->replaceInEmail(Mail::$ITEM_AMOUNT_KEY, $amount);
                $mail->replaceInEmail(Mail::$DESCRIPTION, $description);
                $mail->send();
            } catch (Exception $e) {
                $this->log('RECURRING CREDIT MAIL ERROR user ' . $idUser . ': ' . $e->getMessage());
            }
            ServicesProcess::checkIfServiceToPayAfterRefill($idUser);
        }

        return ['amount' => $amount, 'before' => PlanConsumption::num($credit)];
    }

    /**
     * Backup: saldo de todos os usuarios dos grupos antes da recarga.
     * CLIENTE;NOME;GRUPO;STATUS;TIPO DE PAGAMENTO;LIMITE DE CRÉDITO;TIPO DE PLANO;VALOR RECORRENTE;SALDO ANTES DA RECARGA;RECARGA PREVISTA
     */
    private function buildBackupCsv(array $users, array $rows)
    {
        $labels = PlanConsumption::planTypes();
        $status = [0 => 'Inativo', 1 => 'Ativo', 2 => 'Pendente', 3 => 'Bloqueado entrada', 4 => 'Bloqueado entrada/saída'];
        $m      = function ($v) {
            return PlanConsumption::money($v);
        };

        $csv = "\xEF\xBB\xBF" . $this->csvLine(['CLIENTE', 'NOME', 'GRUPO', 'STATUS', 'TIPO DE PAGAMENTO', 'LIMITE DE CRÉDITO',
            'TIPO DE PLANO', 'VALOR RECORRENTE', 'SALDO ANTES DA RECARGA', 'RECARGA PREVISTA']);
        $sumCredit = 0;
        $sumRefill = 0;
        foreach ($users as $u) {
            $id   = (int) $u['id'];
            $name = PlanConsumption::customerName($u['firstname'], $u['lastname'], $u['company_name']);
            $refill     = isset($rows[$id]) ? $rows[$id]['refill'] : 0;
            $sumCredit += (float) $u['credit'];
            $sumRefill += $refill;
            $csv .= $this->csvLine([
                $u['username'],
                $name,
                $u['group_name'],
                isset($status[(int) $u['active']]) ? $status[(int) $u['active']] : $u['active'],
                (int) $u['typepaid'] === 1 ? 'Pós-pago' : 'Pré-pago',
                $m($u['creditlimit']),
                isset($labels[$u['plan_type']]) ? $labels[$u['plan_type']] : '',
                $m($u['recurring_value']),
                $m($u['credit']),
                $m($refill),
            ]);
        }
        $csv .= $this->csvLine(['TOTAL', '', '', '', '', '', '', '', $m($sumCredit), $m($sumRefill)]);
        return $csv;
    }

    private function csvLine(array $cols)
    {
        foreach ($cols as $k => $c) {
            $c = (string) $c;
            if (strpbrk($c, ";\"\r\n") !== false) {
                $c = '"' . str_replace('"', '""', $c) . '"';
            }
            $cols[$k] = $c;
        }
        return implode(';', $cols) . "\r\n";
    }

    /** "3, 5;7" -> [3,5,7] */
    private function groupIds($value)
    {
        $ids = [];
        foreach (preg_split('/[;,\s]+/', (string) $value) as $id) {
            if (ctype_digit($id) && (int) $id > 0) {
                $ids[] = (int) $id;
            }
        }
        return array_values(array_unique($ids));
    }

    private function log($message, $echo = false)
    {
        if ($echo) {
            echo $message . "\n";
        }
        MagnusLog::writeLog(LOGFILE, ' line:' . __LINE__ . ' ' . $message);
    }
}
