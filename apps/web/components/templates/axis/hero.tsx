"use client"

import { DownloadButton } from "@/components/download-button"
import { Button } from "@/components/ui/button"
import { AnimatedBorder } from "@/components/ui/animated-border"
import { Check, Copy, X, Square, ChevronDown, PlayCircle } from "lucide-react"
import { AppleIcon } from "@/components/ui/apple-icon"
import { motion, AnimatePresence } from "motion/react"
import { useEffect, useState } from "react"

type PillState = "recording" | "processing" | "ready"

const stateSequence: PillState[] = ["recording", "processing", "ready"]

const stateDurations: Record<PillState, number> = {
  recording: 3000,
  processing: 2200,
  ready: 3000,
}

const MorphingPill = () => {
  const [stateIndex, setStateIndex] = useState(0)
  const currentState = stateSequence[stateIndex]

  useEffect(() => {
    const timeout = setTimeout(() => {
      setStateIndex((i) => (i + 1) % stateSequence.length)
    }, stateDurations[currentState])
    return () => clearTimeout(timeout)
  }, [stateIndex, currentState])

  return (
    <div className="relative flex h-14 w-[480px] max-w-full items-center justify-center overflow-hidden rounded-full bg-neutral-900 px-4 shadow-[0_20px_60px_-10px_rgba(120,135,150,0.35),0_0_0_1px_rgba(255,255,255,0.08)] sm:px-5">
      <AnimatePresence mode="wait">
        {currentState === "recording" && (
          <motion.div
            key="recording"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.2 }}
            className="flex w-full items-center justify-between text-white"
          >
            <div className="flex items-center gap-2 sm:gap-3">
              <motion.div
                className="h-2.5 w-2.5 shrink-0 rounded-full bg-red-500"
                animate={{ opacity: [1, 0.35, 1] }}
                transition={{ duration: 1.2, repeat: Infinity }}
              />
              <span className="font-mono text-sm tracking-tight whitespace-nowrap tabular-nums">
                0:02{" "}
                {/* On mobile the waveform is hidden, so show a "Recording"
                    label next to the running timer instead of the "/ 3:00"
                    max-duration; desktop keeps "/ 3:00" alongside the waveform. */}
                <span className="text-white/40 sm:hidden">Recording</span>
                <span className="hidden text-white/40 sm:inline">/ 3:00</span>
              </span>
              {/* Waveform is decorative and the widest flexible element — hide it
                  on mobile so the timer + Cancel + Stop fit inside the pill. */}
              <div className="hidden h-5 items-center gap-[3px] sm:flex">
                {[
                  0.45, 0.55, 0.9, 1.0, 0.5, 0.6, 0.45, 0.55, 0.85, 1.0, 0.5,
                  0.95, 0.6, 1.0, 1.0, 0.55, 0.9, 0.6, 0.5, 0.85, 1.0, 0.55,
                  0.5, 0.9, 0.6, 0.5, 0.45,
                ].map((h, i) => (
                  <motion.span
                    key={i}
                    className="w-[2px] rounded-full bg-white/70"
                    animate={{ scaleY: [h, h * 0.7, h, h] }}
                    transition={{
                      duration: 0.9,
                      repeat: Infinity,
                      delay: i * 0.06,
                      ease: "easeInOut",
                    }}
                    style={{ height: `${h * 100}%`, transformOrigin: "center" }}
                  />
                ))}
              </div>
            </div>
            <div className="flex shrink-0 items-center gap-2 sm:gap-4">
              <button className="flex items-center gap-1.5 text-sm text-white/60 transition-colors hover:text-white/90">
                <X className="h-4 w-4" />
                <span className="hidden sm:inline">Cancel</span>
              </button>
              <button className="flex shrink-0 items-center gap-2 rounded-full bg-red-500 px-3 py-1.5 text-sm font-medium text-white transition-colors hover:bg-red-500/90 sm:px-4">
                <Square className="h-3 w-3 fill-current" />
                Stop
              </button>
            </div>
          </motion.div>
        )}

        {currentState === "processing" && (
          <motion.div
            key="processing"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.2 }}
            className="flex w-full items-center justify-between text-white"
          >
            <div className="flex items-center gap-3">
              <motion.div
                animate={{ rotate: 360 }}
                transition={{ duration: 1.4, repeat: Infinity, ease: "linear" }}
                className="h-4 w-4 rounded-full border-2 border-white/20 border-t-white/80"
              />
              <span className="text-sm font-medium">Generating your response…</span>
            </div>
            <button className="flex items-center gap-1.5 text-sm text-white/60 transition-colors hover:text-white/90">
              <X className="h-4 w-4" />
              Cancel
            </button>
          </motion.div>
        )}

        {currentState === "ready" && (
          <motion.div
            key="ready"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.2 }}
            className="flex w-full items-center justify-between text-white"
          >
            <div className="flex items-center gap-3">
              <motion.div
                initial={{ scale: 0 }}
                animate={{ scale: 1 }}
                transition={{ type: "spring", stiffness: 500, damping: 20 }}
                className="flex h-5 w-5 items-center justify-center rounded-full bg-green-500"
              >
                <Check className="h-3 w-3 text-white" strokeWidth={3} />
              </motion.div>
              <span className="text-sm font-medium">Ready to paste</span>
            </div>
            <div className="flex items-center gap-4">
              <button className="flex items-center gap-2 rounded-full bg-white px-4 py-1.5 text-sm font-medium text-neutral-900 transition-colors hover:bg-white/90">
                <Copy className="h-3.5 w-3.5" />
                Copy
              </button>
              <button className="flex items-center gap-1 text-sm text-white/60 transition-colors hover:text-white/90">
                View
                <ChevronDown className="h-4 w-4" />
              </button>
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  )
}

