import { Check } from "lucide-react"
import { GradientField } from "@/components/ui/gradient-field"

// Server Component — a factual comparison table. Rendered as real <table> markup
// so it's machine-readable (crawlers + AI tools parse it directly) and needs no
// client JS. Competitor cells are deliberately conservative and objective: input
// type, output, where processing runs, keys, platform, pricing model — no
// disparagement. Framed as Zerro's positioning.
//
// Visually it's styled like a pricing table: each product is a vertical lane with
// dashed row separators, and the first lane (Zerro) reads as an elevated card that
// rises above the header and drops below the last row to hold a CTA. That elevated
// card is a decorative, aria-hidden sibling of the <table>, positioned over the
// first product column — so the semantic table stays intact for crawlers/AI.

type Cell = string | boolean

type Row = {
  label: string
  sub?: string
  zerro: Cell
  wispr: Cell
  loom: Cell
}

const COLUMNS = ["Zerro", "Wispr Flow", "Loom"] as const

// Column template (must match the highlight card's horizontal band below):
// label gutter 32%, then three equal product columns of 22.666% each. The first
// product column therefore spans 32% → 54.666% (center 43.333%, width 22.666%).
const COL_TEMPLATE = ["32%", "22.666%", "22.666%", "22.666%"] as const
const HILITE_LEFT = "43.333%"
const HILITE_WIDTH = "22.666%"

const rows: Row[] = [
  {
    label: "Primary input",
    zerro: "Screen + voice",
    wispr: "Voice",
    loom: "Screen + voice",
  },
  {
    label: "Output",
    zerro: "Ready-to-use output",
    wispr: "Dictated text",
    loom: "Video link",
  },
  {
    label: "Formats output for the task",
    sub: "Prompt, message, snippet, or doc.",
    zerro: true,
    wispr: false,
    loom: false,
  },
  {
    label: "Local-first processing",
    zerro: true,
    wispr: false,
    loom: false,
  },
  {
    label: "Bring your own API keys",
    zerro: true,
    wispr: false,
    loom: false,
  },
  {
    label: "Native macOS app",
    zerro: true,
    wispr: true,
    loom: false,
  },
  {
    label: "Pricing model",
    sub: "Pay once, own it forever.",
    zerro: "One-time ($69)",
    wispr: "Subscription",
    loom: "Subscription",
  },
]

function CellValue({ value, emphasize }: { value: Cell; emphasize?: boolean }) {
  if (typeof value === "boolean") {
    return value ? (
      <Check
        className={
          emphasize
            ? "mx-auto h-5 w-5 text-primary"
            : "mx-auto h-5 w-5 text-white/55"
        }
        strokeWidth={2.2}
        aria-label="Yes"
      />
    ) : (
      <span className="text-white/25" aria-label="No">
        &mdash;
      </span>
    )
  }
  return (
    <span
      className={
        emphasize ? "text-sm font-medium text-white" : "text-sm text-white/55"
      }
    >
      {value}
    </span>
  )
}

const Comparison = () => {
  return (
    <section id="comparison" className="relative mx-auto max-w-5xl px-4">
      <div className="flex flex-col items-center gap-3 text-center">
        <p className="text-sm font-medium tracking-[0.18em] text-primary uppercase">
          How it compares
        </p>
        <h2 className="max-w-2xl text-3xl leading-tight font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl">
          A different category.
        </h2>
        <p className="max-w-xl text-base text-muted-foreground">
          Dictation tools give you text. Screen recorders give you a video.
          Zerro gives you the finished result — a prompt, message, snippet, or
          document, or a straight answer to your question.
        </p>
      </div>

      {/* pt leaves room for the floating "Recommended" pill above the card;
          pb leaves room for the CTA footer at the bottom of the card.
          The scroll container is capped at the viewport width (minus the px-4
          page gutter) with a *definite* max-width — a percentage like w-full
          can't resolve during intrinsic sizing, so the 640px table would
          otherwise widen the whole page. With a definite cap the table scrolls
          inside this box on narrow screens instead. */}
      <div className="relative max-w-[calc(100vw-2rem)] overflow-x-auto pt-10 pb-12 lg:max-w-none">
        <div className="relative mx-auto w-full min-w-[640px]">
          {/* Elevated Zerro lane — a decorative card behind the first product
              column. Spans that column's horizontal band (43.333% center,
              22.666% wide) and hugs the table vertically: its top sits flush
              with the header row and its bottom wraps the CTA footer, with no
              extra space above or below. aria-hidden: it carries no data — the
              <table> below is the source of truth. */}
          <div
            aria-hidden="true"
            className="absolute top-0 bottom-0 z-0 -translate-x-1/2 overflow-hidden rounded-3xl bg-white/[0.06] shadow-[0_40px_100px_-20px_rgba(0,0,0,0.55)] ring-1 ring-white/10"
            style={{ left: HILITE_LEFT, width: HILITE_WIDTH }}
          >
            {/* Ambient multi-color spotlight pooled inside the Zerro card — the
                same GradientField used in the hero, masked to a soft ellipse so
                it glows from within the card rather than smearing the edges. */}
            <GradientField
              edgeFade="vertical"
              solid={false}
              className="inset-0 opacity-100 blur-[80px]"
              style={{
                maskImage:
                  "radial-gradient(ellipse 70% 60% at 50% 35%, black 30%, transparent 80%)",
                WebkitMaskImage:
                  "radial-gradient(ellipse 70% 60% at 50% 35%, black 30%, transparent 80%)",
              }}
            />
          </div>

          <table className="relative z-10 w-full table-fixed border-collapse text-left">
            <colgroup>
              {COL_TEMPLATE.map((w, i) => (
                <col key={i} style={{ width: w }} />
              ))}
            </colgroup>
            <thead>
              <tr className="border-b border-dashed border-white/10">
                <th className="px-5 py-4">
                  <span className="sr-only">Feature</span>
                </th>
                {COLUMNS.map((col, i) => (
                  <th
                    key={col}
                    className={
                      i === 0
                        ? "px-5 py-5 text-center text-sm font-semibold text-white"
                        : "px-5 py-5 text-center text-sm font-medium text-white/50"
                    }
                    scope="col"
                  >
                    {i === 0 ? (
                      <span className="inline-flex items-center gap-2">
                        <span className="h-1.5 w-1.5 rounded-full bg-white" />
                        {col}
                      </span>
                    ) : (
                      col
                    )}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr
                  key={row.label}
                  className="border-b border-dashed border-white/10 last:border-b-0"
                >
                  <th
                    scope="row"
                    className="px-5 py-4 align-top text-sm font-normal text-white/80"
                  >
                    {row.label}
                    {row.sub && (
                      <span className="mt-1 block text-sm font-normal text-white/40">
                        {row.sub}
                      </span>
                    )}
                  </th>
                  <td className="px-5 py-4 text-center">
                    <CellValue value={row.zerro} emphasize />
                  </td>
                  <td className="px-5 py-4 text-center">
                    <CellValue value={row.wispr} />
                  </td>
                  <td className="px-5 py-4 text-center">
                    <CellValue value={row.loom} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <p className="text-center text-sm text-muted-foreground">
        Comparison reflects Zerro&apos;s positioning. Competitor capabilities
        change over time — check each product for current details.
      </p>
    </section>
  )
}

export default Comparison
