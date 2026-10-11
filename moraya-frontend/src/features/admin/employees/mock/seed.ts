import { verhoeffCheckDigit } from '../aadhaar';
import type { AccountStatus, Permission, Role } from '../types';

/** What the mock server keeps. `aadhaar` is a fake 12-digit number and never leaves this module tree unmasked. */
export interface StoredEmployee {
  id: string;
  employeeId: string;
  name: string;
  loginEmail: string;
  designation: string | null;
  role: Role;
  accountStatus: AccountStatus;
  dateOfBirth: string | null;
  dateOfJoining: string | null;
  aadhaar: string;
  permissions: Permission[];
  lastLoginAt: string | null;
  createdAt: string;
  createdByName: string | null;
  updatedAt: string;
  version: number;
}

type Row = [
  name: string,
  designation: string,
  role: Role,
  status: AccountStatus,
  dob: string,
  joined: string,
  permissions: Permission[],
];

const SUB_A: Permission[] = ['employee_management', 'site_management', 'verification'];
const SUB_B: Permission[] = ['verification', 'income_management', 'report_view'];

const ROWS: Row[] = [
  ['Sanjay Moraya', 'Proprietor', 'main_admin', 'active', '1974-03-12', '2012-04-01', []],
  ['Anita Deshmukh', 'Office Manager', 'sub_admin', 'active', '1985-07-21', '2016-06-15', SUB_A],
  ['Prakash Kulkarni', 'Senior Surveyor', 'sub_admin', 'active', '1980-11-02', '2014-01-10', SUB_B],
  ['Vikram Patil', 'Surveyor', 'worker', 'active', '1992-01-18', '2019-08-05', []],
  ['Suresh Jadhav', 'Senior Surveyor', 'worker', 'active', '1983-09-30', '2015-03-02', []],
  ['Meena Shinde', 'Assistant', 'worker', 'active', '1995-05-14', '2021-02-01', []],
  ['Amit Kale', 'Draftsman', 'worker', 'active', '1990-12-09', '2018-10-22', []],
  ['Pooja Bhosale', 'Surveyor', 'worker', 'active', '1996-04-27', '2022-07-11', []],
  ['Rahul Gaikwad', 'Surveyor', 'worker', 'inactive', '1991-08-03', '2017-05-19', []],
  ['Snehal Pawar', 'Draftsman', 'worker', 'active', '1993-02-25', '2020-01-13', []],
  ['Nitin More', 'Senior Surveyor', 'worker', 'active', '1982-10-16', '2013-09-09', []],
  ['Kavita Salunkhe', 'Assistant', 'worker', 'inactive', '1994-06-08', '2019-11-04', []],
  ['Ganesh Chavan', 'Surveyor', 'worker', 'active', '1989-03-29', '2016-12-01', []],
  ['Rohini Kadam', 'Surveyor', 'worker', 'active', '1997-09-12', '2023-03-20', []],
  ['Sachin Waghmare', 'Assistant', 'worker', 'active', '1998-01-05', '2023-09-04', []],
  ['Yogesh Thorat', 'Draftsman', 'worker', 'inactive', '1988-07-23', '2015-08-17', []],
  ['Swati Ghule', 'Surveyor', 'worker', 'active', '1995-11-19', '2021-06-28', []],
  ['Mahesh Lokhande', 'Senior Surveyor', 'worker', 'active', '1981-05-06', '2014-04-14', []],
  ['Deepak Nikam', 'Surveyor', 'worker', 'revoked', '1990-02-11', '2018-01-29', []],
  ['Shweta Joshi', 'Assistant', 'worker', 'active', '1999-08-31', '2024-02-12', []],
  ['Tushar Mane', 'Draftsman', 'worker', 'active', '1993-12-15', '2020-10-05', []],
];

export const MAIN_ADMIN_ID = idFor(1);
/** The Sub-Admin (with employee_management) used by the `?mock=sub` scenario. */
export const SUB_ADMIN_ID = idFor(2);

function idFor(n: number): string {
  return `7c1d0000-0000-4000-8000-${String(n).padStart(12, '0')}`;
}

/** Obviously fake, Verhoeff-valid numbers: 9999 0000 0NNx. Real Aadhaar numbers never start with 9999 0000. */
export function fakeAadhaar(n: number): string {
  const base = `99990000${String(n).padStart(3, '0')}`;
  return `${base}${verhoeffCheckDigit(base)}`;
}

function slug(name: string): string {
  return name.toLowerCase().replace(/[^a-z]+/g, '.');
}

export function buildSeed(): StoredEmployee[] {
  const now = Date.now();
  return ROWS.map(([name, designation, role, accountStatus, dob, joined, permissions], i) => {
    const n = i + 1;
    const createdAt = `${joined}T06:30:00.000Z`;
    return {
      id: idFor(n),
      employeeId: `MLS-${String(n).padStart(3, '0')}`,
      name,
      loginEmail: `${slug(name)}@example.com`,
      designation,
      role,
      accountStatus,
      dateOfBirth: dob,
      dateOfJoining: joined,
      aadhaar: fakeAadhaar(n),
      permissions,
      lastLoginAt:
        accountStatus === 'active' ? new Date(now - ((n * 7) % 48) * 3_600_000 - 600_000).toISOString() : null,
      createdAt,
      createdByName: n === 1 ? null : 'Sanjay Moraya',
      updatedAt: createdAt,
      version: 1,
    };
  });
}
