/**
 * Usage Statistics page — integrated into the management panel sidebar.
 *
 * Shows KPI cards, distribution donut, hourly latency bar chart,
 * and a per-model detail table. All data is fetched from the
 * /usage-stats/* management API endpoints.
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { usageStatsApi } from '@/services/api';
import type {
  UsageStatsSummary,
  UsageStatsHourlyRow,
  UsageStatsModelRow,
} from '@/services/api/usageStats';
import styles from './UsageStatsPage.module.scss';

type TimeRange = 'today' | '7d' | '30d';

function getTimeRange(range: TimeRange): { start: string; end: string } {
  const now = new Date();
  const end = now.toISOString();
  let start: Date;
  switch (range) {
    case 'today':
      start = new Date(now.getFullYear(), now.getMonth(), now.getDate());
      break;
    case '7d':
      start = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);
      break;
    case '30d':
      start = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000);
      break;
  }
  return { start: start.toISOString(), end };
}

function formatNumber(n: number | undefined | null): string {
  const val = n ?? 0;
  if (val >= 1_000_000) return (val / 1_000_000).toFixed(1) + 'M';
  if (val >= 1_000) return (val / 1_000).toFixed(1) + 'K';
  return val.toLocaleString();
}

function formatMs(ms: number | undefined | null): string {
  const val = ms ?? 0;
  if (val >= 1000) return (val / 1000).toFixed(1) + 's';
  return Math.round(val) + 'ms';
}

// Donut chart via SVG
function DonutChart({
  data,
}: {
  data: { label: string; value: number; color: string }[];
}) {
  const total = data.reduce((s, d) => s + d.value, 0);
  if (total === 0) {
    return (
      <svg className={styles.donutSvg} viewBox="0 0 36 36">
        <circle cx="18" cy="18" r="14" fill="none" stroke="var(--border-color, #e0e0e0)" strokeWidth="4" />
        <text x="18" y="18" textAnchor="middle" dominantBaseline="middle" fontSize="4" fill="var(--text-secondary)">
          0
        </text>
      </svg>
    );
  }

  let offset = 25; // start from top
  const arcs = data.map((d) => {
    const pct = (d.value / total) * 100;
    const arc = (
      <circle
        key={d.label}
        cx="18"
        cy="18"
        r="14"
        fill="none"
        stroke={d.color}
        strokeWidth="4"
        strokeDasharray={`${pct} ${100 - pct}`}
        strokeDashoffset={`${offset}`}
      />
    );
    offset -= pct;
    return arc;
  });

  return (
    <svg className={styles.donutSvg} viewBox="0 0 36 36">
      {arcs}
      <text x="18" y="17" textAnchor="middle" dominantBaseline="middle" fontSize="5" fontWeight="700" fill="var(--text-primary)">
        {formatNumber(total)}
      </text>
      <text x="18" y="22" textAnchor="middle" dominantBaseline="middle" fontSize="2.5" fill="var(--text-secondary)">
        requests
      </text>
    </svg>
  );
}

export function UsageStatsPage() {
  const { t } = useTranslation();
  const [range, setRange] = useState<TimeRange>('today');
  const [summary, setSummary] = useState<UsageStatsSummary | null>(null);
  const [hourly, setHourly] = useState<UsageStatsHourlyRow[]>([]);
  const [models, setModels] = useState<UsageStatsModelRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchData = useCallback(async (r: TimeRange) => {
    setLoading(true);
    setError(null);
    try {
      const { start, end } = getTimeRange(r);
      const [s, h, m] = await Promise.all([
        usageStatsApi.getSummary(start, end),
        usageStatsApi.getHourly(start, end),
        usageStatsApi.getModels(start, end),
      ]);
      setSummary(s);
      setHourly(h ?? []);
      setModels(m ?? []);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : 'Failed to fetch data';
      setError(msg);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchData(range);
  }, [range, fetchData]);

  // Aggregate hourly data for latency chart
  const hourlyAgg = useMemo(() => {
    const map = new Map<number, { chat_latency: number; img_latency: number; chat_count: number; img_count: number }>();
    for (let i = 0; i < 24; i++) {
      map.set(i, { chat_latency: 0, img_latency: 0, chat_count: 0, img_count: 0 });
    }
    for (const row of hourly) {
      const hourStr = row.hour?.split('T')[1]?.split(':')[0];
      const hour = parseInt(hourStr ?? '0', 10);
      const entry = map.get(hour);
      if (!entry) continue;
      if (row.category === 'chat') {
        entry.chat_latency += (row.avg_latency_ms ?? 0) * (row.total_requests ?? 0);
        entry.chat_count += row.total_requests ?? 0;
      } else if (row.category === 'image') {
        entry.img_latency += (row.avg_latency_ms ?? 0) * (row.total_requests ?? 0);
        entry.img_count += row.total_requests ?? 0;
      }
    }
    return Array.from(map.entries())
      .sort((a, b) => a[0] - b[0])
      .map(([hour, d]) => ({
        hour,
        chat_latency: d.chat_count > 0 ? d.chat_latency / d.chat_count : 0,
        img_latency: d.img_count > 0 ? d.img_latency / d.img_count : 0,
      }));
  }, [hourly]);

  // Donut data
  const donutData = useMemo(() => {
    if (!summary) return [];
    return [
      { label: t('usage_stats.chat'), value: summary.chat_requests ?? 0, color: '#6366f1' },
      { label: t('usage_stats.image'), value: summary.image_requests ?? 0, color: '#f59e0b' },
    ].filter((d) => d.value > 0);
  }, [summary, t]);

  // Max values for bar scaling
  const maxLatency = useMemo(() => {
    return Math.max(1, ...hourlyAgg.map((h) => Math.max(h.chat_latency, h.img_latency)));
  }, [hourlyAgg]);

  const ranges: { key: TimeRange; label: string }[] = [
    { key: 'today', label: t('usage_stats.today') },
    { key: '7d', label: t('usage_stats.last_7_days') },
    { key: '30d', label: t('usage_stats.last_30_days') },
  ];

  if (loading && !summary) {
    return (
      <div className={styles.page}>
        <div className={styles.loading}>{t('usage_stats.loading')}</div>
      </div>
    );
  }

  return (
    <div className={styles.page}>
      {/* Header */}
      <div className={styles.header}>
        <h1 className={styles.title}>{t('usage_stats.title')}</h1>
        <p className={styles.subtitle}>{t('usage_stats.subtitle')}</p>
        <div className={styles.toolbar}>
          {ranges.map((r) => (
            <button
              key={r.key}
              className={`${styles.rangeBtn} ${range === r.key ? styles.active : ''}`}
              onClick={() => setRange(r.key)}
            >
              {r.label}
            </button>
          ))}
        </div>
      </div>

      {error && <div className={styles.error}>{error}</div>}

      {/* KPI Cards */}
      {summary && (
        <div className={styles.kpiRow}>
          <div className={styles.kpiCard}>
            <span className={styles.kpiLabel}>{t('usage_stats.total_requests')}</span>
            <span className={styles.kpiValue}>{formatNumber(summary.total_requests)}</span>
          </div>
          <div className={styles.kpiCard}>
            <span className={styles.kpiLabel}>{t('usage_stats.chat_tokens')}</span>
            <span className={styles.kpiValue}>{formatNumber(summary.chat_tokens)}</span>
            <span className={styles.kpiMeta}>{t('usage_stats.in')} {formatNumber(summary.chat_input)} / {t('usage_stats.out')} {formatNumber(summary.chat_output)}</span>
          </div>
          <div className={styles.kpiCard}>
            <span className={styles.kpiLabel}>{t('usage_stats.image_requests')}</span>
            <span className={styles.kpiValue}>{formatNumber(summary.image_requests)}</span>
          </div>
          <div className={styles.kpiCard}>
            <span className={styles.kpiLabel}>{t('usage_stats.failure_rate')}</span>
            <span className={styles.kpiValue}>
              {(summary.total_requests ?? 0) > 0
                ? (((summary.failed_requests ?? 0) / summary.total_requests) * 100).toFixed(1) + '%'
                : '0%'}
            </span>
            <span className={styles.kpiMeta}>{summary.failed_requests ?? 0} {t('usage_stats.failures')}</span>
          </div>
        </div>
      )}

      {/* Charts Row */}
      <div className={styles.chartsRow}>
        {/* Donut */}
        <div className={styles.chartCard}>
          <h3 className={styles.chartTitle}>{t('usage_stats.request_distribution')}</h3>
          <div className={styles.donutContainer}>
            <DonutChart data={donutData} />
            <div className={styles.donutLegend}>
              {donutData.map((d) => (
                <div key={d.label} className={styles.legendItem}>
                  <span className={styles.legendDot} style={{ background: d.color }} />
                  {d.label} ({formatNumber(d.value)})
                </div>
              ))}
              {donutData.length === 0 && (
                <span style={{ color: 'var(--text-tertiary)', fontSize: '0.8125rem' }}>
                  {t('usage_stats.no_data')}
                </span>
              )}
            </div>
          </div>
        </div>

        {/* Latency Bar Chart */}
        <div className={styles.chartCard}>
          <h3 className={styles.chartTitle}>{t('usage_stats.hourly_latency')}</h3>
          <div className={styles.barChart}>
            {hourlyAgg
              .filter((_, i) => i % 2 === 0)
              .map((h) => (
                <div key={h.hour} className={styles.barRow}>
                  <span className={styles.barLabel}>{String(h.hour).padStart(2, '0')}</span>
                  <div className={styles.barTrack}>
                    {h.chat_latency > 0 && (
                      <div
                        className={styles.barFill}
                        style={{
                          width: `${(h.chat_latency / maxLatency) * 100}%`,
                          background: '#6366f1',
                        }}
                      >
                        {formatMs(h.chat_latency)}
                      </div>
                    )}
                  </div>
                </div>
              ))}
            {hourlyAgg.every((h) => h.chat_latency === 0 && h.img_latency === 0) && (
              <span style={{ color: 'var(--text-tertiary)', fontSize: '0.8125rem', textAlign: 'center', display: 'block', padding: '20px' }}>
                {t('usage_stats.no_data')}
              </span>
            )}
          </div>
        </div>
      </div>

      {/* Model Detail Table */}
      <div className={styles.tableCard}>
        <h3 className={styles.tableTitle}>{t('usage_stats.model_detail')}</h3>
        <table className={styles.table}>
          <thead>
            <tr>
              <th>{t('usage_stats.col_model')}</th>
              <th>{t('usage_stats.col_type')}</th>
              <th>{t('usage_stats.col_requests')}</th>
              <th>{t('usage_stats.col_tokens')}</th>
              <th>{t('usage_stats.col_avg_latency')}</th>
              <th>{t('usage_stats.col_ttft')}</th>
              <th>{t('usage_stats.col_failed')}</th>
            </tr>
          </thead>
          <tbody>
            {models.length === 0 ? (
              <tr>
                <td colSpan={7} className={styles.emptyRow}>
                  {t('usage_stats.no_data')}
                </td>
              </tr>
            ) : (
              models.map((m, i) => (
                <tr key={`${m.model}-${m.category}-${i}`}>
                  <td>{m.model || '-'}</td>
                  <td>{m.category}</td>
                  <td>{formatNumber(m.requests)}</td>
                  <td>{formatNumber(m.total_tokens)}</td>
                  <td>{formatMs(m.avg_latency_ms)}</td>
                  <td>{formatMs(m.avg_ttft_ms)}</td>
                  <td>{m.failed ?? 0}</td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
