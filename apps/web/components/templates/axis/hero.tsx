"use client"

import { Button } from "@/components/ui/button"
import { AnimatedBorder } from "@/components/ui/animated-border"
import { Play, Check, Copy, X, Square, ChevronDown } from "lucide-react"
import { AppleIcon } from "@/components/ui/apple-icon"
import { DOWNLOAD_URL } from "@/lib/site-config"
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
    <div className="relative flex h-14 w-[480px] max-w-full items-center justify-center overflow-hidden rounded-full bg-neutral-900 px-5 shadow-[0_20px_60px_-10px_rgba(120,135,150,0.35),0_0_0_1px_rgba(255,255,255,0.08)]">
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
            <div className="flex items-center gap-3">
              <motion.div
                className="h-2.5 w-2.5 rounded-full bg-red-500"
                animate={{ opacity: [1, 0.35, 1] }}
                transition={{ duration: 1.2, repeat: Infinity }}
              />
              <span className="font-mono text-sm tracking-tight tabular-nums">
                0:02 <span className="text-white/40">/ 3:00</span>
              </span>
              <div className="flex h-5 items-center gap-[3px]">
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
            <div className="flex items-center gap-4">
              <button className="flex items-center gap-1.5 text-sm text-white/60 transition-colors hover:text-white/90">
                <X className="h-4 w-4" />
                Cancel
              </button>
              <button className="flex items-center gap-2 rounded-full bg-red-500 px-4 py-1.5 text-sm font-medium text-white transition-colors hover:bg-red-500/90">
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
              <span className="text-sm font-medium">Building your prompt…</span>
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
              <span className="text-sm font-medium">Prompt ready</span>
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
      <section className="flex w-full max-w-4xl flex-col items-center gap-7 text-center">
        <h1 className="text-4xl leading-[1.05] font-medium tracking-tighter text-foreground md:text-6xl lg:text-7xl">
          Give your agent
          <br />
          <motion.span
            className="bg-gradient-to-r from-foreground via-primary to-foreground bg-[length:200%_auto] bg-clip-text text-transparent"
            animate={{ backgroundPosition: ["200% center", "-200% center"] }}
            transition={{
              repeat: Number.POSITIVE_INFINITY,
              duration: 7,
              ease: "linear",
            }}
          >
            eyes and ears.
          </motion.span>
        </h1>
        <p className="max-w-2xl text-base leading-relaxed text-muted-foreground md:text-lg">
          Record your screen, dictate what you want, and Zerro turns it into
          exactly what you need — a structured prompt for your AI agent, or a
          plain-language explanation of what&apos;s on screen.
        </p>
        <div className="flex flex-row flex-wrap items-center justify-center gap-3">
          <Button
            className="relative gap-2 rounded-full hover:border-border hover:bg-muted hover:text-foreground hover:backdrop-blur-md dark:hover:border-input dark:hover:bg-input/30 dark:hover:text-foreground"
            size="lg"
            nativeButton={false}
            render={<a href={DOWNLOAD_URL} download />}
          >
            <AnimatedBorder />
            <AppleIcon className="h-4 w-4" />
            Download for macOS
          </Button>
          <Button className="gap-2 rounded-full" variant="outline" size="lg">
            <Play className="h-4 w-4" />
            Watch it work
          </Button>
        </div>
        <p className="text-xs text-muted-foreground">
          v1.0 · Apple Silicon · Signed &amp; notarized
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
