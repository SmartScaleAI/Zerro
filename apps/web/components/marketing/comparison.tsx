import {
  Camera,
  ClipboardCheck,
  Crop,
  Images,
  Keyboard,
  Mic,
  type LucideIcon,
} from "lucide-react"
import { GradientField } from "@/components/ui/gradient-field"

// Server Component — a before/after contrast. Zerro isn't positioned against
// other products here; the comparison is the manual workflow people already use
// (screenshot, paste, type out a description) vs. presenting the screen and
// saying it. Plain heading + list markup so it stays machine-readable, no
// client JS.

type Step = {
  icon: LucideIcon
  text: string
}

type Column = {
  /** Heading id — labels the column's step list for assistive tech. */
  id: string
  label: string
  steps: Step[]
  footnote: string
}

const BEFORE: Column = {
  id: "comparison-before",
  label: "The way you do it now",
  steps: [
    { icon: Camera, text: "Screenshot a few parts of your screen" },
    { icon: Images, text: "Paste them into your coding agent" },
    { icon: Keyboard, text: "Type out, in detail, what you want" },
  ],
  footnote: "Writing that description out is the slow, tedious part.",
}

const AFTER: Column = {
  id: "comparison-after",
  label: "With Zerro",
  steps: [
    { icon: Crop, text: "Hotkey, then record your screen" },
    { icon: Mic, text: "Talk through what you want, out loud" },
    {
      icon: ClipboardCheck,
      text: "Finished result in seconds",
    },
  ],
  footnote: "Say it instead of typing it. Same context, a fraction of the effort.",
}

function ColumnCard({
  column,
  featured,
}: {
  column: Column
  featured?: boolean
}) {
  return (
    <div
      className={
        featured
          ? // Featured-lane treatment: teal accent ring (the pricing license card),
            // with the glow split into four directional shadows whose hues
            // mirror the GradientField's corner blobs (blue top-left, teal
            // top-right, purple bottom-left, green bottom-right) — so the glow
            // reads as the card's own gradient bleeding outward.
            "relative overflow-hidden rounded-3xl p-6 ring-1 ring-[#28a082]/40 shadow-[0_0_0_1px_rgba(40,160,130,0.22),-28px_-20px_80px_-24px_rgba(60,100,200,0.3),28px_-20px_80px_-24px_rgba(40,160,130,0.3),-28px_20px_80px_-24px_rgba(140,60,200,0.28),28px_20px_80px_-24px_rgba(60,140,100,0.3)] sm:p-8"
          : // Opaque fill (page background + the same 4% white tint) and a
            // raised z-index so the featured card's glow — painted later in
            // the DOM — can't bleed over or show through this card.
            "relative z-10 rounded-3xl bg-background bg-[linear-gradient(rgba(255,255,255,0.04),rgba(255,255,255,0.04))] p-6 ring-1 ring-white/15 sm:p-8"
      }
    >
      {featured && (
        <>
          {/* Same solid gradient surface the pricing section uses as its
              backdrop, filling the card... */}
          <GradientField solid edgeFade="none" className="inset-0" />
          {/* ...muted by a matte glass layer over it — the pricing BYOK card's
              frosted recipe — so the gradient reads as a soft tint rather than
              at full vibrance. */}
          <div
            aria-hidden="true"
            className="absolute inset-0 bg-black/30 backdrop-blur-2xl shadow-[inset_0_1px_0_rgba(255,255,255,0.08)]"
          />
        </>
      )}

      <div className="relative">
        <h3
          id={column.id}
          className={
            featured
              ? "inline-flex items-center gap-2 text-lg font-semibold tracking-tight text-white"
              : "text-lg font-medium tracking-tight text-white/80"
          }
        >
          {featured && (
            <span aria-hidden="true" className="h-1.5 w-1.5 rounded-full bg-white" />
          )}
          {column.label}
        </h3>

        <ol
          aria-labelledby={column.id}
          className="mt-4 flex flex-col divide-y divide-dashed divide-white/10"
        >
          {column.steps.map((step) => (
            <li key={step.text} className="flex items-start gap-3.5 py-4">
              <step.icon
                aria-hidden="true"
                className={
                  featured
                    ? "mt-0.5 h-5 w-5 shrink-0 text-primary"
                    : "mt-0.5 h-5 w-5 shrink-0 text-white/60"
                }
                strokeWidth={2}
              />
              <span
                className={
                  featured
                    ? "text-sm leading-relaxed font-medium text-white"
                    : "text-sm leading-relaxed text-white/85"
                }
              >
                {step.text}
              </span>
            </li>
          ))}
        </ol>

        <p
          className={
            featured
              ? "border-t border-dashed border-white/10 pt-4 text-sm text-white/60"
              : "border-t border-dashed border-white/10 pt-4 text-sm text-white/50"
          }
        >
          {column.footnote}
        </p>
      </div>
    </div>
  )
}

const Comparison = () => {
  return (
    <section id="comparison" className="relative mx-auto max-w-5xl px-4">
      <div className="flex flex-col items-center gap-3 text-center">
        <p className="text-sm font-medium tracking-[0.18em] text-primary uppercase">
          The difference
        </p>
        <h2 className="max-w-2xl text-3xl leading-tight font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl">
          Screenshots miss the point.
        </h2>
        <p className="max-w-xl text-base text-muted-foreground">
          Screenshots can show the AI your screen, but they can&apos;t point out what you&apos;re focused on or spell out what you want changed.
        </p>
      </div>

      <div className="mt-10 grid grid-cols-1 gap-6 lg:mt-12 lg:grid-cols-2">
        <ColumnCard column={BEFORE} />
        <ColumnCard column={AFTER} featured />
      </div>
    </section>
  )
}

export default Comparison
