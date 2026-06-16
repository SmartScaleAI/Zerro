"use client";

import type { ComponentProps } from "react";
import { Button } from "@/components/ui/button";
import { DOWNLOAD_URL } from "@/lib/site-config";
import { track } from "@/lib/analytics";

type DownloadButtonProps = Omit<
  ComponentProps<typeof Button>,
  "render" | "nativeButton"
> & {
  /** Where on the page this CTA lives — sent as the `placement` prop. */
  placement: string;
};

// The one "Download for macOS" CTA. Renders the same Button-as-anchor every
// download link used before (same `download` attr, same styling passed via
// className/children) and fires `download_clicked` with its placement. Drop-in
// replacement for the raw `<Button render={<a href={DOWNLOAD_URL} download />}>`.
export function DownloadButton({
  placement,
  children,
  onClick,
  ...props
}: DownloadButtonProps) {
  return (
    <Button
      {...props}
      nativeButton={false}
      render={<a href={DOWNLOAD_URL} download />}
      onClick={(event) => {
        track("download_clicked", { placement });
        onClick?.(event);
      }}
    >
      {children}
    </Button>
  );
}
