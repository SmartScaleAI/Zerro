"use client";

import { motion } from "motion/react";

import { cn } from "@/lib/utils";

interface AnimatedBorderProps {
  /** Classes applied to the traveling gradient segment (e.g. color overrides). */
  className?: string;
  /** Seconds per lap around the perimeter. */
  duration?: number;
  /** Corner radius of the offset-path rect. Defaults to a large value for pill buttons. */
  radius?: number;
  /** Length of the gradient segment in px. */
  width?: number;
}

/**
 * Decorative overlay that animates a light segment continuously around the
 * perimeter of its nearest positioned ancestor. Drop it as the first child of
 * a `relative` element (e.g. a Button). Inherits the parent's border-radius.
 *
 * The segment glides continuously but is hidden until the parent button is
 * hovered, then fades in (relies on the Button's `group/button` class).
 */
export function AnimatedBorder({
  className,
  duration = 5,
  radius = 9999,
  width = 40,
}: AnimatedBorderProps) {
  return (
    <div
      aria-hidden="true"
      className={cn(
        "pointer-events-none absolute -inset-px rounded-[inherit] border-2 border-transparent",
        "opacity-0 transition-opacity duration-300 group-hover/button:opacity-100",
        "[mask-clip:padding-box,border-box] [mask-composite:intersect]",
        "[mask-image:linear-gradient(transparent,transparent),linear-gradient(#000,#000)]"
      )}
    >
      <motion.div
        className={cn(
          "absolute aspect-square bg-gradient-to-r from-transparent via-foreground to-foreground",
          className
        )}
        animate={{ offsetDistance: ["0%", "100%"] }}
        style={{
          width,
          offsetPath: `rect(0 auto auto 0 round ${radius}px)`,
        }}
        transition={{
          repeat: Number.POSITIVE_INFINITY,
          duration,
          ease: "linear",
        }}
      />
    </div>
  );
}
