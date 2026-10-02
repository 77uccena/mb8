<?php

/**
 * Relatorio de Recarga ("Consumo por Plano") - regra unica usada pela TELA e pela ROTINA do dia 20.
 *
 * Uma linha por cliente (grupos configurados em "Grupos da recarga recorrente", com tipo de plano):
 *
 *   Cliente;tipo de plano;valor recorrente;saldo;recarga;valor a pagar
 *
 *   saldo          = saldo do cliente no momento da recarga. O ciclo comeca com o saldo cheio
 *                    (valor recorrente) e as ligacoes vao descontando; pode ficar negativo.
 *   recarga        = saldo >= 0: max(0, recorrente - saldo)   (saldo acima do recorrente: 0)
 *                    saldo <  0: recorrente + |saldo|
 *                    (as duas formas = max(0, recorrente - saldo))
 *   valor a pagar  = Plano de Minutos / Franquia: quanto o saldo ficou negativo (0 se positivo).
 *                    Ilimitado: sempre 0.
 *   O valor recorrente e cobrado a parte todo mes; aparece so para explicar o calculo.
 *
 * Valores exatos: o saldo tem 4 casas no banco; a recarga usa o valor exato (o saldo volta
 * exatamente ao recorrente) e o relatorio mostra 2 casas, ou ate 4 quando houver.
 *
 * Origem dos dados do ciclo AAAAMM:
 *   - recarga feita: foto gravada no momento da recarga (pkg_recurring_credit);
 *     recargas antigas sem foto: saldo = recorrente - recarga (ou o "saldo antigo" da descricao).
 *   - ciclo atual/futuro sem recarga: previsao com o saldo de agora.
 */
class PlanConsumption extends Model
{
    protected $_module = 'planconsumption';

    const TYPE_UNLIMITED = 'unlimited';
    const TYPE_FRANCHISE = 'franchise';
    const TYPE_MINUTES   = 'minutes';

    const ROUTINE_HEADER = ['Cliente', 'tipo de plano', 'valor recorrente', 'saldo', 'recarga', 'valor a pagar'];

    public static function model($className = __CLASS__)
    {
        return parent::model($className);
    }

    public function tableName()
    {
        return 'pkg_user';
    }

    public function primaryKey()
    {
        return 'id';
    }

    public function rules()
    {
        return [];
    }

    public static function planTypes()
    {
        return [
            self::TYPE_FRANCHISE => 'Plano de Franquia',
            self::TYPE_MINUTES   => 'Plano de Minutos',
            self::TYPE_UNLIMITED => 'Plano Ilimitado',
        ];
    }

    /** Dia configurado da rotina (1 a 28, padrao 20). */
    public static function configDay()
    {
        $day = (int) Yii::app()->db->createCommand(
            "SELECT config_value FROM pkg_configuration WHERE config_key = 'recurring_credit_day'"
        )->queryScalar();
        return $day >= 1 && $day <= 28 ? $day : 20;
    }

    /** IDs dos grupos da recarga recorrente (padrao 3). */
    public static function configGroups()
    {
        $value = Yii::app()->db->createCommand(
            "SELECT config_value FROM pkg_configuration WHERE config_key = 'recurring_credit_groups'"
        )->queryScalar();
        $ids = [];
        foreach (preg_split('/[;,\s]+/', (string) ($value === false ? '3' : $value)) as $id) {
            if (ctype_digit($id) && (int) $id > 0) {
                $ids[] = (int) $id;
            }
        }
        return array_values(array_unique($ids));
    }

    /** Valor com 4 casas (precisao do saldo no banco). */
    public static function num($value)
    {
        $v = round((float) $value, 4);
        return $v == 0 ? 0.0 : $v;
    }

    /** Recarga para o saldo voltar ao valor recorrente (0 se o saldo ja estava igual ou acima). */
    public static function refillAmount($recurring, $balance)
    {
        return self::num(max(0, self::num($recurring) - self::num($balance)));
    }

    /** Aplica as regras a partir do tipo de plano, recorrente, saldo na recarga e recarga. */
    public static function computeRow($planType, $recurring, $balance, $refill)
    {
        $recurring = self::num($recurring);
        $balance   = self::num($balance);

        return [
            'recurring_value' => $recurring,
            'consumption'     => $balance,
            'spent'           => self::num($recurring - $balance),
            'refill'          => self::num($refill),
            'amount_due'      => $planType === self::TYPE_UNLIMITED ? 0.0 : self::num(max(0, -$balance)),
        ];
    }

    /** "... , Old credit -271.4" -> -271.4 (recargas antigas, sem foto) */
    private static function balanceFromDescription($description)
    {
        return preg_match('/(-?\d+(?:\.\d+)?)\s*$/', (string) $description, $m) ? (float) $m[1] : null;
    }

