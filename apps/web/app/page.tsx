"use client";

import Navbar from "@/components/templates/axis/navbar";
import Hero from "@/components/templates/axis/hero";
import Feature from "@/components/templates/axis/feature";
import ToolFeature from "@/components/templates/axis/tools";
import BuiltRight from "@/components/templates/axis/built-right";
import NowTalking from "@/components/templates/axis/now-talking";
import Pricing from "@/components/templates/axis/pricing";
import FinalCTA from "@/components/templates/axis/final-cta";
import Footer from "@/components/templates/axis/footer";
import { GradientField } from "@/components/ui/gradient-field";

const Page = () => {
  return (
    <div className="relative mx-auto w-full overflow-hidden">
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
        <Feature />
        <ToolFeature />
        <BuiltRight />
        <NowTalking />
        <Pricing />
        <FinalCTA />
        <Footer />
      </main>
    </div>
  );
};

export default Page;
