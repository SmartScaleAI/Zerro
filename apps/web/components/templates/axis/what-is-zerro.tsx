import { MessageSquare, Mic, Sparkles } from "lucide-react";

// Server Component — a clean, factual, third-person definition of the product.
// This is the block AI assistants quote when asked "what is Zerro?", so it's
// deliberately plain prose (no client JS) and front-loads the facts. Framed for
// anyone who uses an AI assistant, not just developers.

// "Use it for" — everyday, cross-audience examples.
const uses = [
  "Hand a coding agent real context",
  "Draft a message about what's on screen",
  "Grab the exact formula or snippet you need",
  "Turn messy notes into a clean write-up",
  "Get a confusing screen, error, or chart explained",
  "Make changes to your website in real time using Dev Mode",
];

const WhatIsZerro = () => {
  return (
    <section id="what-is-zerro" className="relative mx-auto max-w-6xl px-4">
      <div className="grid grid-cols-1 items-start gap-10 lg:grid-cols-2 lg:gap-16">
        {/* Left — definition */}
        <div className="flex flex-col gap-5 text-center lg:text-left">
          <p className="text-sm font-medium tracking-[0.18em] text-primary uppercase">
            What is Zerro?
          </p>

          <h2 className="text-3xl leading-tight font-medium tracking-tight text-foreground sm:text-4xl lg:text-5xl">
            Show your screen. Say what you want.
          </h2>

          <div className="space-y-5 text-base leading-relaxed text-muted-foreground lg:text-lg">
            <p>
             Screenshots can show the AI your screen, but they can&apos;t point out what you&apos;re focused on or spell out what you want changed. That part is on you to type out, and it&apos;s the slow, frustrating step. Zerro lets you record what&apos;s actually happening and just say what you want, then turns it into exactly what you need.
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
                <span className="text-sm leading-snug text-white/55">
                  {label}
                </span>
              </div>
            ))}
          </div>

          {/* Use it for */}
          <div className="rounded-2xl border border-white/10 bg-[#202022] p-6">
            <p className="text-sm font-medium tracking-[0.18em] text-white/40 uppercase">
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
