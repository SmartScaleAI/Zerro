import { cn } from "@/lib/utils";

interface GradientFieldProps {
  /** Classes for the outer container (positioning, size, blur, mask). */
  className?: string;
  /** Inline styles for the outer container (e.g. maskImage). */
  style?: React.CSSProperties;
  /**
   * Edge-fade direction for blending into the page background.
   * "bottom" fades only the bottom (use at the top of the page);
   * "vertical" fades top + bottom + sides (constrained, mid-page);
   * "vertical-only" fades top + bottom but NOT the sides (full-bleed, edge-to-edge);
   * "none" no fade — the field fills its box as a solid gradient surface.
   */
  edgeFade?: "bottom" | "vertical" | "vertical-only" | "none";
  /**
   * When true, paints an opaque base color behind the blobs so the field reads
   * as a solid gradient surface (no page background showing through the gaps).
   */
  solid?: boolean;
}

const EDGE_FADE: Record<NonNullable<GradientFieldProps["edgeFade"]>, string> = {
  bottom: `
    linear-gradient(to right, var(--background), transparent 18%, transparent 82%, var(--background)),
    linear-gradient(to bottom, transparent 60%, var(--background))
  `,
  vertical: `
    linear-gradient(to right, var(--background), transparent 18%, transparent 82%, var(--background)),
    linear-gradient(to bottom, var(--background), transparent 18%, transparent 82%, var(--background))
  `,
  "vertical-only": `
    linear-gradient(to bottom, var(--background), transparent 22%, transparent 78%, var(--background))
  `,
  none: "none",
};

const SOLID_BASE_LIGHT =
  "linear-gradient(135deg, #fafbff 0%, #f5fff9 50%, #fdf8ff 100%)";
const SOLID_BASE_DARK =
  "linear-gradient(135deg, #060810 0%, #04100a 50%, #0a0612 100%)";

/**
 * Ambient multi-color gradient field — soft blue/teal/purple/green corner blobs
 * over the page background, with theme-aware colors and an edge-fade overlay that
 * dissolves the field into `--background` so there are no hard box edges.
 * Positioning and size are controlled by the caller via `className`/`style`.
 */
export function GradientField({
  className,
  style,
  edgeFade = "vertical",
  solid = false,
}: GradientFieldProps) {
  const blobsLight = `
    radial-gradient(ellipse 55% 55% at 25% 22%, rgba(120, 160, 255, 0.55), transparent 70%),
    radial-gradient(ellipse 52% 52% at 75% 22%, rgba(90, 215, 175, 0.50), transparent 70%),
    radial-gradient(ellipse 54% 54% at 25% 78%, rgba(190, 130, 255, 0.48), transparent 70%),
    radial-gradient(ellipse 50% 50% at 75% 78%, rgba(120, 215, 150, 0.50), transparent 70%),
    radial-gradient(ellipse 50% 50% at 50% 50%, rgba(255, 255, 255, 0.30), transparent 72%)
  `;
  const blobsDark = `
    radial-gradient(ellipse 55% 55% at 25% 22%, rgba(60, 100, 200, 0.27), transparent 70%),
    radial-gradient(ellipse 52% 52% at 75% 22%, rgba(40, 160, 130, 0.25), transparent 70%),
    radial-gradient(ellipse 54% 54% at 25% 78%, rgba(140, 60, 200, 0.24), transparent 70%),
    radial-gradient(ellipse 50% 50% at 75% 78%, rgba(60, 140, 100, 0.25), transparent 70%),
    radial-gradient(ellipse 50% 50% at 50% 50%, rgba(100, 120, 180, 0.17), transparent 72%)
  `;

  return (
    <div
      aria-hidden="true"
      className={cn("pointer-events-none absolute", className)}
      style={style}
    >
      {/* Light mode */}
      <div
        className="absolute inset-0 block dark:hidden"
        style={{
          background: solid ? `${blobsLight}, ${SOLID_BASE_LIGHT}` : blobsLight,
        }}
      />
      {/* Dark mode */}
      <div
        className="absolute inset-0 hidden dark:block"
        style={{
          background: solid ? `${blobsDark}, ${SOLID_BASE_DARK}` : blobsDark,
        }}
      />
      {/* Edge-fade overlay — dissolves residual color into the page background */}
      {edgeFade !== "none" && (
        <div
          className="absolute inset-0"
          style={{ background: EDGE_FADE[edgeFade] }}
        />
      )}
    </div>
  );
}
