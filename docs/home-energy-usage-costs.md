# Home energy usage and estimated costs

## Purpose and source of truth

The GitOps-managed **Home Energy | Usage & Costs** dashboard is at
`platform/observability/grafana/dashboards/home/home-energy-insights.json`,
with UID `home-energy-insights`. The original `dsmr-energy` and `home-energy`
dashboards remain unchanged for instantaneous power, phase data and inverter
diagnostics. This dashboard focuses on metered consumption and **illustrative**
costs; it does not recreate a supplier invoice.

Data uses the existing `observability` Prometheus datasource UID `prometheus`:
- DSMR P1 10-second scrape: four cumulative electricity registers, two import
  (`dsmr_electricity_import_total_kwh_tariff_1/2`) and two export
  (`dsmr_electricity_export_total_kwh_tariff_1/2`), plus
  `dsmr_gas_total_m3`.
- GoodWe 10-second scrape: `goodwe_total_generation_kwh`.
- Data quality: `dsmr_up`, `goodwe_up`, P1 last-telegram timestamp.

## Calendar period selection

Use the dashboard's top links or Grafana time picker:
- Hour: `now/h` to `now`.
- Today: `now/d` to `now`; yesterday: `now-1d/d` to `now/d`.
- This month: `now/M` to `now`; previous month:
  `now-1M/M` to `now/M`.
- This year: `now/y` to `now`; previous year:
  `now-1y/y` to `now/y`.

The dashboard timezone is explicitly `Europe/Amsterdam`. Calendar total
KPI expressions use the meter reading from up to 15 minutes before
`${__from:date:seconds}` and `${__to:date:seconds}`, then subtract.
There is no fabricated zero for unavailable boundary readings. The 15-minute
window accommodates delayed gas telegrams; it may produce a small discrepancy
against the supplier around an hour boundary and should be checked against
the meter's update schedule. In particular, missing data at the *start*
of a selected period means you **cannot** infer that period's consumption.
The start/end meter reading method also assumes a single site and stable
cumulative meter registers. Register replacement, downward resets or
a non-monotonic exporter series require investigation before trusting totals.

Chart panels intentionally show rolling 1-hour / 24-hour / 30-day differences.
The daily graph uses 24-hour windows and therefore **is not an exact local
calendar day** on daylight saving changes. The 30-day trends **are not
calendar months**, nor do they show monthly or yearly category comparisons.
Use the dashboard's calendar picker to obtain exact selected-month/year
totals. If literal year-by-year or month-by-month comparison bars are
required, add calendar-aligned aggregation in a subsequent stage.

Prometheus currently has `--storage.tsdb.retention.time=365d` and
`--storage.tsdb.retention.size=50GB`. Data can expire earlier when the
size limit is reached. Annual historical comparisons beyond retained data,
or supplier historical bills, require longer-term storage or importing
supplier history. **Do not increase retention without planning disk space
and a durable recording/downsampling approach.**

## Editable estimates

All prices are Grafana textbox variables, and need to be checked against
the actual contract, with any rate changes split into separate periods:

| Input | Default | Explanation |
| --- | ---: | --- |
| `elec_t1_eur_kwh` | 0.2703 | Approximate electricity import T1, €/kWh |
| `elec_t2_eur_kwh` | 0.2703 | Approximate electricity import T2, €/kWh |
| `credit_t1_eur_kwh` | 0.2703 | Simplified credit for T1 grid return |
| `credit_t2_eur_kwh` | 0.2703 | Simplified credit for T2 grid return |
| `feedin_fee_eur_kwh` | 0 | Optional **linear** return fee, €/kWh |
| `elec_fixed_eur_day` | -0.13 | Example net daily electricity fixed credit |
| `gas_eur_m3` | 1.59 | Example gas variable price, €/m³ |
| `gas_fixed_eur_day` | 1.04 | Example daily gas fixed charge |

The examples were inferred from the **4 November** utility screenshots:
35 kWh net electricity with €9.46 variable cost, -€0.13 fixed cost
and €9.33 daily total; 1 m³ gas with €1.59 variable, €1.04 fixed and
€2.63 total. These numbers are **not a verified tariff sheet or contract**.

- Gross import cost = (T1 import × T1 import price) +
  (T2 import × T2 import price).
- Illustrative electricity net cost = gross import cost -
  (T1 export × credit T1) - (T2 export × credit T2) +
  (total export × feed-in fee) + daily electricity fixed cost.
- Gas cost = (gas m³ × gas price) + daily gas fixed cost.
- Fixed costs for selected periods use elapsed seconds / 86400 days;
  the hourly/rolling 24h/rolling 30d trend uses 1/24, 1 and 30
  assumed fixed-day quantities respectively.
- Estimated locally used solar = max(0, GoodWe lifetime production
  difference minus DSMR grid export difference). Hypothetical avoided
  purchase value is shown **separately**, not added to total bill cost.

**Important supplier differences:** In the Netherlands annual net metering
remains relevant during 2026, and ends on **1 January 2027**. The dashboard's
flat-rate per-period credit is **not** an implementation of annual
saldering, tariff-specific settlement, post-2026 feed-in compensation,
supplier tiered return charges, energy tax credits, VAT rules,
capacity charges or contract changes. The estimated cost is best treated as
a planning/budget figure, not final liability. Compare totals and fees with
monthly/yearly supplier statements and adjust as needed.

## Deployment and validation

Dashboard JSON is provisioned by the existing `observability`
Kustomization. The `grafana-dashboard-home-energy-insights` generated
ConfigMap is mounted as `Home/home-energy-insights.json` via the
existing hashed projected ConfigMap mechanism. The Home folder and other
dashboards stay unchanged.

Run the existing test suite:
```bash
python3 scripts/test-grafana-dashboards.py
python3 scripts/test-grafana-provisioning.py
kubectl kustomize platform/observability >/tmp/observability.yaml
```

After merge and reconciliation:
```bash
kubectl -n observability rollout status deployment/grafana
kubectl -n observability rollout status deployment/prometheus
```

Use Grafana Explore to confirm all six cumulative meter metrics are present
in the `prometheus` datasource. Validate today, yesterday, a full month
and a year in the time picker, ensure any incomplete historical boundary
shows **No data**, and compare import/export/gas against the utility portal.
Verify PV generation is measured by the same GoodWe/DSMR installation.
Costs become reliable only after verified contract prices and settlement
rules have been entered.

## Known follow-ups

1. Calendar-aligned hourly/daily/monthly/yearly comparison bars, ideally
   backed by recording rules or a longer-term time-series backend.
2. Contract-based tariffs with effective dates and actual return-charge
   structure; correctly implement 2026 saldering and post-2026 compensation.
3. Multi-year historical storage, importer/backfill and missing-data
   coverage diagnostics before enabling year-on-year comparisons.