    /**
     * Linhas do relatorio do ciclo AAAAMM, indexadas pelo id do usuario.
     * status: done (recarregado) | planned (previsao) | skipped (inativo/bloqueado ou recorrente 0)
     */
    public static function cycleRows($month, $planType = '', $username = '', $limitGroup = 0)
    {
        $groups = self::configGroups();
        if (! count($groups)) {
            return [];
        }

        $params = [];
        $where  = "u.plan_type IN ('unlimited','franchise','minutes') AND u.id_group IN (" . implode(',', $groups) . ')';

        if ($planType !== '') {
            $where .= ' AND u.plan_type = :plan_type';
            $params[':plan_type'] = $planType;
        }
        if ($username !== '') {
            $where .= ' AND (u.username LIKE :u1 OR u.firstname LIKE :u2 OR u.lastname LIKE :u3 OR u.company_name LIKE :u4)';
            foreach ([':u1', ':u2', ':u3', ':u4'] as $k) {
                $params[$k] = '%' . $username . '%';
            }
        }
        if ($limitGroup > 0) {
            $where .= ' AND u.id_group IN (SELECT gug.id_group FROM pkg_group_user_group gug WHERE gug.id_group_user = :idgA0)';
            $params[':idgA0'] = (int) $limitGroup;
        }

        $users = Yii::app()->db->createCommand(
            "SELECT u.id, u.username, u.firstname, u.lastname, u.company_name, u.active,
                    u.credit, u.plan_type, u.recurring_value
             FROM pkg_user u
             WHERE $where"
        )->queryAll(true, $params);

        $snap = [];
        foreach (Yii::app()->db->createCommand(
            'SELECT id_user, plan_type, recurring_value, credit_before, refill FROM pkg_recurring_credit WHERE month = :m'
        )->queryAll(true, [':m' => $month]) as $r) {
            $snap[(int) $r['id_user']] = $r;
        }

        $legacy = [];
        foreach (Yii::app()->db->createCommand(
            'SELECT id_user, SUM(credit) AS credit, MIN(description) AS description
             FROM pkg_refill WHERE description LIKE :m GROUP BY id_user'
        )->queryAll(true, [':m' => '%[RC-' . $month . ']%']) as $r) {
            $legacy[(int) $r['id_user']] = $r;
        }

        $live   = strcmp($month, date('Ym')) >= 0; // previsao so no ciclo atual/futuro
        $labels = self::planTypes();
        $rows   = [];

        foreach ($users as $u) {
            $id   = (int) $u['id'];
            $plan = $u['plan_type'];
            $rec  = $u['recurring_value'];

            if (isset($snap[$id])) {
                $plan    = $snap[$id]['plan_type'];
                $rec     = $snap[$id]['recurring_value'];
                $balance = $snap[$id]['credit_before'];
                $refill  = $snap[$id]['refill'];
                $status  = 'done';
            } elseif (isset($legacy[$id])) {
                $refill  = $legacy[$id]['credit'];
                $old     = self::balanceFromDescription($legacy[$id]['description']);
                $balance = (float) $refill != 0 ? self::num($rec - $refill) : ($old !== null ? $old : $rec);
                $status  = 'done';
            } elseif ($live) {
                $balance  = $u['credit'];
                $eligible = (int) $u['active'] === 1 && (float) $rec > 0;
                $refill   = $eligible ? self::refillAmount($rec, $balance) : 0;
                $status   = $eligible ? 'planned' : 'skipped';
            } else {
                continue; // ciclo passado sem recarga registrada para o cliente
            }

            $name = self::customerName($u['firstname'], $u['lastname'], $u['company_name']);

            $rows[$id] = [
                'id'              => $id,
                'username'        => $u['username'],
                'name'            => $name,
                'customer'        => $name !== '' ? $name : $u['username'],
                'active'          => (int) $u['active'],
                'plan_type'       => $plan,
                'plan_type_label' => isset($labels[$plan]) ? $labels[$plan] : $plan,
                'status'          => $status,
            ] + self::computeRow($plan, $rec, $balance, $refill);
        }

        $order = [self::TYPE_FRANCHISE => 1, self::TYPE_MINUTES => 2, self::TYPE_UNLIMITED => 3];
        uasort($rows, function ($a, $b) use ($order) {
            $pa = isset($order[$a['plan_type']]) ? $order[$a['plan_type']] : 9;
            $pb = isset($order[$b['plan_type']]) ? $order[$b['plan_type']] : 9;
            return $pa !== $pb ? $pa - $pb : strcasecmp($a['customer'] . $a['username'], $b['customer'] . $b['username']);
        });

        return $rows;
    }

    /**
     * Nome do cliente no relatorio: nome + sobrenome; sem nome, a empresa.
     * Espacos repetidos, TAB e quebras de linha do cadastro viram um espaco so.
     */
    public static function customerName($firstname, $lastname, $company = '')
    {
        $clean = function ($v) {
            return trim(preg_replace('/[\s\x{00A0}]+/u', ' ', (string) $v));
        };
        $name = $clean($firstname . ' ' . $lastname);
        return $name !== '' ? $name : $clean($company);
    }

    /** 2 casas, ou ate 4 quando o valor tiver mais casas (financeiro: valor exato). Ex.: 271,40 / 0,1234 */
    public static function money($value)
    {
        $s = number_format(self::num($value), 4, ',', '');
        return preg_replace('/(,\d{2}\d*?)0+$/', '$1', $s);
    }

    private static function csvLine(array $cols)
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

    /**
     * Relatorio de Recarga (e-mail do dia 20 e exportacao da tela): 6 colunas, uma linha por
     * cliente, sem linha de total. UTF-8 com BOM, separador ";", CRLF.
     */
    public static function routineCsv(array $rows)
    {
        $m   = function ($v) { return PlanConsumption::money($v); };
        $csv = "\xEF\xBB\xBF" . self::csvLine(self::ROUTINE_HEADER);
        foreach ($rows as $r) {
            $csv .= self::csvLine([
                $r['customer'], $r['plan_type_label'], $m($r['recurring_value']),
                $m($r['consumption']), $m($r['refill']), $m($r['amount_due']),
            ]);
        }
        return $csv;
    }

    /** Nome do arquivo do relatorio: Relatorio_de_Recarga-DDMMAAAA.csv */
    public static function reportFileName($timestamp = null)
    {
        return 'Relatorio_de_Recarga-' . date('dmY', $timestamp ?: time()) . '.csv';
    }
}
