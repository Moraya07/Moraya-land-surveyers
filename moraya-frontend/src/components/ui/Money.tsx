import { formatMoney } from '../../lib/format';

/** Integer paise → "₹1,25,000". Tabular numerals so columns line up. */
export function Money({ paise, className = '' }: { paise: number; className?: string }) {
  return <span className={`whitespace-nowrap tabular-nums ${className}`}>{formatMoney(paise)}</span>;
}
