const MAX = 8; // matches the server-side validation in acer-ec-web.nix

export interface PaletteEditorProps {
  colors: string[];
  onChange: (colors: string[]) => void;
}

/** The swatch strip palette mode steps through. 1–8 colours, like the API. */
export function PaletteEditor({ colors, onChange }: PaletteEditorProps) {
  const set = (i: number, hex: string) =>
    onChange(colors.map((c, j) => (j === i ? hex : c)));

  return (
    <div className="pal">
      {colors.map((c, i) => (
        <div className="pal__slot" key={i} style={{ background: c }}>
          <input
            type="color"
            value={c}
            aria-label={`Swatch ${i + 1}`}
            onChange={(e) => set(i, e.target.value)}
          />
          {colors.length > 1 ? (
            <button
              type="button"
              className="pal__drop"
              aria-label={`Remove swatch ${i + 1}`}
              onClick={() => onChange(colors.filter((_, j) => j !== i))}
            >
              ×
            </button>
          ) : null}
        </div>
      ))}
      {colors.length < MAX ? (
        <button
          type="button"
          className="pal__add"
          aria-label="Add swatch"
          onClick={() => onChange([...colors, colors[colors.length - 1] ?? "#ffffff"])}
        >
          +
        </button>
      ) : null}
    </div>
  );
}
