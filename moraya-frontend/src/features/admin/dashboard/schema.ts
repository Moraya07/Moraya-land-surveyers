import { z } from 'zod';

/** Runtime validation of GET /api/admin/dashboard. Amounts are integer paise (₹1 = 100). */

export const periodSchema = z.enum(['today', 'this_week', 'this_month', 'previous_month']);
export type Period = z.infer<typeof periodSchema>;

const paise = z.number().int();
const count = z.number().int().nonnegative();

const verificationStatus = z.enum([
  'DRAFT',
  'PENDING_VERIFICATION',
  'VERIFIED',
  'CHANGES_REQUESTED',
  'REJECTED',
  'CANCELLED',
]);
export type VerificationStatus = z.infer<typeof verificationStatus>;

const pendingItem = z.object({
  id: z.string(),
  kind: z.enum(['work', 'expense']),
  employeeName: z.string(),
  siteName: z.string(),
  submittedAt: z.string(),
  amountPaise: paise.nullable(),
});
const workItem = z.object({
  id: z.string(),
  employeeName: z.string(),
  assistantName: z.string().nullable(),
  siteName: z.string(),
  workedAt: z.string(),
  status: verificationStatus,
});
const expenseItem = z.object({
  id: z.string(),
  employeeName: z.string(),
  siteName: z.string(),
  date: z.string(),
  category: z.string(),
  amountPaise: paise,
  status: verificationStatus,
});
const incomeItem = z.object({
  id: z.string(),
  siteName: z.string(),
  date: z.string(),
  reference: z.string().nullable(),
  amountPaise: paise,
  status: z.enum(['PENDING', 'RECEIVED', 'PARTIALLY_RECEIVED', 'CANCELLED']),
});
const salaryItem = z.object({
  id: z.string(),
  employeeName: z.string(),
  employeeId: z.string(),
  periodLabel: z.string(),
  amountPaise: paise,
  paymentStatus: z.enum(['PENDING', 'PARTIALLY_PAID']),
});
const siteItem = z.object({
  id: z.string(),
  name: z.string(),
  clientName: z.string().nullable(),
  status: z.literal('ACTIVE'),
  workCount: count,
});
const activityItem = z.object({
  employeeId: z.string(),
  employeeName: z.string(),
  lastWorkAt: z.string().nullable(),
  workCountInPeriod: count,
});

export const dashboardSchema = z.object({
  generatedAt: z.string(),
  period: z.object({ key: periodSchema, from: z.string(), to: z.string() }),
  counts: z.object({
    activeEmployees: count.nullable(),
    activeSites: count.nullable(),
    pendingVerification: count.nullable(),
  }),
  money: z.object({
    siteIncomePaise: paise.nullable(),
    siteExpensesPaise: paise.nullable(),
    salaryPaidPaise: paise.nullable(),
    salaryPendingPaise: paise.nullable(),
    siteNetBalancePaise: paise.nullable(),
  }),
  // null = this caller may not see the section: render nothing for it.
  pendingVerification: z.object({ total: count, items: z.array(pendingItem) }).nullable(),
  recentWork: z.array(workItem).nullable(),
  recentExpenses: z.array(expenseItem).nullable(),
  recentIncome: z.array(incomeItem).nullable(),
  pendingSalaries: z.array(salaryItem).nullable(),
  activeSites: z.array(siteItem).nullable(),
  employeeActivity: z.array(activityItem).nullable(),
});

export type DashboardResponse = z.infer<typeof dashboardSchema>;
export type PendingItem = z.infer<typeof pendingItem>;
export type WorkItem = z.infer<typeof workItem>;
export type ExpenseItem = z.infer<typeof expenseItem>;
export type IncomeItem = z.infer<typeof incomeItem>;
export type SalaryItem = z.infer<typeof salaryItem>;
export type SiteItem = z.infer<typeof siteItem>;
export type ActivityItem = z.infer<typeof activityItem>;
