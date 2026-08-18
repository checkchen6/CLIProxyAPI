/**
 * Usage Stats API service
 */

import { apiClient } from './client';

export interface UsageStatsSummary {
  total_requests: number;
  failed_requests: number;
  chat_requests: number;
  image_requests: number;
  other_requests: number;
  chat_tokens: number;
  chat_input: number;
  chat_output: number;
  image_tokens: number;
}

export interface UsageStatsHourlyRow {
  hour: string;
  category: string;
  total_requests: number;
  input_tokens: number;
  output_tokens: number;
  total_tokens: number;
  avg_latency_ms: number;
  avg_ttft_ms: number;
}

export interface UsageStatsModelRow {
  model: string;
  category: string;
  requests: number;
  total_tokens: number;
  avg_latency_ms: number;
  avg_ttft_ms: number;
  failed: number;
}

export const usageStatsApi = {
  getSummary(start: string, end: string): Promise<UsageStatsSummary> {
    return apiClient.get<UsageStatsSummary>('/usage-stats/summary', {
      params: { start, end },
    });
  },

  getHourly(start: string, end: string): Promise<UsageStatsHourlyRow[]> {
    return apiClient.get<UsageStatsHourlyRow[]>('/usage-stats/hourly', {
      params: { start, end },
    });
  },

  getModels(start: string, end: string): Promise<UsageStatsModelRow[]> {
    return apiClient.get<UsageStatsModelRow[]>('/usage-stats/models', {
      params: { start, end },
    });
  },

  deleteRecords(before: string): Promise<void> {
    return apiClient.delete('/usage-stats/records', {
      params: { before },
    });
  },
};
