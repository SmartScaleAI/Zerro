"use client"

import { Button } from "@/components/ui/button"
import { DownloadButton } from "@/components/download-button"
import { AnimatedBorder } from "@/components/ui/animated-border"
import { Menu, X } from "lucide-react"
import { AppleIcon } from "@/components/ui/apple-icon"
import { track } from "@/lib/analytics"
import {
  AnimatePresence,
  motion,
  useMotionValueEvent,
  useScroll,
} from "motion/react"
import Image from "next/image"
import Link from "next/link"
import { useEffect, useState } from "react"

// "#how-it-works" → "how_it_works", matching the section_viewed naming.
const navTarget = (href: string) => href.replace(/^#/, "").replace(/-/g, "_")

// Distance from the viewport top, in px, at which a section's header should
// land — the sticky bar is ~80px tall, so this leaves a small gap below it
// instead of the header hugging the bar's bottom edge. Kept in sync with the
// `scroll-mt-24` (96px) on the section elements so JS-driven and native hash
// navigation settle at the same place.
const NAV_OFFSET = 96

// Smooth-scroll to the section without letting the anchor write `#id` to the
// URL: we preventDefault and drive the scroll ourselves, applying NAV_OFFSET.
const scrollToSection = (href: string) => {
  const el = document.getElementById(href.replace(/^#/, ""))
  if (!el) return
  const top = el.getBoundingClientRect().top + window.scrollY - NAV_OFFSET
  window.scrollTo({ top, behavior: "smooth" })
}

const Navbar = () => {
  const [isOpen, setIsOpen] = useState(false)
  const [isScrolled, setIsScrolled] = useState(false)
  const { scrollY } = useScroll()

  const links = [
    { name: "How it works", href: "#how-it-works" },
    { name: "Output", href: "#output" },
    { name: "Dev Mode", href: "#dev-mode" },
    { name: "Built right", href: "#built-right" },
    { name: "Pricing", href: "#pricing" },
  ]

  useMotionValueEvent(scrollY, "change", (latest) => {
    setIsScrolled(latest > 50)
  })

  useEffect(() => {
    if (isOpen) {
      document.body.style.overflow = "hidden"
    } else {
      document.body.style.overflow = "unset"
    }
    return () => {
      document.body.style.overflow = "unset"
    }
  }, [isOpen])

  return (
    <motion.div
      className="fixed top-0 right-0 left-0 z-50 mx-auto w-full max-w-6xl px-4 pt-4 max-md:my-2"
      initial={{ opacity: 0, y: -20 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.3, ease: [0.25, 0.46, 0.45, 0.94] }}
    >
      <motion.div
        className="relative mx-auto max-w-7xl"
        animate={{
          scale: isScrolled ? 0.98 : 1,
        }}
        transition={{ duration: 0.2 }}
      >
        <motion.div
          className="flex flex-row items-center justify-between gap-4 rounded-full border border-border p-2 dark:border-white/10"
          animate={{
            backgroundColor: isScrolled
              ? "hsl(var(--background) / 0.8)"
              : "hsl(var(--background))",
            backdropFilter: "blur(12px)",
            boxShadow: isScrolled
              ? "0 4px 20px -5px rgba(0, 0, 0, 0.3), 0 0 24px 0 var(--nav-glow)"
              : "0 0 20px 0 var(--nav-glow)",
          }}
          transition={{ duration: 0.3 }}
        >
          {/* Zerro wordmark */}
          <Link href="/" className="group ml-3 flex items-center">
            <Image
              src="/logo/zerro-mark.svg"
              alt="Zerro"
              width={36}
              height={36}
              className="-ml-1 h-9 w-9 text-foreground dark:invert"
              priority
            />
            <span className="text-xl font-medium tracking-tight text-foreground">
              Zerro
            </span>
          </Link>

          <section className="hidden flex-row items-center gap-7 lg:flex">
            <div className="flex flex-row gap-8">
              {links.map((link) => (
                <Link
                  href={link.href}
                  key={link.name}
                  onClick={(e) => {
                    e.preventDefault()
                    track("nav_link_clicked", { target: navTarget(link.href) })
                    scrollToSection(link.href)
                  }}
                  className="flex flex-row items-center gap-1 text-sm font-medium text-muted-foreground transition-colors hover:text-foreground"
                >
                  {link.name}
                </Link>
              ))}
            </div>
            <DownloadButton
              placement="navbar"
              className="relative gap-2 rounded-full hover:border-border hover:bg-muted hover:text-foreground hover:backdrop-blur-md dark:hover:border-input dark:hover:bg-input/30 dark:hover:text-foreground"
              size="lg"
            >
              <AnimatedBorder />
              <AppleIcon className="h-4 w-4" />
              Download
            </DownloadButton>
          </section>

          <section className="flex flex-row items-center gap-2 lg:hidden">
            <DownloadButton
              placement="navbar_mobile"
              className="relative gap-2 rounded-full hover:border-border hover:bg-muted hover:text-foreground hover:backdrop-blur-md dark:hover:border-input dark:hover:bg-input/30 dark:hover:text-foreground"
              size="default"
            >
              <AnimatedBorder />
              <AppleIcon className="h-4 w-4" />
              Download
            </DownloadButton>
            <Button
              variant="ghost"
              size="icon"
              className="rounded-full"
              onClick={() => setIsOpen(!isOpen)}
              aria-label={isOpen ? "Close menu" : "Open menu"}
              aria-expanded={isOpen}
            >
              <AnimatePresence mode="wait" initial={false}>
                {isOpen ? (
                  <motion.div
                    key="close"
                    initial={{ opacity: 0, rotate: -90 }}
                    animate={{ opacity: 1, rotate: 0 }}
                    exit={{ opacity: 0, rotate: 90 }}
                    transition={{ duration: 0.2 }}
                  >
                    <X className="h-5 w-5" />
                  </motion.div>
                ) : (
                  <motion.div
                    key="menu"
                    initial={{ opacity: 0, rotate: 90 }}
                    animate={{ opacity: 1, rotate: 0 }}
                    exit={{ opacity: 0, rotate: -90 }}
                    transition={{ duration: 0.2 }}
                  >
                    <Menu className="h-5 w-5" />
                  </motion.div>
                )}
              </AnimatePresence>
            </Button>
          </section>
        </motion.div>

        <AnimatePresence>
          {isOpen && (
            <motion.div
              initial={{ opacity: 0, y: -10, height: 0 }}
              animate={{ opacity: 1, y: 0, height: "auto" }}
              exit={{ opacity: 0, y: -10, height: 0 }}
              transition={{ duration: 0.3, ease: "easeInOut" }}
              className="absolute top-full right-0 left-0 z-50 mt-2 overflow-hidden lg:hidden"
            >
              <div className="flex flex-col gap-2 rounded-2xl border border-border bg-background/95 p-4 backdrop-blur-xl">
                {links.map((link, index) => (
                  <motion.div
                    key={link.name}
                    initial={{ opacity: 0, x: -20 }}
                    animate={{ opacity: 1, x: 0 }}
                    transition={{ duration: 0.2, delay: index * 0.05 }}
                  >
                    <Link
                      href={link.href}
                      className="flex flex-row items-center justify-between rounded-lg px-4 py-3 font-medium text-foreground transition-colors hover:bg-muted"
                      onClick={(e) => {
                        e.preventDefault()
                        track("nav_link_clicked", { target: navTarget(link.href) })
                        scrollToSection(link.href)
                        setIsOpen(false)
                      }}
                    >
                      {link.name}
                    </Link>
                  </motion.div>
                ))}
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </motion.div>
    </motion.div>
  )
}

export default Navbar
