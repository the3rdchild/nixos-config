import type { CSSProperties } from "react";

export interface SegmentedOption<T> {
  value: T;
  label: string;
  /** Optional second line, e.g. what a fan profile is for. */
  sub?: string;
}

export interface SegmentedProps<T> {
  options: SegmentedOption<T>[];
  value: T | undefined;
  onChange: (value: T) => void;
  /** Tint for the selected segment; defaults to the stylesheet accent. */
  accent?: string;
  label?: string;
}

/**
 * The pill row used for lighting modes and fan profiles.
 *
 * Plain DOM on purpose. The component-library version of this row renders
 * each button inside its own <iframe> with its own WebGL context — four of
 * those for four fan profiles is four GPU contexts for a radio group, on
 * the very iGPU whose thermals this page exists to manage.
 */
export function Segmented<T extends string | number>({
  options,
  value,
  onChange,
  accent,
  label,
}: SegmentedProps<T>) {
  return (
    <div className="seg" role="radiogroup" aria-label={label}>
      {options.map((o) => {
        const on = o.value === value;
        return (
          <button
            key={String(o.value)}
            type="button"
            role="radio"
            aria-checked={on}
            className={`seg__btn${on ? " is-on" : ""}`}
            style={on && accent ? ({ "--seg-accent": accent } as CSSProperties) : undefined}
            onClick={() => onChange(o.value)}
          >
            <span className="seg__label">{o.label}</span>
            {o.sub ? <span className="seg__sub">{o.sub}</span> : null}
          </button>
        );
      })}
    </div>
  );
}
