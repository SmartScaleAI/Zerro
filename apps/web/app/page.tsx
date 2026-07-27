import type { Metadata } from "next";
import Navbar from "@/components/templates/axis/navbar";
import Hero from "@/components/templates/axis/hero";
import Feature from "@/components/templates/axis/feature";
import ToolFeature from "@/components/templates/axis/tools";
import DevMode from "@/components/templates/axis/dev-mode";
import BuiltRight from "@/components/templates/axis/built-right";
import NowTalking from "@/components/templates/axis/now-talking";
import Pricing from "@/components/templates/axis/pricing";
import FinalCTA from "@/components/templates/axis/final-cta";
import Footer from "@/components/templates/axis/footer";
import Comparison from "@/components/templates/axis/comparison";
import Faq from "@/components/templates/axis/faq";
import { SectionView } from "@/components/section-view";
import { GradientField } from "@/components/ui/gradient-field";
import {
  SoftwareApplicationJsonLd,
  FaqJsonLd,
} from "@/components/structured-data";
import { faqEntries } from "@/components/templates/axis/faq-data";

export const metadata: Metadata = {
  // Absolute so the homepage title is fully controlled and mirrors the hero
  // headline, rather than relying on the root template suffix.
  title: {
    absolute: "Zerro: Talk to your screen. Zerro does the work.",
  },
  description:
    "A lightweight macOS menu bar app. Record your screen, explain what you want, and get it done faster: an agent prompt, a message, a snippet, a document, or a clear answer to your question. Local-first, bring your own keys.",
  alternates: { canonical: "/" },
  openGraph: {
    title: "Zerro: Talk to your screen. Zerro does the work.",
    description:
      "A lightweight macOS menu bar app. Record your screen, explain what you want, and get it done faster: an agent prompt, a message, a snippet, a document, or a clear answer to your question. Local-first, bring your own keys.",
    url: "https://getzerro.app",
    siteName: "Zerro",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "Zerro: Talk to your screen. Zerro does the work.",
    description:
      "A lightweight macOS menu bar app. Record your screen, explain what you want, and get it done faster: a prompt, a message, a snippet, a document, or a clear answer. Local-first, BYOK.",
  },
};

const Page = () => {
  return (
    <div className="relative mx-auto w-full overflow-hidden">
      <SoftwareApplicationJsonLd />
      <FaqJsonLd entries={faqEntries} />
      <Navbar />

      {/* Ambient hero gradient field — multi-color corners, constrained to the hero area */}
      <GradientField
        edgeFade="bottom"
        className="-top-24 left-1/2 -translate-x-1/2 z-0 mx-auto w-full max-w-6xl px-4 h-[66rem] lg:h-[78rem] blur-[80px]"
        style={{
          maskImage:
            "radial-gradient(ellipse 75% 60% at 50% 32%, black 30%, transparent 78%)",
          WebkitMaskImage:
            "radial-gradient(ellipse 75% 60% at 50% 32%, black 30%, transparent 78%)",
        }}
      />

      {/* Subtle grain/noise texture overlay */}
      <div
        aria-hidden="true"
        className="pointer-events-none fixed inset-0 opacity-[0.015] mix-blend-overlay"
        style={{
          backgroundImage: `url("data:image/svg+xml,%3Csvg viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='3' /%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' /%3E%3C/svg%3E")`,
        }}
      />

      <main className="relative flex flex-col gap-24 lg:gap-40 mt-36 mb-14 lg:mt-40 lg:mb-32 mx-auto w-full">
        <SectionView section="hero">
          <Hero />
        </SectionView>
        {/* Pulled up against the hero so "How it works" sits right under the
            CTAs, where the recording pill used to be, instead of a full
            section gap away. */}
        <SectionView section="how_it_works" className="-mt-4 lg:-mt-12">
          <Feature />
        </SectionView>
        <SectionView section="comparison">
          <Comparison />
        </SectionView>
        <SectionView section="output">
          <ToolFeature />
        </SectionView>
        <SectionView section="dev_mode">
          <DevMode />
        </SectionView>
        <SectionView section="built_right">
          <BuiltRight />
        </SectionView>
        <SectionView section="the_shift">
          <NowTalking />
        </SectionView>
        <SectionView section="pricing">
          <Pricing />
        </SectionView>
        <SectionView section="faq">
          <Faq />
        </SectionView>
        <SectionView section="final_cta">
          <FinalCTA />
        </SectionView>
        <Footer />
      </main>
    </div>
  );
};

export default Page;
