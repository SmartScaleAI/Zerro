import { MessageSquare, Mic, Sparkles } from "lucide-react";

// Server Component — a clean, factual, third-person definition of the product.
// This is the block AI assistants quote when asked "what is Zerro?", so it's
// deliberately plain prose (no client JS) and front-loads the facts. Framed for
// anyone who uses an AI assistant, not just developers.

// "Works with" — a spread of AI tools across audiences, not just coding agents.
const tools = ["ChatGPT", "Claude", "Gemini", "Cursor", "Perplexity", "v0"];

// "Use it for" — everyday, cross-audience examples.
const uses = [
  "Explain a bug to an AI assistant",
  "Get help with a spreadsheet or design",
  "Turn what's on screen into a clear request",
  "Hand a coding agent real context",
];

const WhatIsZerro = () => {
  return (
    <section id="what-is-zerro" className="relative mx-auto max-w-6xl px-4">
      <div className="grid grid-cols-1 items-start gap-10 lg:grid-cols-2 lg:gap-16">
        {/* Left — definition */}
        <div className="flex flex-col gap-5 text-center lg:text-left">
          <p className="text-xs font-medium tracking-[0.18em] text-primary uppercase">
            What is Zerro?
          </p>

          <h2 className="text-3xl leading-tight font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl">
            Show your screen. Say what you want.
          </h2>

          <div className="space-y-5 text-base leading-relaxed text-muted-foreground lg:text-lg">
            <p>
              Zerro is a native macOS menu-bar app that turns a screen recording
              and a few spoken words into a clear, structured prompt for whatever
              AI tool you&apos;re using — ChatGPT, Claude, a coding agent, or
              anything else that takes text.
            </p>
            <p>
              Everything runs locally first, and you bring your own keys — no
              servers in the middle, no account required. Talking is faster than
              typing, and Zerro turns what you say into something an AI can
              actually act on.
            </p>
          </div>
        </div>

        {/* Right — works with / use it for */}
        <div className="flex flex-col gap-5">
          {/* Three-step micro-flow */}
          <div className="grid grid-cols-3 gap-3">
            {[
              { icon: Mic, label: "Record + speak" },
              { icon: Sparkles, label: "Zerro structures it" },
              { icon: MessageSquare, label: "Paste anywhere" },
            ].map(({ icon: Icon, label }) => (
              <div
                key={label}
                className="flex flex-col items-center gap-2.5 rounded-xl border border-white/10 bg-[#202022] p-4 text-center"
              >
                <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-primary/15 text-primary">
                  <Icon className="h-4 w-4" strokeWidth={1.8} />
                </div>
                <span className="text-xs leading-snug text-white/55">
                  {label}
                </span>
              </div>
            ))}
          </div>

          {/* Works with */}
          <div className="rounded-2xl border border-white/10 bg-[#202022] p-6">
            <p className="text-xs font-medium tracking-[0.18em] text-white/40 uppercase">
              Works with
            </p>
            <div className="mt-3 flex flex-wrap gap-2">
              {tools.map((t) => (
                <span
                  key={t}
                  className="rounded-full border border-white/[0.08] bg-black/25 px-3 py-1 text-sm text-white/85"
                >
                  {t}
                </span>
              ))}
              <span className="rounded-full border border-white/[0.08] bg-black/25 px-3 py-1 text-sm text-white/45">
                & any text-based AI
              </span>
            </div>
          </div>

          {/* Use it for */}
          <div className="rounded-2xl border border-white/10 bg-[#202022] p-6">
            <p className="text-xs font-medium tracking-[0.18em] text-white/40 uppercase">
              Use it for
            </p>
            <ul className="mt-3 grid grid-cols-1 gap-2 sm:grid-cols-2">
              {uses.map((u) => (
                <li
                  key={u}
                  className="flex items-start gap-2 text-sm leading-relaxed text-white/65"
                >
                  <span className="mt-1.5 h-1 w-1 flex-shrink-0 rounded-full bg-primary" />
                  {u}
                </li>
              ))}
            </ul>
          </div>
        </div>
      </div>
    </section>
  );
};

export default WhatIsZerro;
