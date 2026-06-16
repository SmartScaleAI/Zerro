"use client"

import Image from "next/image"
import Link from "next/link"
import { motion } from "motion/react"
import { track } from "@/lib/analytics"

const Footer = () => {
  // "/#section" (not "#section") so the links work from /privacy and /terms too.
  const links = [
    { name: "How it works", href: "/#how-it-works" },
    { name: "Output", href: "/#output" },
    { name: "Built right", href: "/#built-right" },
    { name: "Pricing", href: "/#pricing" },
    { name: "Privacy", href: "/privacy" },
    { name: "Terms", href: "/terms" },
  ]

  return (
    <motion.footer
      className="flex flex-col items-center justify-center gap-8 px-4 text-center"
      initial={{ opacity: 0, y: 20 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, amount: 0.15 }}
      transition={{ duration: 0.5, ease: [0.25, 0.46, 0.45, 0.94] }}
    >
      {/* Wordmark */}
      <Link href="/" className="flex items-center">
        <Image
          src="/logo/zerro-mark.svg"
          alt="Zerro"
          width={44}
          height={44}
          className="h-11 w-11 text-foreground dark:invert"
        />
        <span className="text-2xl font-medium tracking-tight text-foreground">
          Zerro
        </span>
      </Link>

      {/* Tagline */}
      <p className="max-w-md text-sm text-muted-foreground">
        Record it. Paste it. Zerro in between.
      </p>

      {/* Nav links */}
      <ul className="flex flex-wrap items-center justify-center gap-x-6 gap-y-2">
        {links.map((link) => (
          <li key={link.name}>
            <Link
              href={link.href}
              onClick={() => {
                // Anchor links (/#section) are on-page nav; the route links
                // (/privacy, /terms) are the outbound destinations worth tracking.
                if (!link.href.includes("#")) {
                  track("outbound_clicked", {
                    destination: link.href.replace(/^\//, ""),
                  })
                }
              }}
              className="text-sm text-muted-foreground transition-colors hover:text-foreground"
            >
              {link.name}
            </Link>
          </li>
        ))}
      </ul>

      {/* Support + copyright */}
      <div className="flex w-full max-w-md flex-col items-center gap-2 border-t border-border pt-4">
        <a
          href="mailto:support@getzerro.app"
          onClick={() =>
            track("outbound_clicked", { destination: "support_email" })
          }
          className="text-sm text-muted-foreground transition-colors hover:text-foreground"
        >
          support@getzerro.app
        </a>
        <p className="text-sm text-muted-foreground">
          &copy; {new Date().getFullYear()} Zerro. All rights reserved.
        </p>
      </div>
    </motion.footer>
  )
}

export default Footer
