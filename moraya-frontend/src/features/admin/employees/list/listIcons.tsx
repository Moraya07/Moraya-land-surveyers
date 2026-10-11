import type { SVGProps } from 'react';

// Small icons used only by the Employee List. Same drawing rules as components/icons.tsx.
type IconProps = SVGProps<SVGSVGElement>;
const base = {
  width: 20,
  height: 20,
  viewBox: '0 0 24 24',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 2,
  strokeLinecap: 'round',
  strokeLinejoin: 'round',
  'aria-hidden': true,
  focusable: false,
} as const;

export const MoreVerticalIcon = (p: IconProps) => (
  <svg {...base} {...p}>
    <circle cx="12" cy="5" r="1.2" />
    <circle cx="12" cy="12" r="1.2" />
    <circle cx="12" cy="19" r="1.2" />
  </svg>
);
export const ChevronUpIcon = (p: IconProps) => (
  <svg {...base} {...p}>
    <path d="M6 15l6-6 6 6" />
  </svg>
);
export const ChevronsUpDownIcon = (p: IconProps) => (
  <svg {...base} {...p}>
    <path d="M8 9l4-4 4 4M8 15l4 4 4-4" />
  </svg>
);
export const PlusIcon = (p: IconProps) => (
  <svg {...base} {...p}>
    <path d="M12 5v14M5 12h14" />
  </svg>
);
