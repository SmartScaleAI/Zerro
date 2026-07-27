"use client"

import { DownloadButton } from "@/components/download-button"
import { Button } from "@/components/ui/button"
import { AnimatedBorder } from "@/components/ui/animated-border"
import { PlayCircle } from "lucide-react"
import { AppleIcon } from "@/components/ui/apple-icon"
import { motion, useReducedMotion } from "motion/react"
import { track } from "@/lib/analytics"

const Hero = () => {
  const reduceMotion = useReducedMotion()

  return (
    <motion.div
      className="flex flex-col items-center justify-center px-4"
      initial={{ opacity: 0, y: 20 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, amount: 0.15 }}
      transition={{ duration: 0.5, ease: [0.25, 0.46, 0.45, 0.94] }}
    >
      <section className="flex w-full max-w-4xl flex-col items-center text-center">
        {/* Category eyebrow. Two-tone pill: the chip files Zerro into a
            category at a glance, the label says what kind of app it is.
            Asymmetric padding keeps the chip tight against the left edge. */}
        <div className="inline-flex items-center gap-[9px] rounded-full border border-white/[0.14] bg-white/[0.035] py-[5px] pr-[14px] pl-[6px] text-[12.5px] text-foreground/80 backdrop-blur-[8px]">
          <span className="rounded-full bg-foreground/10 px-2 py-[2px] text-[10.5px] font-bold tracking-[0.06em] text-foreground uppercase">
            Mac app
          </span>
          Lightweight, lives in your menu bar
        </div>
        <h1 className="mt-5 text-5xl leading-[1.05] font-medium tracking-tighter text-foreground md:text-6xl lg:text-[72px]">
          Talk to your screen.
          <br />
          <motion.span
            className="bg-clip-text text-transparent bg-[length:200%_auto]"
            style={{
              backgroundImage:
                "linear-gradient(to right, rgb(135,160,215), rgb(115,190,165), rgb(180,140,215), rgb(125,190,150), rgb(135,160,215))",
            }}
            animate={
              reduceMotion
                ? undefined
                : { backgroundPosition: ["200% center", "-200% center"] }
            }
            transition={{
              repeat: Number.POSITIVE_INFINITY,
              duration: 9,
              ease: "linear",
            }}
          >
            Zerro does the work.
          </motion.span>
        </h1>
        <p className="mt-4 max-w-2xl text-base leading-relaxed text-muted-foreground md:text-lg">
          Record your screen, explain what you want, and get it done faster.
        </p>
        <div className="mt-6 flex flex-row flex-wrap items-center justify-center gap-3">
          <DownloadButton
            placement="hero"
            className="relative gap-2 rounded-full hover:border-border hover:bg-muted hover:text-foreground hover:backdrop-blur-md dark:hover:border-input dark:hover:bg-input/30 dark:hover:text-foreground"
            size="lg"
          >
            <AnimatedBorder />
            <AppleIcon className="h-4 w-4" />
            Try it for free
          </DownloadButton>
          <Button
            variant="outline"
            size="lg"
            className="gap-2 rounded-full"
            nativeButton={false}
            render={<a href="#how-it-works" />}
            onClick={() =>
              track("hero_secondary_clicked", { target: "how_it_works" })
            }
          >
            <PlayCircle className="h-4 w-4" />
            Watch it work
          </Button>
        </div>
        <p className="mt-4 text-sm text-muted-foreground">
          {"Apple Silicon · Signed & notarized"}
        </p>
      </section>
    </motion.div>
  )
}

export default Hero