const Hero = () => {
  return (
    <motion.div
      className="flex flex-col items-center justify-center px-4"
      initial={{ opacity: 0, y: 20 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, amount: 0.15 }}
      transition={{ duration: 0.5, ease: [0.25, 0.46, 0.45, 0.94] }}
    >
      <section className="flex w-full max-w-4xl flex-col items-center text-center">
        <h1 className="text-5xl leading-[1.05] font-medium tracking-tighter text-foreground md:text-6xl lg:text-[85px]">
          Give your AI
          <br />
          <motion.span
            className="bg-clip-text text-transparent bg-[length:200%_auto]"
            style={{
              backgroundImage:
                "linear-gradient(to right, rgb(135,160,215), rgb(115,190,165), rgb(180,140,215), rgb(125,190,150), rgb(135,160,215))",
            }}
            animate={{ backgroundPosition: ["200% center", "-200% center"] }}
            transition={{
              repeat: Number.POSITIVE_INFINITY,
              duration: 9,
              ease: "linear",
            }}
          >
            eyes and ears.
          </motion.span>
        </h1>
        <p className="mt-5 max-w-lg text-base leading-relaxed text-muted-foreground md:text-lg lg:max-w-2xl">
          Record your screen, explain what you want, get what you need.
        </p>
        <div className="mt-7 flex flex-row flex-wrap items-center justify-center gap-3">
          <DownloadButton
            placement="hero"
            className="relative gap-2 rounded-full hover:border-border hover:bg-muted hover:text-foreground hover:backdrop-blur-md dark:hover:border-input dark:hover:bg-input/30 dark:hover:text-foreground"
            size="lg"
          >
            <AnimatedBorder />
            <AppleIcon className="h-4 w-4" />
            Download for Mac
          </DownloadButton>
          <Button
            variant="outline"
            size="lg"
            className="gap-2 rounded-full"
            nativeButton={false}
            render={<a href="#how-it-works" />}
          >
            <PlayCircle className="h-4 w-4" />
            How it works
          </Button>
        </div>
        <p className="mt-4 text-sm text-muted-foreground">
          {"Apple Silicon · Signed & notarized"}
        </p>
      </section>

      {/* The morphing pill — sits directly under the CTAs */}
      <div className="relative mt-12 flex w-full max-w-4xl items-center justify-center lg:mt-16">
        {/* Ambient glow */}
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-0 flex items-center justify-center"
        >
          <div
            className="h-[280px] w-[280px] rounded-full opacity-30 blur-[80px]"
            style={{
              background:
                "radial-gradient(circle at center, rgba(150,165,180,0.5), rgba(150,165,180,0) 70%)",
            }}
          />
        </div>
        <MorphingPill />
      </div>
    </motion.div>
  )
}

export default Hero
