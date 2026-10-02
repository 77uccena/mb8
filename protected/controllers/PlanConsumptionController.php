<?php

/**
 * Relatorio "Consumo por plano".
 *
 * Lista, por ciclo de recarga (mes AAAA-MM), os clientes dos grupos da recarga recorrente
 * com tipo de plano: valor recorrente, consumo (saldo na recarga), recarga e valor a pagar.
 * Regras em PlanConsumption (as mesmas do Relatorio_de_Recarga enviado no dia 20).
 *
 * Somente leitura. Parametros aceitos (GET):
 *   month      YYYY-MM  (padrao: mes atual)
 *   plan_type  unlimited | franchise | minutes | vazio (todos)
 *   username   filtro parcial por usuario ou nome
 *
 * Os filtros genericos da grade (?filter=) NAO sao usados aqui de proposito:
 * o BaseController registra campos desconhecidos como tentativa de SQL inject.
 */
class PlanConsumptionController extends Controller
{
    public $attributeOrder = 'plan_type ASC';

    public function init()
    {
        $this->instanceModel = new PlanConsumption;
        $this->abstractModel = PlanConsumption::model();
        $this->titleReport   = Yii::t('zii', 'Consumption per Plan');
        parent::init();
    }

    private function checkRead()
    {
        if (! Yii::app()->session['isAdmin']
            || ! AccessManager::getInstance($this->instanceModel->getModule())->canRead()) {
            header('HTTP/1.0 401 Unauthorized');
            $this->sendError('Access denied for module "{module}".', ['{module}' => $this->instanceModel->getModule()]);
        }
    }

    /** @return array [month YYYYMM, plan_type, username] validados */
    private function readParams()
    {
        $month = isset($_GET['month']) ? trim($_GET['month']) : '';
        if ($month === '') {
            // padrao: ciclo do mes atual a partir do dia da rotina; antes disso, o ciclo anterior
            $month = (int) date('j') >= PlanConsumption::configDay()
                ? date('Y-m')
                : date('Y-m', strtotime(date('Y-m-01') . ' -1 month'));
        }
        if (! preg_match('/^(\d{4})-(0[1-9]|1[0-2])$/', $month, $m)) {
            $this->sendError('Invalid request parameters. Check the submitted values.', [], 400);
        }

        $planType = isset($_GET['plan_type']) ? trim($_GET['plan_type']) : '';
        if ($planType !== '' && ! array_key_exists($planType, PlanConsumption::planTypes())) {
            $this->sendError('Invalid request parameters. Check the submitted values.', [], 400);
        }

        $username = isset($_GET['username']) ? trim($_GET['username']) : '';
        if ($username !== '' && ! preg_match('/^[\p{L}\p{N} _.@-]{1,50}$/u', $username)) {
            $this->sendError('Invalid request parameters. Check the submitted values.', [], 400);
        }

        return [$m[1] . $m[2], $planType, $username];
    }

    private function limitGroup()
    {
        if (Yii::app()->session['user_type'] == 1 && Yii::app()->session['adminLimitUsers'] == true) {
            return (int) Yii::app()->session['id_group'];
        }
        return 0;
    }

    public function actionRead($asJson = true, $condition = null)
    {
        $this->checkRead();
        list($month, $planType, $username) = $this->readParams();

        $rows = array_values(PlanConsumption::cycleRows($month, $planType, $username, $this->limitGroup()));

        header('Content-Type: application/json; charset=utf-8');
        echo json_encode([
            $this->nameRoot  => $rows,
            $this->nameCount => count($rows),
            $this->nameSum   => [],
        ]);
    }

    public function actionCsv()
    {
        $this->checkRead();
        list($month, $planType, $username) = $this->readParams();

        MagnusLog::insertLOG(7, 'User export CSV planconsumption ' . $month);

        $rows = PlanConsumption::cycleRows($month, $planType, $username, $this->limitGroup());

        $csv = PlanConsumption::routineCsv($rows);

        header('Content-Type: text/csv; charset=utf-8');
        header('Content-Disposition: attachment; filename="Relatorio_de_Recarga-ciclo-' . substr($month, 4, 2) . substr($month, 0, 4) . '.csv"');
        echo $csv;
    }

    // Relatorio somente leitura.
    public function actionSave()
    {
        $this->sendError('Disallowed action', [], 403);
    }

    public function actionDestroy()
    {
        $this->sendError('Disallowed action', [], 403);
    }

    public function actionReport()
    {
        $this->sendError('Disallowed action', [], 403);
    }

    public function actionDestroyReport()
    {
        $this->sendError('Disallowed action', [], 403);
    }

    public function actionImportFromCsv()
    {
        $this->sendError('Disallowed action', [], 403);
    }
}
