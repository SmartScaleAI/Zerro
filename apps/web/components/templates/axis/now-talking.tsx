"use client"

import { motion, useInView, animate } from "motion/react"
import { Mic, Keyboard } from "lucide-react"
import { useEffect, useRef, useState } from "react"

const TYPING_WPM = 40
const SPEAKING_WPM = 150

// A single animated WPM "race" row: an icon, a label, a fill bar that grows to
// `value/max`, and a counter that ticks up to `value`. Animates when in view.
const SpeedRow = ({
  icon: Icon,
  label,
  value,
  max,
  active,
  delay,
  isFast = false,
}: {
  icon: React.ComponentType<{ className?: string; strokeWidth?: number }>
  label: string
  value: number
  max: number
  active: boolean
  delay: number
  isFast?: boolean
}) => {
  const [count, setCount] = useState(0)

  useEffect(() => {
    if (!active) return
    const controls = animate(0, value, {
      duration: 1.4,
      delay,
      ease: [0.25, 0.46, 0.45, 0.94],
      onUpdate: (v) => setCount(Math.round(v)),
    })
    return () => controls.stop()
  }, [active, value, delay])

  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2 text-sm font-medium text-foreground">
          <Icon
            className={
              isFast ? "h-4 w-4 text-primary" : "h-4 w-4 text-muted-foreground"
            }
            strokeWidth={1.8}
          />
          {label}
        </div>
        <div className="font-mono text-sm text-muted-foreground tabular-nums">
          <span className={isFast ? "text-primary" : "text-foreground"}>
            {count}
          </span>{" "}
          wpm
        </div>
      </div>
      <div className="h-2.5 w-full overflow-hidden rounded-full bg-muted">
        <motion.div
          className={
            isFast
              ? "h-full rounded-full bg-primary"
              : "h-full rounded-full bg-muted-foreground/50"
          }
          initial={{ width: 0 }}
          animate={{ width: active ? `${(value / max) * 100}%` : 0 }}
          transition={{ duration: 1.4, delay, ease: [0.25, 0.46, 0.45, 0.94] }}
        />
      </div>
    </div>
  )
}

const SpeedContrast = () => {
  const ref = useRef<HTMLDivElement>(null)
  const inView = useInView(ref, { once: true, amount: 0.4 })

  return (
    <div
      ref={ref}
      className="flex w-full flex-col gap-7 rounded-2xl border border-border bg-card p-8 lg:p-10"
    >
      <p className="text-xs font-medium tracking-[0.18em] text-muted-foreground uppercase">
        Words per minute
      </p>
      <SpeedRow
        icon={Keyboard}
        label="Typing"
        value={TYPING_WPM}
        max={SPEAKING_WPM}
        active={inView}
        delay={0.1}
      />
      <SpeedRow
        icon={Mic}
        label="Speaking"
        value={SPEAKING_WPM}
        max={SPEAKING_WPM}
        active={inView}
        delay={0.35}
        isFast
      />
      <p className="text-sm leading-relaxed text-muted-foreground">
        You speak nearly{" "}
        <span className="font-medium text-foreground">4× faster</span> than you
        type. The keyboard has been the bottleneck all along.
      </p>
    </div>
  )
}

const NowTalking = () => {
  return (
    <motion.section
      id="now-talking"
      className="relative mx-auto max-w-7xl px-4"
      initial={{ opacity: 0, y: 20 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, amount: 0.15 }}
      transition={{ duration: 0.5, ease: [0.25, 0.46, 0.45, 0.94] }}
    >
      <div className="grid grid-cols-1 items-center gap-10 lg:grid-cols-2 lg:gap-16">
        {/* Left column — copy */}
        <div className="flex flex-col gap-5 text-center lg:text-left">
          <p className="text-xs font-medium tracking-[0.18em] text-primary uppercase">
            The shift
          </p>

          <h2 className="text-3xl leading-tight font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl">
            Now we&apos;re talking.
          </h2>

          <div className="space-y-5 text-base leading-relaxed text-muted-foreground lg:text-lg">
            <p>
              The keyboard was never the point — it was just the only interface
              we had. As agents get better at acting on what you actually mean,
              typing out every instruction by hand starts to feel like the
              bottleneck it always was.
            </p>
            <p>
              You think faster than you type. You talk faster than you think.
              Voice closes that gap — and dictation is becoming the default.
              Zerro is built for that future: less typing, more talking.
            </p>
          </div>
        </div>

        {/* Right column — speed contrast illustration */}
        <SpeedContrast />
      </div>
    </motion.section>
  )
}

export default NowTalking
