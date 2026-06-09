"use client";

import { AnimatePresence, motion } from "motion/react";
import { Plus } from "lucide-react";
import { useState } from "react";
import { faqEntries } from "./faq-data";

// FAQ accordion. Each answer is always rendered in the DOM (just height-collapsed
// when closed) so crawlers and AI tools can read every answer regardless of open
// state. The matching FAQPage JSON-LD is emitted server-side from the homepage
// using the same faqEntries source, so the two never drift.
const FaqItem = ({
  question,
  answer,
  isOpen,
  onToggle,
}: {
  question: string;
  answer: string;
  isOpen: boolean;
  onToggle: () => void;
}) => {
  return (
    <div className="px-6">
      <h3>
        <button
          type="button"
          onClick={onToggle}
          aria-expanded={isOpen}
          className="flex w-full cursor-pointer items-center justify-between gap-4 py-5 text-left text-base font-medium text-foreground"
        >
          {question}
          <Plus
            className={`h-4 w-4 flex-shrink-0 text-muted-foreground transition-transform duration-300 ${
              isOpen ? "rotate-45" : ""
            }`}
            strokeWidth={2}
            aria-hidden="true"
          />
        </button>
      </h3>
      <AnimatePresence initial={false}>
        {isOpen && (
          <motion.div
            key="content"
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: "auto", opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            transition={{ duration: 0.3, ease: [0.25, 0.46, 0.45, 0.94] }}
            className="overflow-hidden"
          >
            <p className="pb-5 text-sm leading-relaxed text-muted-foreground">
              {answer}
            </p>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
};

const Faq = () => {
  const [openIndex, setOpenIndex] = useState<number | null>(null);

  return (
    <motion.section
      id="faq"
      className="relative mx-auto w-full max-w-3xl px-4"
      initial={{ opacity: 0, y: 20 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, amount: 0.15 }}
      transition={{ duration: 0.5, ease: [0.25, 0.46, 0.45, 0.94] }}
    >
      <div className="mb-12 flex flex-col items-center gap-3 text-center lg:mb-16">
        <p className="text-sm font-medium tracking-[0.18em] text-primary uppercase">
          FAQ
        </p>
        <h2 className="text-3xl leading-tight font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl">
          Questions, answered.
        </h2>
      </div>

      <div className="flex flex-col divide-y divide-border rounded-2xl border border-border">
        {faqEntries.map((entry, i) => (
          <FaqItem
            key={entry.question}
            question={entry.question}
            answer={entry.answer}
            isOpen={openIndex === i}
            onToggle={() => setOpenIndex(openIndex === i ? null : i)}
          />
        ))}
      </div>
    </motion.section>
  );
};

export default Faq;
