"use client";

import { useEffect, useState } from "react";
import { motion } from "motion/react";
import { cn } from "@/lib/utils";

const TYPE_MS = 80;
const DELETE_MS = 45;
const HOLD_MS = 2000;
const NEXT_WORD_DELAY_MS = 350;

type Phase = "typing" | "deleting";

/**
 * Cycles through `words` with a typewriter effect: type, hold, backspace,
 * then type the next word. Starts with the first word fully typed so the
 * server-rendered headline is complete and doesn't pop on hydration.
 */
export const TypewriterWords = ({
  words,
  colors,
  className,
  cursorClassName,
}: {
  words: string[];
  /** Optional solid text colors, cycled per word by index. */
  colors?: string[];
  className?: string;
  cursorClassName?: string;
}) => {
  const [wordIndex, setWordIndex] = useState(0);
  const [length, setLength] = useState(words[0]?.length ?? 0);
  const [phase, setPhase] = useState<Phase>("typing");

  const word = words[wordIndex % words.length] ?? "";

  useEffect(() => {
    let delay: number;
    let next: () => void;

    if (phase === "typing") {
      if (length < word.length) {
        delay = TYPE_MS;
        next = () => setLength(length + 1);
      } else {
        delay = HOLD_MS;
        next = () => setPhase("deleting");
      }
    } else if (length > 0) {
      delay = DELETE_MS;
      next = () => setLength(length - 1);
    } else {
      delay = NEXT_WORD_DELAY_MS;
      next = () => {
        setWordIndex((i) => (i + 1) % words.length);
        setPhase("typing");
      };
    }

    const timeout = setTimeout(next, delay);
    return () => clearTimeout(timeout);
  }, [phase, length, word, words.length]);

  const color = colors?.length
    ? colors[wordIndex % colors.length]
    : undefined;

  return (
    <span className={cn("inline-block whitespace-nowrap", className)}>
      <span style={color ? { color } : undefined}>
        {word.slice(0, length)}
      </span>
      {/* Aceternity-style caret: slim bar with subtle rounding, vertically
          centered on the line so it tops out near the lowercase letters and
          dips just below the baseline, with their soft reverse-fade blink. */}
      <motion.span
        aria-hidden="true"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{
          duration: 0.8,
          repeat: Number.POSITIVE_INFINITY,
          repeatType: "reverse",
        }}
        className={cn(
          "inline-block h-[1em] w-[4px] align-bottom rounded-sm bg-foreground",
          cursorClassName,
        )}
      />
    </span>
  );
};
