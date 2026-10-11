import { useId, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';

export interface TabDef {
  id: string;
  label: string;
  content: ReactNode;
}

/** WAI-ARIA tabs: roving tabindex, Left/Right/Home/End, only the active panel is rendered. */
export function Tabs({ label, tabs }: { label: string; tabs: TabDef[] }) {
  const baseId = useId();
  const [selectedId, setSelectedId] = useState<string | undefined>(tabs[0]?.id);
  const buttons = useRef<Array<HTMLButtonElement | null>>([]);

  const found = tabs.findIndex((tab) => tab.id === selectedId);
  const activeIndex = found === -1 ? 0 : found;
  const active = tabs[activeIndex];
  if (!active) return null;

  const select = (index: number) => {
    const tab = tabs[index];
    if (!tab) return;
    setSelectedId(tab.id);
    buttons.current[index]?.focus();
  };

  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    const last = tabs.length - 1;
    let next: number | null = null;
    if (e.key === 'ArrowRight') next = activeIndex === last ? 0 : activeIndex + 1;
    else if (e.key === 'ArrowLeft') next = activeIndex === 0 ? last : activeIndex - 1;
    else if (e.key === 'Home') next = 0;
    else if (e.key === 'End') next = last;
    if (next === null) return;
    e.preventDefault();
    select(next);
  };

  return (
    <div>
      <div
        role="tablist"
        aria-label={label}
        onKeyDown={onKeyDown}
        className="flex overflow-x-auto border-b border-border"
      >
        {tabs.map((tab, i) => (
          <button
            key={tab.id}
            ref={(el) => {
              buttons.current[i] = el;
            }}
            type="button"
            role="tab"
            id={`${baseId}-tab-${tab.id}`}
            aria-selected={i === activeIndex}
            aria-controls={`${baseId}-panel-${tab.id}`}
            tabIndex={i === activeIndex ? 0 : -1}
            onClick={() => setSelectedId(tab.id)}
            className="tab"
          >
            {tab.label}
          </button>
        ))}
      </div>
      <div
        role="tabpanel"
        id={`${baseId}-panel-${active.id}`}
        aria-labelledby={`${baseId}-tab-${active.id}`}
        tabIndex={0}
        className="pt-4"
      >
        {active.content}
      </div>
    </div>
  );
}
