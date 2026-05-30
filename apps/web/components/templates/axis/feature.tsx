"use client"

import { motion } from "motion/react"
import { Crop, Mic, Cpu, ClipboardPaste, Check } from "lucide-react"

type Step = {
  n: string
  icon: React.ComponentType<{ className?: string; strokeWidth?: number }>
  title: string
  description: string
  visual: React.ReactNode
}

// Mini visual mockups for each step
const SelectRegionVisual = () => (
  <div className="absolute inset-0 flex items-center justify-center bg-gradient-to-br from-neutral-900 to-neutral-950 p-4">
    {/* Simulated app window behind */}
    <div className="absolute inset-4 rounded-md border border-white/5 bg-white/[0.02]">
      <div className="flex items-center gap-1 border-b border-white/5 px-2 py-1.5">
        <span className="h-1.5 w-1.5 rounded-full bg-white/15" />
        <span className="h-1.5 w-1.5 rounded-full bg-white/15" />
        <span className="h-1.5 w-1.5 rounded-full bg-white/15" />
      </div>
      <div className="space-y-2 p-3">
        <div className="h-1.5 w-12 rounded bg-white/10" />
        <div className="h-1.5 w-20 rounded bg-white/5" />
        <div className="h-1.5 w-16 rounded bg-white/5" />
      </div>
    </div>
    {/* Selection rectangle with crosshair */}
    <div className="relative h-[55%] w-[55%] border-2 border-dashed border-white/40">
      <div className="absolute -top-1 -left-1 h-2 w-2 bg-white/70" />
      <div className="absolute -top-1 -right-1 h-2 w-2 bg-white/70" />
      <div className="absolute -bottom-1 -left-1 h-2 w-2 bg-white/70" />
      <div className="absolute -right-1 -bottom-1 h-2 w-2 bg-white/70" />
      <div className="absolute inset-0 flex items-center justify-center">
        <div className="rounded bg-black/60 px-1.5 py-0.5 font-mono text-[8px] text-white/80">
          480 × 320
        </div>
      </div>
    </div>
  </div>
)

const NarrateVisual = () => (
  <div className="absolute inset-0 flex items-center justify-center bg-gradient-to-br from-neutral-900 to-neutral-950 p-4">
    {/* Recording pill mockup */}
    <div className="flex items-center gap-2 rounded-full bg-neutral-800 px-3 py-2 shadow-lg ring-1 ring-white/10">
      <span className="h-1.5 w-1.5 rounded-full bg-red-500" />
      <span className="font-mono text-[10px] text-white/90 tabular-nums">
        0:59 / 3:00
      </span>
      <div className="flex h-3 items-end gap-[1px]">
        {[0.5, 0.8, 0.4, 0.9, 0.6, 0.3, 0.7, 0.5].map((h, i) => (
          <motion.span
            key={i}
            className="w-[1.5px] rounded-full bg-white/60"
            animate={{ scaleY: [h, h * 0.4, h * 1.1, h] }}
            transition={{
              duration: 0.9,
              repeat: Infinity,
              delay: i * 0.08,
              ease: "easeInOut",
            }}
            style={{ height: `${h * 100}%`, transformOrigin: "bottom" }}
          />
        ))}
      </div>
    </div>
  </div>
)

const ProcessingVisual = () => (
  <div className="absolute inset-0 flex items-center justify-center bg-gradient-to-br from-neutral-900 to-neutral-950 p-4">
    <div className="flex items-center gap-2 rounded-full bg-neutral-800 px-3 py-2 shadow-lg ring-1 ring-white/10">
      <motion.div
        animate={{ rotate: 360 }}
        transition={{ duration: 1.4, repeat: Infinity, ease: "linear" }}
        className="h-3 w-3 rounded-full border-2 border-white/15 border-t-white/70"
      />
      <span className="text-[10px] font-medium text-white/90">
        Building your prompt…
      </span>
    </div>
  </div>
)

