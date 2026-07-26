"use client"

import { useDeferredValue, useRef, useState } from "react"
import { motion } from "motion/react"
import { Play } from "lucide-react"

// Each use case gets its own walkthrough video. Only the scrolling-capture clip
// exists today; the other tabs reuse it as a placeholder until their own
// recordings land, so swapping in a real file is a one-line change here.
type UseCase = {
  id: string
  label: string
  src: string
  poster: string
  /** Describes the clip for the play button's accessible label. */
  playLabel: string
}

const PLACEHOLDER_SRC = "/videos/zerro-walkthrough.mp4"
const PLACEHOLDER_POSTER = "/videos/zerro-walkthrough-poster.jpg"

const USE_CASES: UseCase[] = [
  {
    id: "scrolling-capture",
    label: "Scrolling capture",
    src: PLACEHOLDER_SRC,
    poster: PLACEHOLDER_POSTER,
    playLabel: "Play the scrolling capture walkthrough",
  },
  {
    id: "compare-tabs",
    label: "Compare tabs",
    src: "/videos/compare-tabs.mp4",
    poster: "/videos/compare-tabs-poster.jpg",
    playLabel: "Play the compare tabs walkthrough",
  },
  {
    id: "explain-a-video",
    label: "Explain a video",
    src: "/videos/explain-a-video.mp4",
    poster: "/videos/explain-a-video-poster.jpg",
    playLabel: "Play the explain a video walkthrough",
  },
  {
    id: "get-unstuck",
    label: "Get unstuck",
    src: "/videos/get-unstuck.mp4",
    poster: "/videos/get-unstuck-poster.jpg",
    playLabel: "Play the get unstuck walkthrough",
  },
]

const Feature = () => {
  const videoRef = useRef<HTMLVideoElement>(null)
  const [hasStarted, setHasStarted] = useState(false)
  const [useCaseId, setUseCaseId] = useState(USE_CASES[0].id)

  // Remounting the <video> is the expensive part of a tab switch. Deferring it
  // lets the tab highlight repaint immediately instead of stalling on the
  // video teardown + metadata load.
  const deferredUseCaseId = useDeferredValue(useCaseId)
  const useCase =
    USE_CASES.find((u) => u.id === deferredUseCaseId) ?? USE_CASES[0]

  return (
    <motion.section
      id="how-it-works"
      className="relative mx-auto max-w-7xl px-4 scroll-mt-24"
      initial={{ opacity: 0, y: 20 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, amount: 0.15 }}
      transition={{ duration: 0.5, ease: [0.25, 0.46, 0.45, 0.94] }}
    >
      <div className="mb-6 text-center lg:mb-12">
        <p className="mb-3 text-sm font-medium tracking-[0.18em] text-primary uppercase">
          How it works
        </p>
        <h2 className="mx-auto max-w-2xl text-3xl leading-tight font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl">
          Record. Speak. Done.
        </h2>
        <p className="mx-auto mt-4 max-w-xl text-base text-muted-foreground">
          Explain what you need and get a ready-to-use result in seconds.
        </p>
      </div>

      {/* Use-case switcher — centered directly above the video. Switching tabs
          swaps the clip and drops back to the poster + play button. */}
      <div className="mb-5 flex justify-center">
        <div
          role="group"
          aria-label="Show walkthrough for an example use case"
          className="grid w-full max-w-[360px] grid-cols-2 gap-1 rounded-2xl bg-foreground/[0.06] p-1 ring-1 ring-foreground/10 sm:flex sm:w-auto sm:max-w-none sm:flex-wrap sm:items-center sm:justify-center sm:gap-0.5 sm:rounded-full sm:p-0.5"
        >
          {USE_CASES.map((u) => {
            const isActive = u.id === useCaseId
            return (
              <button
                key={u.id}
                type="button"
                onClick={() => {
                  if (u.id === useCaseId) return
                  setUseCaseId(u.id)
                  setHasStarted(false)
                }}
                aria-pressed={isActive}
                className={`relative rounded-full px-3 py-1.5 text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-foreground/40 sm:py-1 ${
                  isActive
                    ? "text-background"
                    : "text-muted-foreground hover:text-foreground"
                }`}
              >
                {/* One shared highlight that slides between tabs. A single
                    element can't double-render the way two crossfading
                    per-button backgrounds could. */}
                {isActive && (
                  <motion.span
                    layoutId="use-case-highlight"
                    className="absolute inset-0 rounded-full bg-foreground"
                    transition={{ type: "spring", stiffness: 500, damping: 40 }}
                  />
                )}
                <span className="relative">{u.label}</span>
              </button>
            )
          })}
        </div>
      </div>

      <motion.div
        initial={{ opacity: 0, y: 16 }}
        whileInView={{ opacity: 1, y: 0 }}
        viewport={{ once: true, amount: 0.3 }}
        transition={{ duration: 0.4, ease: [0.25, 0.46, 0.45, 0.94] }}
        className="relative mx-auto max-w-[992px] overflow-hidden rounded-2xl border border-border"
      >
        <video
          // Keyed by use case so switching tabs remounts a fresh, unplayed
          // element rather than leaving the previous clip's playhead in place.
          key={useCase.id}
          ref={videoRef}
          className="block aspect-video w-full"
          src={useCase.src}
          poster={useCase.poster}
          preload="metadata"
          playsInline
          controls={hasStarted}
          onLoadedMetadata={(e) => {
            e.currentTarget.volume = 0.5
          }}
          onPlay={() => setHasStarted(true)}
          onEnded={() => setHasStarted(false)}
        />
        {!hasStarted && (
          <button
            type="button"
            aria-label={useCase.playLabel}
            onClick={() => videoRef.current?.play()}
            className="group absolute inset-0 flex items-center justify-center"
          >
            <span className="flex h-16 w-16 items-center justify-center rounded-full bg-black/50 shadow-lg ring-1 ring-white/30 backdrop-blur-md transition-transform duration-200 group-hover:scale-105 sm:h-20 sm:w-20">
              <Play className="h-6 w-6 translate-x-0.5 fill-white text-white drop-shadow sm:h-7 sm:w-7" />
            </span>
          </button>
        )}
      </motion.div>

      {/* Quiet footnote so the tabs read as a sampler, not the full menu. */}
      <p className="mt-5 text-center text-sm text-muted-foreground/80">
        Just a few examples. Show Zerro anything and ask for what you need.
      </p>
    </motion.section>
  )
}

export default Feature
