import { ImageResponse } from "next/og";

// Static social share card, 1200×630. Rendered once at build via ImageResponse.
// Uses the default sans font (no font fetch) to keep the route lightweight.
export const alt = "Zerro: Stop typing out what's already on your screen";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default function OpengraphImage() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          backgroundColor: "#0a0a0a",
          padding: "80px",
          fontFamily: "sans-serif",
        }}
      >
        {/* Wordmark: the Zerro mark + name */}
        <div style={{ display: "flex", alignItems: "center", gap: "20px" }}>
          <svg
            width="72"
            height="72"
            viewBox="0 0 512 512"
            xmlns="http://www.w3.org/2000/svg"
          >
            <g fill="#fafafa">
              <path d="M150 362 V180 Q150 150 180 150 H288 Q300 150 300 162 V208 H208 V362 Z" />
              <path
                d="M150 362 V180 Q150 150 180 150 H288 Q300 150 300 162 V208 H208 V362 Z"
                transform="rotate(180 256 256)"
              />
            </g>
          </svg>
          <span
            style={{ color: "#fafafa", fontSize: 48, fontWeight: 600, letterSpacing: "-0.02em" }}
          >
            Zerro
          </span>
        </div>

        {/* Tagline */}
        <div style={{ display: "flex", flexDirection: "column", gap: "24px" }}>
          <div
            style={{
              display: "flex",
              flexDirection: "column",
              color: "#fafafa",
              fontSize: 84,
              fontWeight: 600,
              lineHeight: 1.05,
              letterSpacing: "-0.03em",
            }}
          >
            <span>Stop typing out what&apos;s</span>
            <span>already on your screen.</span>
          </div>
          <div style={{ color: "#a1a1a1", fontSize: 32, fontWeight: 400 }}>
            Record your screen, explain what you want, get the answer in
            seconds.
          </div>
        </div>
      </div>
    ),
    { ...size },
  );
}
