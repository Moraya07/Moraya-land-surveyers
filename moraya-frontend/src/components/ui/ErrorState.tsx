import { useI18n } from '../../i18n';
import { Button } from './Button';

interface ErrorStateProps {
  message: string;
  onRetry: () => void;
  retrying?: boolean;
}

export function ErrorState({ message, onRetry, retrying = false }: ErrorStateProps) {
  const { t } = useI18n();
  return (
    <div role="alert" className="rounded-lg border border-border bg-surface px-4 py-8 text-center">
      <p className="text-text">{message}</p>
      <div className="mt-4">
        <Button loading={retrying} onClick={onRetry}>
          {t('common.retry')}
        </Button>
      </div>
    </div>
  );
}