const PastePromptVisual = () => (
  <div className="absolute inset-0 flex items-center justify-center bg-gradient-to-br from-neutral-900 to-neutral-950 p-3">
    {/* Mini prompt card */}
    <div className="w-full max-w-[180px] overflow-hidden rounded-md border border-white/10 bg-neutral-900 shadow-lg">
      <div className="flex items-center justify-between border-b border-white/10 px-2 py-1">
        <div className="flex items-center gap-1">
          <Check className="h-2.5 w-2.5 text-white/80" strokeWidth={3} />
          <span className="font-mono text-[8px] tracking-wider text-white/50 uppercase">
            Ready
          </span>
        </div>
        <span className="text-[8px] text-white/50">⌘V</span>
      </div>
      <div className="space-y-1 p-2 font-mono text-[7px] leading-tight">
        <div className="font-semibold text-white/90">## Context</div>
        <div className="h-1 w-full rounded bg-white/10" />
        <div className="h-1 w-3/4 rounded bg-white/10" />
        <div className="pt-0.5 font-semibold text-white/90">## Request</div>
        <div className="h-1 w-full rounded bg-white/10" />
        <div className="h-1 w-2/3 rounded bg-white/10" />
      </div>
    </div>
  </div>
)

const steps: Step[] = [
  {
    n: "01",
    icon: Crop,
    title: "Select a region",
    description:
      "Hit the hotkey, drag to frame the part of your screen you want the agent to see. Native macOS crosshair, no window switching.",
    visual: <SelectRegionVisual />,
  },
  {
    n: "02",
    icon: Mic,
    title: "Dictate what you want",
    description:
      "Talk it through like you'd explain it to a teammate. Point at things, change your mind, ramble. Zerro records up to 3 minutes.",
    visual: <NarrateVisual />,
  },
  {
    n: "03",
    icon: Cpu,
    title: "Zerro processes locally",
    description:
      "Audio gets isolated and frames get downsampled on your machine. Then a single API call turns it into a structured prompt.",
    visual: <ProcessingVisual />,
  },
  {
    n: "04",
    icon: ClipboardPaste,
    title: "Paste the prompt",
    description:
      "Markdown prompt lands on your clipboard, ready to drop into Cursor, Windsurf, v0, or wherever you ship from.",
    visual: <PastePromptVisual />,
  },
]

const Feature = () => {
  return (
    <motion.section
      id="how-it-works"
      className="relative mx-auto max-w-7xl px-4"
      initial={{ opacity: 0, y: 20 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, amount: 0.15 }}
      transition={{ duration: 0.5, ease: [0.25, 0.46, 0.45, 0.94] }}
    >
      <div className="mb-12 text-center lg:mb-20">
        <p className="mb-3 text-xs font-medium tracking-[0.18em] text-primary uppercase">
          How it works
        </p>
        <h2 className="mx-auto max-w-2xl text-3xl leading-tight font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl">
          Record. Speak. Copy.
        </h2>
        <p className="mx-auto mt-4 max-w-xl text-base text-muted-foreground">
          Think voice dictation — but instead of plain text, you get a
          structured prompt. No new app to learn; the whole flow runs from the
          menu bar.
        </p>
      </div>

      <div className="grid grid-cols-1 gap-px overflow-hidden rounded-2xl border border-border bg-border md:grid-cols-2 lg:grid-cols-4">
        {steps.map((step, i) => {
          const Icon = step.icon
          return (
            <motion.div
              key={step.n}
              initial={{ opacity: 0, y: 16 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: 0.4 }}
              transition={{
                duration: 0.4,
                delay: i * 0.08,
                ease: [0.25, 0.46, 0.45, 0.94],
              }}
              className="relative flex flex-col gap-6 bg-background p-6 lg:p-8"
            >
              <div className="flex items-center justify-between">
                <span className="font-mono text-xs tracking-wider text-muted-foreground">
                  {step.n}
                </span>
                <Icon className="h-5 w-5 text-primary" strokeWidth={1.6} />
              </div>

              <div className="relative aspect-[4/3] w-full overflow-hidden rounded-lg border border-border">
                {step.visual}
              </div>

              <div className="flex flex-col gap-2">
                <h3 className="text-lg font-medium tracking-tight text-foreground">
                  {step.title}
                </h3>
                <p className="text-sm leading-relaxed text-muted-foreground">
                  {step.description}
                </p>
              </div>
            </motion.div>
          )
        })}
      </div>
    </motion.section>
  )
}

export default Feature
