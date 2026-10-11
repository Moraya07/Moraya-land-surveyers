/**
 * DEV ONLY. Loaded with a dynamic import when VITE_USE_MOCK_DASHBOARD=true and never imported by
 * production paths. Pick a scenario with ?mock=full | limited | empty | error | forbidden.
 */
import { ApiError } from '../../../lib/errors';
import type { DashboardResponse, Period } from './schema';

const DELAY_MS = 500;
const MULTIPLIER: Record<Period, number> = { today: 0.08, this_week: 0.35, this_month: 1, previous_month: 0.9 };
const SPAN_MINUTES: Record<Period, number> = {
  today: 24 * 60,
  this_week: 7 * 24 * 60,
  this_month: 30 * 24 * 60,
  previous_month: 60 * 24 * 60,
};

const wait = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function full(period: Period): DashboardResponse {
  const now = Date.now();
  const ago = (minutes: number) => new Date(now - minutes * 60_000).toISOString();
  const rupees = (amount: number) => Math.round(amount * MULTIPLIER[period]) * 100;

  const income = rupees(845_000);
  const expenses = rupees(312_500);

  return {
    generatedAt: new Date(now).toISOString(),
    period: { key: period, from: ago(SPAN_MINUTES[period]), to: new Date(now).toISOString() },
    counts: { activeEmployees: 24, activeSites: 9, pendingVerification: 12 },
    money: {
      siteIncomePaise: income,
      siteExpensesPaise: expenses,
      salaryPaidPaise: rupees(225_000),
      salaryPendingPaise: rupees(125_000),
      siteNetBalancePaise: income - expenses,
    },
    pendingVerification: {
      total: 12,
      items: [
        { id: 'pv1', kind: 'work', employeeName: 'Rohit Patil', siteName: 'Hinjewadi Phase 2 Layout', submittedAt: ago(35), amountPaise: null },
        { id: 'pv2', kind: 'expense', employeeName: 'Sneha Kulkarni', siteName: 'Baner Road Survey', submittedAt: ago(95), amountPaise: 185_000 },
        { id: 'pv3', kind: 'work', employeeName: 'Amit Deshmukh', siteName: 'Wagholi Plot 14', submittedAt: ago(240), amountPaise: null },
        { id: 'pv4', kind: 'expense', employeeName: 'Priya Jadhav', siteName: 'Kharadi IT Park', submittedAt: ago(26 * 60), amountPaise: 1_250_050 },
        { id: 'pv5', kind: 'work', employeeName: 'Vikram Shinde', siteName: 'Pimpri Industrial Estate', submittedAt: ago(30 * 60), amountPaise: null },
      ],
    },
    recentWork: [
      { id: 'w1', employeeName: 'Rohit Patil', assistantName: 'Suresh Pawar', siteName: 'Hinjewadi Phase 2 Layout', workedAt: ago(60), status: 'PENDING_VERIFICATION' },
      { id: 'w2', employeeName: 'Anjali More', assistantName: null, siteName: 'Baner Road Survey', workedAt: ago(5 * 60), status: 'VERIFIED' },
      { id: 'w3', employeeName: 'Amit Deshmukh', assistantName: 'Vikram Shinde', siteName: 'Wagholi Plot 14', workedAt: ago(22 * 60), status: 'CHANGES_REQUESTED' },
      { id: 'w4', employeeName: 'Priya Jadhav', assistantName: null, siteName: 'Kharadi IT Park', workedAt: ago(30 * 60), status: 'VERIFIED' },
      { id: 'w5', employeeName: 'Sneha Kulkarni', assistantName: null, siteName: 'Lonavala Hillside', workedAt: ago(48 * 60), status: 'REJECTED' },
    ],
    recentExpenses: [
      { id: 'e1', employeeName: 'Sneha Kulkarni', siteName: 'Baner Road Survey', date: ago(95), category: 'Fuel', amountPaise: 185_000, status: 'PENDING_VERIFICATION' },
      { id: 'e2', employeeName: 'Priya Jadhav', siteName: 'Kharadi IT Park', date: ago(26 * 60), category: 'Equipment hire', amountPaise: 1_250_050, status: 'PENDING_VERIFICATION' },
      { id: 'e3', employeeName: 'Rohit Patil', siteName: 'Hinjewadi Phase 2 Layout', date: ago(40 * 60), category: 'Food', amountPaise: 42_000, status: 'VERIFIED' },
      { id: 'e4', employeeName: 'Amit Deshmukh', siteName: 'Wagholi Plot 14', date: ago(52 * 60), category: 'Travel', amountPaise: 96_500, status: 'VERIFIED' },
      { id: 'e5', employeeName: 'Suresh Pawar', siteName: 'Lonavala Hillside', date: ago(70 * 60), category: 'Materials', amountPaise: 310_000, status: 'CANCELLED' },
    ],
    recentIncome: [
      { id: 'i1', siteName: 'Hinjewadi Phase 2 Layout', date: ago(8 * 60), reference: 'INV-2026-0142', amountPaise: 25_000_000, status: 'RECEIVED' },
      { id: 'i2', siteName: 'Kharadi IT Park', date: ago(3 * 24 * 60), reference: 'INV-2026-0139', amountPaise: 12_500_000, status: 'PARTIALLY_RECEIVED' },
      { id: 'i3', siteName: 'Pimpri Industrial Estate', date: ago(6 * 24 * 60), reference: null, amountPaise: 8_000_000, status: 'PENDING' },
    ],
    pendingSalaries: [
      { id: 's1', employeeName: 'Rohit Patil', employeeId: 'emp-001', periodLabel: 'Sep 2026', amountPaise: 3_200_000, paymentStatus: 'PENDING' },
      { id: 's2', employeeName: 'Anjali More', employeeId: 'emp-004', periodLabel: 'Sep 2026', amountPaise: 2_800_000, paymentStatus: 'PARTIALLY_PAID' },
      { id: 's3', employeeName: 'Suresh Pawar', employeeId: 'emp-007', periodLabel: 'Sep 2026', amountPaise: 2_150_000, paymentStatus: 'PENDING' },
    ],
    activeSites: [
      { id: 'a1', name: 'Hinjewadi Phase 2 Layout', clientName: 'Kolte Patil Developers', status: 'ACTIVE', workCount: 18 },
      { id: 'a2', name: 'Baner Road Survey', clientName: 'Sahyadri Constructions', status: 'ACTIVE', workCount: 11 },
      { id: 'a3', name: 'Wagholi Plot 14', clientName: null, status: 'ACTIVE', workCount: 7 },
      { id: 'a4', name: 'Kharadi IT Park', clientName: 'Gaikwad Infra', status: 'ACTIVE', workCount: 5 },
    ],
    employeeActivity: [
      { employeeId: 'emp-001', employeeName: 'Rohit Patil', lastWorkAt: ago(60), workCountInPeriod: 14 },
      { employeeId: 'emp-004', employeeName: 'Anjali More', lastWorkAt: ago(5 * 60), workCountInPeriod: 11 },
      { employeeId: 'emp-002', employeeName: 'Sneha Kulkarni', lastWorkAt: ago(48 * 60), workCountInPeriod: 6 },
      { employeeId: 'emp-009', employeeName: 'Vikram Shinde', lastWorkAt: null, workCountInPeriod: 0 },
    ],
  };
}

