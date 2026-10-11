/** Money, number and date helpers. Latin digits everywhere; dates always in Asia/Kolkata. */

const TIME_ZONE = 'Asia/Kolkata';

const inrWhole = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 0 });
const inrPaise = new Intl.NumberFormat('en-IN', {
  style: 'currency',
  currency: 'INR',
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});
const plainNumber = new Intl.NumberFormat('en-IN');

const dateFormat = new Intl.DateTimeFormat('en-GB', {
  timeZone: TIME_ZONE,
  day: '2-digit',
  month: '2-digit',
  year: 'numeric',
});
const timeFormat = new Intl.DateTimeFormat('en-GB', {
  timeZone: TIME_ZONE,
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
});

/** Integer paise in, "₹1,25,000" out. Paise are shown only when non-zero. */
export function formatMoney(paise: number): string {
  return paise % 100 === 0 ? inrWhole.format(paise / 100) : inrPaise.format(paise / 100);
}

export function formatNumber(value: number): string {
  return plainNumber.format(value);
}

function parse(iso: string): Date | null {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? null : d;
}

const DATE_ONLY = /^(\d{4})-(\d{2})-(\d{2})$/;

/** dd/MM/yyyy in Asia/Kolkata. A date-only value ("2024-03-05") is a calendar date, so it is not shifted. */
export function formatDate(iso: string): string {
  const m = DATE_ONLY.exec(iso);
  if (m) return `${m[3]}/${m[2]}/${m[1]}`;
  const d = parse(iso);
  return d ? dateFormat.format(d) : '—';
}

/** formatDate for optional values: null/empty shows an em dash. */
export function formatDateOrDash(iso: string | null | undefined): string {
  return iso ? formatDate(iso) : '—';
}

/** HH:mm (24 hour) */
export function formatTime(iso: string): string {
  const d = parse(iso);
  return d ? timeFormat.format(d) : '—';
}

export function formatDateTime(iso: string): string {
  const d = parse(iso);
  return d ? `${dateFormat.format(d)} ${timeFormat.format(d)}` : '—';
}
