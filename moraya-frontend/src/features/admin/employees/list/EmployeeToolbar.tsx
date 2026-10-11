import { SearchInput } from '../../../../components/ui/SearchInput';
import { Select } from '../../../../components/ui/Select';
import { useI18n, type DictKey } from '../../../../i18n';
import { ROLE_LABEL } from '../labels';
import type { Role, StatusFilter } from '../types';
import { ROLE_OPTIONS, STATUS_OPTIONS } from './useEmployeeListParams';

const STATUS_OPTION_LABEL: Record<StatusFilter, DictKey> = {
  active: 'acct.active',
  all: 'filter.all',
  inactive: 'acct.inactive',
  revoked: 'acct.revoked',
};

interface EmployeeToolbarProps {
  q: string;
  status: StatusFilter;
  role: Role | null;
  /** True when search, status or role differs from its default: shows "Clear filters". */
  filtersActive: boolean;
  onQuery: (q: string) => void;
  onStatus: (status: StatusFilter) => void;
  onRole: (role: Role | null) => void;
  onClear: () => void;
}

/** Search (debounced, 2+ characters), Status, Role and "Clear filters". Values come from and go to the URL. */
export function EmployeeToolbar({
  q,
  status,
  role,
  filtersActive,
  onQuery,
  onStatus,
  onRole,
  onClear,
}: EmployeeToolbarProps) {
  const { t } = useI18n();

  return (
    <div className="flex flex-col gap-3 md:flex-row md:flex-wrap md:items-end">
      <div className="md:min-w-64 md:flex-1">
        <SearchInput value={q} onChange={onQuery} label={t('emp.search')} placeholder={t('emp.search')} delay={400} />
      </div>

      <div className="grid grid-cols-2 gap-3 md:flex md:gap-3">
        <div className="min-w-0 md:w-44">
          <Select
            label={t('filter.status')}
            className="!h-11"
            value={status}
            onChange={(e) => {
              const next = STATUS_OPTIONS.find((s) => s === e.target.value);
              if (next) onStatus(next);
            }}
          >
            {STATUS_OPTIONS.map((s) => (
              <option key={s} value={s}>
                {t(STATUS_OPTION_LABEL[s])}
              </option>
            ))}
          </Select>
        </div>
        <div className="min-w-0 md:w-44">
          <Select
            label={t('filter.role')}
            className="!h-11"
            value={role ?? ''}
            onChange={(e) => onRole(ROLE_OPTIONS.find((r) => r === e.target.value) ?? null)}
          >
            <option value="">{t('filter.all')}</option>
            {ROLE_OPTIONS.map((r) => (
              <option key={r} value={r}>
                {t(ROLE_LABEL[r])}
              </option>
            ))}
          </Select>
        </div>
      </div>

      {filtersActive && (
        <button type="button" onClick={onClear} className="link-action inline-flex min-h-11 items-center self-start px-1 text-sm md:self-end">
          {t('filter.clear')}
        </button>
      )}
    </div>
  );
}