/** Sub-admin with verification + site rights only: income, salary and employee data are null. */
function limited(period: Period): DashboardResponse {
  const base = full(period);
  return {
    ...base,
    counts: { ...base.counts, activeEmployees: null },
    money: {
      siteIncomePaise: null,
      siteExpensesPaise: base.money.siteExpensesPaise,
      salaryPaidPaise: null,
      salaryPendingPaise: null,
      siteNetBalancePaise: null,
    },
    recentIncome: null,
    pendingSalaries: null,
    employeeActivity: null,
  };
}

function empty(period: Period): DashboardResponse {
  const base = full(period);
  return {
    generatedAt: base.generatedAt,
    period: base.period,
    counts: { activeEmployees: 0, activeSites: 0, pendingVerification: 0 },
    money: {
      siteIncomePaise: 0,
      siteExpensesPaise: 0,
      salaryPaidPaise: 0,
      salaryPendingPaise: 0,
      siteNetBalancePaise: 0,
    },
    pendingVerification: { total: 0, items: [] },
    recentWork: [],
    recentExpenses: [],
    recentIncome: [],
    pendingSalaries: [],
    activeSites: [],
    employeeActivity: [],
  };
}

export async function getMockDashboard(period: Period, scenario: string | null): Promise<DashboardResponse> {
  await wait(DELAY_MS);
  switch (scenario) {
    case 'error':
      throw new ApiError(500, 'INTERNAL_ERROR');
    case 'forbidden':
      throw new ApiError(403, 'FORBIDDEN');
    case 'limited':
      return limited(period);
    case 'empty':
      return empty(period);
    default:
      return full(period);
  }
}
