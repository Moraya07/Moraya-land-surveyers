import { Button } from '../../../../components/ui/Button';
import { Chip } from '../../../../components/ui/Chip';
import { useI18n } from '../../../../i18n';
import { formatDateOrDash, formatDateTime } from '../../../../lib/format';
import { useEmployeeActions } from '../actions/useEmployeeActions';
import { PERMISSION_LABEL, PERMISSION_ORDER } from '../labels';
import { AccountStatusBadge, RoleBadge } from '../list/EmployeeBadges';
import type { EmployeeDetail } from '../types';
import { EMPTY_VALUE, ProfileGroup, ProfileRow } from './ProfileGroup';
import { SensitiveAadhaar } from './SensitiveAadhaar';

/** Read-only profile. Single column on phones; two columns from `lg`. */
export function ProfileTab({ employee }: { employee: EmployeeDetail }) {
  const { t } = useI18n();
  // The Change permissions dialog is the Prompt 2 dialog, opened through the same hook as the header menu.
  const { items, dialogs } = useEmployeeActions(employee);
  const openPermissions = employee.capabilities.canChangePermissions
    ? items.find((item) => item.key === 'changePermissions')
    : undefined;

  const permissions = PERMISSION_ORDER.filter((p) => employee.permissions.includes(p));

  return (
    <div className="grid gap-4 lg:grid-cols-2 lg:items-start">
      <ProfileGroup title={t('group.employment')}>
        <ProfileRow label={t('field.srNo')}>
          <span className="tabular-nums">{employee.srNo}</span>
        </ProfileRow>
        <ProfileRow label={t('field.employeeId')}>
          <span dir="ltr" className="inline-block">
            {employee.employeeId}
          </span>
        </ProfileRow>
        <ProfileRow label={t('field.name')}>{employee.name}</ProfileRow>
        <ProfileRow label={t('field.designation')}>{employee.designation || EMPTY_VALUE}</ProfileRow>
        <ProfileRow label={t('field.dob')}>{formatDateOrDash(employee.dateOfBirth)}</ProfileRow>
        <ProfileRow label={t('field.doj')}>{formatDateOrDash(employee.dateOfJoining)}</ProfileRow>
      </ProfileGroup>

      <ProfileGroup title={t('group.access')}>
        <ProfileRow label={t('field.loginEmail')}>
          <span dir="ltr" className="inline-block break-all">
            {employee.loginEmail}
          </span>
        </ProfileRow>
        <ProfileRow label={t('field.role')}>
          <RoleBadge role={employee.role} />
        </ProfileRow>
        <ProfileRow label={t('field.status')}>
          <AccountStatusBadge status={employee.accountStatus} />
        </ProfileRow>
        <ProfileRow label={t('field.lastLogin')}>
          {employee.lastLoginAt ? formatDateTime(employee.lastLoginAt) : t('field.never')}
        </ProfileRow>
        {employee.role === 'sub_admin' && (
          <ProfileRow label={t('field.permissions')}>
            <div className="space-y-3">
              {permissions.length > 0 ? (
                <ul className="flex flex-wrap gap-1.5">
                  {permissions.map((p) => (
                    <li key={p}>
                      <Chip>{t(PERMISSION_LABEL[p])}</Chip>
                    </li>
                  ))}
                </ul>
              ) : (
                <span>{EMPTY_VALUE}</span>
              )}
              {openPermissions && (
                <Button variant="secondary" onClick={openPermissions.onSelect}>
                  {t('act.changePerms')}
                </Button>
              )}
            </div>
          </ProfileRow>
        )}
      </ProfileGroup>

      <ProfileGroup title={t('group.identity')}>
        <ProfileRow label={t('field.aadhaar')}>
          <SensitiveAadhaar
            key={employee.id}
            employeeId={employee.id}
            masked={employee.aadhaarMasked}
            canReveal={employee.capabilities.canRevealAadhaar}
            version={employee.version}
            updatedAt={employee.updatedAt}
          />
        </ProfileRow>
      </ProfileGroup>

      <ProfileGroup title={t('group.record')}>
        <ProfileRow label={t('field.createdAt')}>{formatDateTime(employee.createdAt)}</ProfileRow>
        <ProfileRow label={t('field.createdBy')}>{employee.createdByName || EMPTY_VALUE}</ProfileRow>
        <ProfileRow label={t('field.updatedAt')}>{formatDateTime(employee.updatedAt)}</ProfileRow>
      </ProfileGroup>

      {dialogs}
    </div>
  );
}
