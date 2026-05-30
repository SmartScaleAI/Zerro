import { Check, Minus } from "lucide-react"
import { GradientField } from "@/components/ui/gradient-field"

// Server Component — a factual comparison table. Rendered as real <table> markup
// so it's machine-readable (crawlers + AI tools parse it directly) and needs no
// client JS. Competitor cells are deliberately conservative and objective: input
// type, output, where processing runs, keys, platform, pricing model — no
// disparagement. Framed as Zerro's positioning.

type Cell = string | boolean

type Row = {
  label: string
  zerro: Cell
  wispr: Cell
  loom: Cell
}

const COLUMNS = ["Zerro", "Wispr Flow", "Loom"] as const

const rows: Row[] = [
  {
    label: "Primary input",
    zerro: "Screen + voice",
    wispr: "Voice",
    loom: "Screen + voice",
  },
  {
    label: "Output",
    zerro: "Structured prompt",
    wispr: "Dictated text",
    loom: "Video link",
  },
  {
    label: "Built for AI coding agents",
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
    zerro: "One-time ($39)",
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
      <Minus
        className="mx-auto h-5 w-5 text-white/25"
        strokeWidth={2}
        aria-label="No"
      />
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
        <p className="text-xs font-medium tracking-[0.18em] text-primary uppercase">
          How it compares
        </p>
        <h2 className="max-w-2xl text-3xl leading-tight font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl">
          A different category.
        </h2>
        <p className="max-w-xl text-base text-muted-foreground">
          Dictation tools give you text. Screen recorders give you a video.
          Zerro gives your agent a prompt.
        </p>
      </div>

      {/* pt gives the gradient field room to rise above the table's top edge */}
      <div className="relative pt-16">
        {/* Ambient gradient blur spotlight behind the highlighted Zerro column —
            the same multi-color GradientField used in the hero. The table panel
            is opaque, so the glow can't sit *behind* it; instead it's layered
            *inside* the panel as an overlay (z-0 within the panel, below the table
            text at z-10). It's confined tightly to the Zerro column (first data
            column, whose center sits ~45% from the left) and masked to a soft
            ellipse no wider than the column, so the glow pools behind that one
            column without bleeding color onto the neighbouring columns or the
            panel edges. No blend mode — a contained pool reads cleaner than an
            additive smear across the whole surface. */}
        <div className="relative z-10 overflow-hidden rounded-2xl border border-white/10 bg-[#202022]/80 backdrop-blur-sm">
          <GradientField
            edgeFade="vertical"
            solid={false}
            className="-top-12 -bottom-12 left-[45%] z-0 w-[80%] -translate-x-1/2 opacity-100 blur-[80px]"
            style={{
              maskImage:
                "radial-gradient(ellipse 60% 85% at 50% 45%, black 30%, transparent 80%)",
              WebkitMaskImage:
                "radial-gradient(ellipse 60% 85% at 50% 45%, black 30%, transparent 80%)",
            }}
          />
          <table className="relative z-10 w-full border-collapse text-left">
            <thead>
              <tr className="border-b border-white/10">
                <th className="px-5 py-4 text-sm font-medium text-white/50">
                  <span className="sr-only">Feature</span>
                </th>
                {COLUMNS.map((col, i) => (
                  <th
                    key={col}
                    className={
                      i === 0
                        ? "border-x border-t-2 border-white/15 border-t-white/70 bg-white/[0.12] px-5 py-5 text-center text-sm font-semibold text-white"
                        : "px-5 py-4 text-center text-sm font-medium text-white/50"
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
                  className="border-b border-white/10 last:border-b-0"
                >
                  <th
                    scope="row"
                    className="px-5 py-4 text-sm font-normal text-white/80"
                  >
                    {row.label}
                  </th>
                  <td className="border-x border-white/15 bg-white/[0.06] px-5 py-4 text-center">
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

      <p className="mt-4 text-center text-xs text-muted-foreground">
        Comparison reflects Zerro&apos;s positioning. Competitor capabilities
        change over time — check each product for current details.
      </p>
    </section>
  )
}

export default Comparison
