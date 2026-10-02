/**
 * MB8 customizado - carregado pelo index.html depois do app.js pre-compilado.
 * Nao precisa recompilar o frontend (Sencha).
 *
 *  - Clientes > Usuarios: campos "Tipo de plano" e "Valor recorrente" (aba Geral)
 *    e colunas opcionais na lista.
 *  - Relatorios > Consumo por Plano (modulo "planconsumption").
 */
(function () {
    var tries = 0;

    function baseReady() {
        return window.Ext && Ext.isReady && Ext.ClassManager &&
            Ext.ClassManager.get('Ext.ux.panel.Module') &&
            Ext.ClassManager.get('Ext.ux.grid.Panel') &&
            Ext.ClassManager.get('Ext.ux.form.Panel') &&
            Ext.ClassManager.get('Ext.ux.app.ViewController') &&
            window.Helper && Helper.Util && window.App && App.user;
    }

    function boot() {
        if (window.__mb8CustomInstalled) {
            return;
        }
        if (!baseReady()) {
            if (++tries < 600) { // ate ~2 minutos (aguarda o login)
                setTimeout(boot, 200);
            } else if (window.console) {
                console.error('[mb8-custom] Ext/App nao disponivel; customizacoes nao carregadas.');
            }
            return;
        }
        window.__mb8CustomInstalled = true;
        try {
            install();
            if (window.console) console.info('[mb8-custom] customizacoes carregadas.');
        } catch (e) {
            if (window.console) console.error('[mb8-custom] erro ao carregar:', e);
        }
    }

    function planTypeStore() {
        return [
            ['', t('Not defined')],
            ['unlimited', t('Unlimited')],
            ['franchise', t('Franchise')],
            ['minutes', t('Minutes')]
        ];
    }

    function install() {
        // ---------- helper
        Helper.Util.formatPlanType = function (value) {
            var labels = {
                unlimited: t('Unlimited'),
                franchise: t('Franchise'),
                minutes: t('Minutes')
            };
            return labels[value] || '';
        };

        // valor exato para o financeiro: 2 casas, ou ate 4 quando houver (ex.: R$ -271,40 / R$ 0,1234)
        Helper.Util.formatExactMoney = function (value) {
            var v = Math.round((Number(value) || 0) * 10000) / 10000,
                parts = Math.abs(v).toFixed(4).replace(/(\.\d{2}\d*?)0+$/, '$1').split('.');
            parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, '.');
            return (window.App && App.user && App.user.currency ? App.user.currency + ' ' : '') +
                (v < 0 ? '-' : '') + parts.join(',');
        };

        // ---------- model User: campos novos
        var UserModel = Ext.ClassManager.get('MBilling.model.User');
        if (UserModel && Ext.isFunction(UserModel.addFields)) {
            try {
                UserModel.addFields([{
                    name: 'plan_type',
                    type: 'string'
                }, {
                    name: 'recurring_value',
                    type: 'number'
                }]);
            } catch (e) {
                if (window.console) console.warn('[mb8-custom] addFields:', e);
            }
        }

        // ---------- formulario do usuario: campos na aba Geral, depois de "Plano"
        if (Ext.ClassManager.get('MBilling.view.user.Form')) {
            Ext.define('MB8Custom.override.UserForm', {
                override: 'MBilling.view.user.Form',
                initComponent: function () {
                    this.callParent(arguments);
                    try {
                        var tab = this.down('#mainData');
                        if (!tab || tab.down('[name=plan_type]')) {
                            return;
                        }
                        var ref = tab.down('[name=id_plan]'),
                            idx = ref ? tab.items.indexOf(ref) + 1 : tab.items.getCount();
                        tab.insert(idx, [{
                            xtype: 'combo',
                            name: 'plan_type',
                            fieldLabel: t('Plan type'),
                            forceSelection: true,
                            editable: false,
                            allowBlank: true,
                            value: '',
                            store: planTypeStore(),
                            hidden: !App.user.isAdmin
                        }, {
                            xtype: 'moneyfield',
                            name: 'recurring_value',
                            fieldLabel: t('Recurring value'),
                            mask: App.user.currency + ' #9.999.990,00',
                            value: 0,
                            allowBlank: true,
                            hidden: !App.user.isAdmin
                        }]);
                    } catch (e) {
                        if (window.console) console.error('[mb8-custom] user form:', e);
                    }
                }
            });
        }

        // ---------- lista de usuarios: colunas opcionais (ocultas por padrao)
        if (Ext.ClassManager.get('MBilling.view.user.List')) {
            Ext.define('MB8Custom.override.UserList', {
                override: 'MBilling.view.user.List',
                initComponent: function () {
                    this.callParent(arguments);
                    if (!App.user.isAdmin) {
                        return;
                    }
                    try {
                        var header = this.headerCt,
                            idx = header.items.findIndex('dataIndex', 'id_plan');
                        idx = idx >= 0 ? idx + 1 : header.items.getCount();
                        header.insert(idx, [{
                            header: t('Plan type'),
                            dataIndex: 'plan_type',
                            renderer: Helper.Util.formatPlanType,
                            hidden: true,
                            flex: 2
                        }, {
                            header: t('Recurring value'),
                            dataIndex: 'recurring_value',
                            renderer: Helper.Util.formatMoneyDecimal,
                            hidden: true,
                            flex: 2
                        }]);
                    } catch (e) {
                        if (window.console) console.error('[mb8-custom] user list:', e);
                    }
                }
            });
        }

        // ---------- relatorio "Consumo por Plano"
        // ---- app/model/PlanConsumption.js
        Ext.define('MBilling.model.PlanConsumption', {
            extend: 'Ext.data.Model',
            fields: [{
                name: 'id',
                type: 'int'
            }, {
                name: 'username',
                type: 'string'
            }, {
                name: 'name',
                type: 'string'
            }, {
                name: 'customer',
                type: 'string'
            }, {
                name: 'active',
                type: 'int'
            }, {
                name: 'plan_type',
                type: 'string'
            }, {
                name: 'plan_type_label',
                type: 'string'
            }, {
                name: 'status',
                type: 'string'
            }, {
                name: 'recurring_value',
                type: 'float'
            }, {
                name: 'consumption',
                type: 'float'
            }, {
                name: 'spent',
                type: 'float'
            }, {
                name: 'refill',
                type: 'float'
            }, {
                name: 'amount_due',
                type: 'float'
            }],
            proxy: {
                type: 'uxproxy',
                module: 'planConsumption'
            }
        });

        // ---- app/store/PlanConsumption.js
        Ext.define('MBilling.store.PlanConsumption', {
            extend: 'Ext.data.Store',
            model: 'MBilling.model.PlanConsumption',
            remoteSort: false,
            remoteFilter: false,
            pageSize: 0,
            groupField: 'plan_type_label'
        });

        // ---- classic/src/view/planConsumption/Controller.js
        Ext.define('MBilling.view.planConsumption.Controller', {
            extend: 'Ext.ux.app.ViewController',
            alias: 'controller.planconsumption',
            onRenderModule: function () {
                var me = this;
                me.callParent(arguments);
                me.store.on('load', me.updateTotals, me);
                if (me.store.isLoaded()) {
                    me.updateTotals();
                }
            },
            onDestroyModule: function () {
                var me = this;
                me.store && me.store.un('load', me.updateTotals, me);
                me.callParent(arguments);
            },
            getFilterParams: function () {
                var me = this,
                    month = me.lookupReference('pcMonth'),
                    planType = me.lookupReference('pcPlanType'),
                    username = me.lookupReference('pcUsername');
                return {
                    month: month ? month.getValue() : '',
                    plan_type: planType ? (planType.getValue() || '') : '',
                    username: username ? Ext.String.trim(username.getValue() || '') : ''
                };
            },
            onFilterChange: function () {
                var me = this,
                    proxy = me.store.getProxy();
                Ext.Object.each(me.getFilterParams(), function (key, value) {
                    proxy.setExtraParam(key, value);
                });
                me.store.load();
            },
            updateTotals: function () {
                // soma em centesimos de centavo (4 casas) para nao acumular erro de arredondamento
                var me = this,
                    params = me.getFilterParams(),
                    c = function (v) {
                        return Math.round((v || 0) * 10000);
                    },
                    sum = {
                        recurring_value: 0,
                        refill: 0,
                        amount_due: 0,
                        negative: 0
                    },
                    totals = {
                        month_label: params.month ? params.month.split('-').reverse().join('/') : '',
                        total_users: 0,
                        done: 0,
                        planned: 0,
                        skipped: 0,
                        customers_to_pay: 0
                    };
                me.store.each(function (record) {
                    totals.total_users++;
                    totals[record.get('status')] = (totals[record.get('status')] || 0) + 1;
                    sum.recurring_value += c(record.get('recurring_value'));
                    sum.refill += c(record.get('refill'));
                    sum.amount_due += c(record.get('amount_due'));
                    if (record.get('amount_due') > 0) {
                        totals.customers_to_pay++;
                    }
                });
                Ext.Object.each(sum, function (key, value) {
                    totals[key] = value / 10000;
                });
                if (!me.formPanel) {
                    return;
                }
                me.formPanel.getForm().getFields().each(function (field) {
                    if (Ext.isDefined(totals[field.name])) {
                        field.setValue(totals[field.name]);
                    }
                });
            },
            onEdit: function () {
                // relatorio somente leitura: o painel lateral mostra sempre os totais
                this.updateTotals();
                this.formPanel && this.formPanel.expand();
            },
            onExportPlanCsv: function () {
                var me = this;
                window.open('index.php/planConsumption/csv/?' + Ext.Object.toQueryString(me.getFilterParams()));
            }
        });

        // ---- classic/src/view/planConsumption/Form.js
        Ext.define('MBilling.view.planConsumption.Form', {
            extend: 'Ext.ux.form.Panel',
            alias: 'widget.planconsumptionform',
            labelWidthFields: 170,
            defaultType: 'displayfield',
            initComponent: function () {
                var me = this,
                    money = Helper.Util.formatExactMoney;
                me.allowUpdate = false;
                me.allowCreate = false;
                me.items = [{
                    name: 'month_label',
                    fieldLabel: t('Cycle')
                }, {
                    name: 'total_users',
                    fieldLabel: t('Customers')
                }, {
                    name: 'recurring_value',
                    fieldLabel: t('Recurring value'),
                    renderer: money
                }, {
                    name: 'refill',
                    fieldLabel: t('Refill'),
                    renderer: money
                }, {
                    name: 'amount_due',
                    fieldLabel: '<b>' + t('Amount to pay') + '</b>',
                    renderer: function (value) {
                        return '<b>' + money(value) + '</b>';
                    }
                }, {
                    name: 'customers_to_pay',
                    fieldLabel: t('Customers with amount to pay')
                }, {
                    xtype: 'component',
                    html: '<hr>'
                }, {
                    name: 'done',
                    fieldLabel: t('Refilled')
                }, {
                    name: 'planned',
                    fieldLabel: t('Forecast (not refilled yet)')
                }, {
                    name: 'skipped',
                    fieldLabel: t('Not refilled (inactive/blocked)')
                }];
                me.callParent(arguments);
            }
        });

        // ---- classic/src/view/planConsumption/List.js
        Ext.define('MBilling.view.planConsumption.List', {
            extend: 'Ext.ux.grid.Panel',
            alias: 'widget.planconsumptionlist',
            initComponent: function () {
                var me = this,
                    months = [],
                    now = new Date(),
                    d, i, defaultMonth;

                // ultimos 24 meses para o seletor
                for (i = 0; i < 24; i++) {
                    d = Ext.Date.add(new Date(now.getFullYear(), now.getMonth(), 1), Ext.Date.MONTH, -i);
                    months.push([Ext.Date.format(d, 'Y-m'), Ext.Date.format(d, 'm/Y')]);
                }
                // padrao: ciclo do mes atual a partir do dia 20; antes disso, o ciclo anterior
                defaultMonth = now.getDate() >= 20 ? months[0][0] : months[1][0];

                me.store = Ext.create('MBilling.store.PlanConsumption');
                me.store.getProxy().setExtraParam('month', defaultMonth);
                me.store.getProxy().setExtraParam('plan_type', '');
                me.store.getProxy().setExtraParam('username', '');

                me.allowCreate = false;
                me.allowUpdate = false;
                me.allowDelete = false;
                me.allowSearch = false;
                me.buttonUpdateLot = false;
                me.buttonImportCsv = false;
                me.buttonPrint = false;
                me.buttonCleanFilter = false;
                me.filterableColumns = false;
                me.remoteFilter = false;
                me.pagination = false;
                me.actionButtonCsv = 'onExportPlanCsv';

                me.dockedItems = [{
                    xtype: 'toolbar',
                    dock: 'top',
                    items: [{
                        xtype: 'combo',
                        reference: 'pcMonth',
                        fieldLabel: t('Cycle'),
                        labelWidth: 45,
                        width: 160,
                        editable: false,
                        forceSelection: true,
                        store: months,
                        value: defaultMonth,
                        listeners: {
                            select: 'onFilterChange'
                        }
                    }, {
                        xtype: 'combo',
                        reference: 'pcPlanType',
                        fieldLabel: t('Plan type'),
                        labelWidth: 95,
                        width: 240,
                        editable: false,
                        forceSelection: true,
                        value: '',
                        store: [
                            ['', t('All')],
                            ['franchise', t('Franchise')],
                            ['minutes', t('Minutes')],
                            ['unlimited', t('Unlimited')]
                        ],
                        listeners: {
                            select: 'onFilterChange'
                        }
                    }, {
                        xtype: 'textfield',
                        reference: 'pcUsername',
                        emptyText: t('Search') + ' ' + t('Customer'),
                        width: 150,
                        enableKeyEvents: true,
                        listeners: {
                            specialkey: function (field, e) {
                                if (e.getKey() === e.ENTER) {
                                    field.lookupController().onFilterChange();
                                }
                            }
                        }
                    }, {
                        xtype: 'button',
                        text: t('Search'),
                        iconCls: 'x-fa fa-search',
                        handler: 'onFilterChange'
                    }]
                }];

                var money = Helper.Util.formatExactMoney,
                    statusLabels = {
                        done: t('Refilled'),
                        planned: t('Forecast'),
                        skipped: t('Not refilled')
                    };
                me.columns = [{
                    header: t('Customer'),
                    dataIndex: 'customer',
                    flex: 4
                }, {
                    header: t('Username'),
                    dataIndex: 'username',
                    flex: 2
                }, {
                    header: t('Plan type'),
                    dataIndex: 'plan_type_label',
                    flex: 2
                }, {
                    header: t('Recurring value'),
                    dataIndex: 'recurring_value',
                    renderer: money,
                    flex: 2
                }, {
                    header: t('Balance'),
                    dataIndex: 'consumption',
                    tooltip: t('Balance at the time of the refill'),
                    renderer: function (value) {
                        return '<span style="color:' + (value < 0 ? 'red' : 'inherit') + '">' + money(value) + '</span>';
                    },
                    flex: 2
                }, {
                    header: t('Spent in the cycle'),
                    dataIndex: 'spent',
                    renderer: money,
                    hidden: true,
                    flex: 2
                }, {
                    header: t('Refill'),
                    dataIndex: 'refill',
                    renderer: function (value, meta, record) {
                        if (record.get('status') === 'planned') {
                            meta.tdAttr = 'data-qtip="' + t('Forecast (not refilled yet)') + '"';
                            return '<span style="color:gray;font-style:italic">' + money(value) + '</span>';
                        }
                        return money(value);
                    },
                    flex: 2
                }, {
                    header: t('Amount to pay'),
                    dataIndex: 'amount_due',
                    renderer: function (value) {
                        return '<b>' + money(value) + '</b>';
                    },
                    flex: 2
                }, {
                    header: t('Status'),
                    dataIndex: 'status',
                    renderer: function (value) {
                        return statusLabels[value] || value;
                    },
                    flex: 2
                }];
                me.callParent(arguments);
            }
        });

        // ---- classic/src/view/planConsumption/Module.js
        Ext.define('MBilling.view.planConsumption.Module', {
            extend: 'Ext.ux.panel.Module',
            alias: 'widget.planconsumptionmodule',
            controller: 'planconsumption',
            titleDetails: t('Total'),
            iconForm: 'icon-sum',
            collapsedForm: false,
            cfgEast: {
                flex: 0.8
            }
        });
    }

    boot();
})();
