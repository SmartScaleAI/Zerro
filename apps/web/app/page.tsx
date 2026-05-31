import type { Metadata } from "next";
import Navbar from "@/components/templates/axis/navbar";
import Hero from "@/components/templates/axis/hero";
import Feature from "@/components/templates/axis/feature";
import ToolFeature from "@/components/templates/axis/tools";
import BuiltRight from "@/components/templates/axis/built-right";
import NowTalking from "@/components/templates/axis/now-talking";
import Pricing from "@/components/templates/axis/pricing";
import FinalCTA from "@/components/templates/axis/final-cta";
import Footer from "@/components/templates/axis/footer";
import WhatIsZerro from "@/components/templates/axis/what-is-zerro";
import Comparison from "@/components/templates/axis/comparison";
import Faq from "@/components/templates/axis/faq";
import { GradientField } from "@/components/ui/gradient-field";
import {
  SoftwareApplicationJsonLd,
  FaqJsonLd,
} from "@/components/structured-data";
import { faqEntries } from "@/components/templates/axis/faq-data";

export const metadata: Metadata = {
  // Absolute so the homepage title is fully controlled and lead-with-product,
  // rather than relying on the root template suffix.
  title: {
    absolute: "Zerro — Turn your screen and voice into a prompt or an explanation",
  },
  description:
    "Zerro is a native macOS menu-bar app. Record a region of your screen, dictate what you want, and get either a structured prompt for your AI agent or a clear plain-language explanation of what's on screen. Local-first, bring your own keys.",
  alternates: { canonical: "/" },
  openGraph: {
    title: "Zerro — Turn your screen and voice into a prompt or an explanation",
    description:
      "Record a region of your screen, dictate what you want, and get either a structured prompt for your AI agent or a clear plain-language explanation of what's on screen. Native macOS, local-first, bring your own keys.",
    url: "https://getzerro.app",
    siteName: "Zerro",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "Zerro — Turn your screen and voice into a prompt or an explanation",
    description:
      "Record your screen, dictate what you want, and get either a structured prompt for your AI agent or a plain-language explanation of what's on screen. Native macOS, local-first, BYOK.",
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

      <main className="relative flex flex-col gap-24 lg:gap-40 mt-44 mb-14 lg:mt-52 lg:mb-32 mx-auto w-full">
        <Hero />
        <WhatIsZerro />
        <Feature />
        <ToolFeature />
        <BuiltRight />
        <Comparison />
        <NowTalking />
        <Pricing />
        <Faq />
        <FinalCTA />
        <Footer />
      </main>
    </div>
  );
};

export default Page;
