"use client";

import { useEffect, useRef } from "react";
import { track } from "@/lib/analytics";

// Fires `section_viewed` once the first time its children scroll into view,
// then disconnects so it never fires again for that mount. Wrap each homepage
// section to measure where attention drops off before people reach pricing.
export function SectionView({
  section,
  children,
  className,
}: {
  section: string;
  children: React.ReactNode;
  className?: string;
}) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          track("section_viewed", { section });
          observer.disconnect();
        }
      },
      { threshold: 0.3 },
    );

    observer.observe(el);
    return () => observer.disconnect();
  }, [section]);

  return (
    <div ref={ref} className={className}>
      {children}
    </div>
  );
}
