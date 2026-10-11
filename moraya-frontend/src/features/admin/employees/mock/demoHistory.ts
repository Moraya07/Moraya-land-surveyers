import type { ActivityChange, ActivityItem } from '../types';

/**
 * Dev-only demo trail for one employee (Vikram Patil), so the Activity tab can be tried without clicking
 * through every action: 59 entries in total (3 pages of 25), every known action code, a reason with markup,
 * an unknown action code and unknown field names.
 *
 * It also contains DELIBERATELY DIRTY entries (`aadhaar`, `Password`, `accessToken` change keys, and a value on an
 * Aadhaar entry). A real server never sends those; they exist to prove the client filter drops them.
 * The numbers used here are obviously fake.
 */

const DAY = 86_400_000;
const SANJAY = 'Sanjay Moraya';
const ANITA = 'Anita Deshmukh';

type Seed = [daysAgo: number, action: string, actor: string | null, reason: string | null, changes: ActivityChange[] | null];

const change = (field: string, from: string | null, to: string | null): ActivityChange => ({ field, from, to });

const HANDWRITTEN: Seed[] = [
  [2350, 'USER_UPDATED', ANITA, null, [change('dateOfJoining', '2019-08-12', '2019-08-05')]],
  [2200, 'USER_UPDATED', SANJAY, null, [change('employeeId', 'MLS-104', 'MLS-004'), change('designation', 'Trainee Surveyor', 'Surveyor')]],
  // Dirty on purpose: an Aadhaar entry that carries values. Must render as the sentence only.
  [2100, 'USER_AADHAAR_CHANGED', ANITA, null, [change('aadhaar', '999900004123', '999900004130')]],
  [1900, 'USER_DEACTIVATED', SANJAY, 'Extended medical leave until further notice.', [change('accountStatus', 'active', 'inactive')]],
  [1750, 'USER_REACTIVATED', SANJAY, null, [change('accountStatus', 'inactive', 'active')]],
  [1600, 'USER_UPDATED', ANITA, null, [change('designation', 'Surveyor', 'Senior Surveyor')]],
  [
    1400,
    'SUBADMIN_CREATED',
    SANJAY,
    'Covering for Anita during her leave.',
    [change('role', 'worker', 'sub_admin'), change('permissions', null, 'verification, report_view')],
  ],
  [
    1390,
    'SUBADMIN_PERMISSIONS_CHANGED',
    SANJAY,
    'Needs to see site records as well.',
    [change('permissions', 'verification, report_view', 'site_management, verification, report_view')],
  ],
  [1380, 'AADHAAR_REVEALED', SANJAY, null, null],
  [1300, 'SUBADMIN_PERMISSIONS_CHANGED', SANJAY, null, [change('permissions', 'site_management, verification, report_view', 'verification')]],
  [
    1200,
    'SUBADMIN_REVOKED',
    SANJAY,
    'Anita is back, so the temporary cover has ended.',
    [change('role', 'sub_admin', 'worker'), change('permissions', 'verification', null)],
  ],
  [1100, 'AADHAAR_REVEALED', SANJAY, null, null],
  [1000, 'USER_UPDATED', ANITA, null, [change('designation', 'Senior Surveyor', 'Surveyor'), change('dateOfBirth', '1991-01-18', '1992-01-18')]],
  // A reason with markup: must be shown as text, never run.
  [900, 'USER_DEACTIVATED', ANITA, '<script>alert("x")</script> <b>Absent</b> without notice for 10 days.', [change('accountStatus', 'active', 'inactive')]],
  [880, 'USER_REACTIVATED', ANITA, null, [change('accountStatus', 'inactive', 'active')]],
  // Unknown action code (generic label) with no actor (system).
  [700, 'PAYROLL_SYNCED', null, null, null],
  // Unknown field names (humanized) written by the system.
  [650, 'USER_UPDATED', null, null, [change('reportingManager', null, 'Prakash Kulkarni'), change('shift_start_time', '09:00', '08:30')]],
  // Dirty on purpose: secrets in the change keys. Only the `name` line may survive.
  [
    600,
    'USER_UPDATED',
    SANJAY,
    null,
    [
      change('Password', 'old-secret', 'new-secret'),
      change('accessToken', 'abc.def.ghi', 'jkl.mno.pqr'),
      change('aadhaarNumber', '999900004123', '999900004130'),
      change('name', 'Vikram  Patil', 'Vikram Patil'),
    ],
  ],
  [
    500,
    'USER_DEACTIVATED',
    SANJAY,
    'Under review after repeated site-visit mismatches. Verify the attendance records for February and March, compare them with the site diaries, and meet the employee before any decision. Reference: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    [change('accountStatus', 'active', 'inactive')],
  ],
  [480, 'USER_REACTIVATED', SANJAY, null, [change('accountStatus', 'inactive', 'active')]],
  [420, 'USER_UPDATED', ANITA, null, [change('designation', 'Surveyor', null)]],
  [410, 'USER_UPDATED', ANITA, null, [change('designation', null, 'Surveyor')]],
];

const REASONS = [
  'Seasonal layoff, no site work scheduled.',
  'On leave for a family function.',
  'Awaiting renewal of identity documents.',
  'Medical leave, certificate submitted.',
  'Training programme at the head office.',
  'Absent without notice, to be reviewed.',
];

/** Oldest first. The store sorts newest first when it answers. */
export function buildDemoHistory(employeeId: string, now: number): ActivityItem[] {
  const seeds: Seed[] = [...HANDWRITTEN];

  // 12 deactivate/reactivate pairs (ends active, like the employee) and 12 reveals.
  for (let i = 0; i < 12; i += 1) {
    const day = 380 - i * 28;
    const actor = i % 2 === 0 ? SANJAY : ANITA;
    seeds.push([day, 'USER_DEACTIVATED', actor, REASONS[i % REASONS.length] ?? null, [change('accountStatus', 'active', 'inactive')]]);
    seeds.push([day - 5, 'USER_REACTIVATED', actor, null, [change('accountStatus', 'inactive', 'active')]]);
    seeds.push([day - 9, 'AADHAAR_REVEALED', SANJAY, null, null]);
  }

  return seeds
    .map(([daysAgo, action, actor, reason, changes], i): ActivityItem => ({
      id: `a-demo-${employeeId}-${i}`,
      at: new Date(now - daysAgo * DAY - (i % 7) * 3_600_000 - 17 * 60_000).toISOString(),
      action,
      actorName: actor,
      reason,
      changes,
    }))
    .sort((a, b) => a.at.localeCompare(b.at));
}
