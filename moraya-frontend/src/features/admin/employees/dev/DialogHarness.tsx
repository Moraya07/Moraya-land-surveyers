import { useState } from 'react';
import { Button } from '../../../../components/ui/Button';
import { PageHeader } from '../../../../components/ui/PageHeader';
import { Select } from '../../../../components/ui/Select';
import { useI18n } from '../../../../i18n';
import { useEmployeeActions } from '../actions/useEmployeeActions';
import { useEmployee, useEmployees } from '../hooks';
import { forceNextError, type ForcedError } from '../mock/store';

const FORCED: ForcedError[] = [
  'LAST_MAIN_ADMIN_PROTECTED',
  'INVALID_STATE',
  'VERSION_CONFLICT',
  'FORBIDDEN',
  'NOT_FOUND',
  'VALIDATION_ERROR',
];

/**
 * Dev-only (mock mode): open each action dialog for a mock employee before the real pages exist.
 * Developer text, so it is not translated. Never part of a production build (see routes.tsx).
 */
export default function DialogHarness() {
  const { t } = useI18n();
  const list = useEmployees({ page: 1, pageSize: 50 });
  const [id, setId] = useState('');
  const detail = useEmployee(id || undefined);
  const { items, dialogs, isProtectedMainAdmin } = useEmployeeActions(detail.data);
  const [forced, setForced] = useState<ForcedError | ''>('');

  return (
    <div className="max-w-xl space-y-5">
      <PageHeader title="Action dialogs (dev harness)" subtitle="Mock mode only. Use ?mock=sub to try the Sub-Admin view." />

      <Select label="Employee" value={id} onChange={(e) => setId(e.target.value)}>
        <option value="">Select…</option>
        {list.data?.items.map((e) => (
          <option key={e.id} value={e.id}>
            {e.employeeId} · {e.name} · {e.role} · {e.accountStatus}
          </option>
        ))}
      </Select>

      <Select
        label="Make the NEXT write fail with"
        value={forced}
        onChange={(e) => {
          const next = FORCED.find((code) => code === e.target.value) ?? null;
          setForced(next ?? '');
          forceNextError(next);
        }}
      >
        <option value="">Nothing (normal behaviour)</option>
        {FORCED.map((code) => (
          <option key={code} value={code}>
            {code}
          </option>
        ))}
      </Select>

      {detail.isPending && id && <p role="status">{t('common.loading')}</p>}
      {detail.data && (
        <section aria-label="Available actions" className="space-y-3">
          {isProtectedMainAdmin && <p className="text-sm text-text-muted">{t('protected.main')}</p>}
          {!isProtectedMainAdmin && items.length === 0 && <p className="text-sm text-text-muted">No actions available.</p>}
          <div className="flex flex-wrap gap-2">
            {items.map((item) => (
              <Button key={item.key} variant={item.danger ? 'danger' : 'secondary'} onClick={item.onSelect}>
                {t(item.labelKey)}
              </Button>
            ))}
          </div>
          <p className="text-sm text-text-muted">
            Status: {detail.data.accountStatus} · Role: {detail.data.role}
          </p>
        </section>
      )}
      {dialogs}
    </div>
  );
}
