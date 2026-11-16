"use client";

import { useEffect, useRef, useState } from "react";
import jsQR from "jsqr";

// Camera QR scanner (works on http://localhost). Falls back to a message if the camera is unavailable.
export default function QrScanner({ onResult }: { onResult: (text: string) => void }) {
  const video = useRef<HTMLVideoElement>(null);
  const cb = useRef(onResult);
  cb.current = onResult;
  const [error, setError] = useState("");

  useEffect(() => {
    let stopped = false;
    let raf = 0;
    let stream: MediaStream | undefined;
    const canvas = document.createElement("canvas");

    (async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } });
        const v = video.current;
        if (!v) return;
        v.srcObject = stream;
        await v.play();
        const tick = () => {
          if (stopped) return;
          if (v.videoWidth) {
            canvas.width = v.videoWidth;
            canvas.height = v.videoHeight;
            const ctx = canvas.getContext("2d", { willReadFrequently: true })!;
            ctx.drawImage(v, 0, 0);
            const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
            const code = jsQR(img.data, img.width, img.height);
            if (code?.data) { cb.current(code.data); return; }
          }
          raf = requestAnimationFrame(tick);
        };
        tick();
      } catch {
        setError("Camera not available. Type the code instead.");
      }
    })();

    return () => {
      stopped = true;
      cancelAnimationFrame(raf);
      stream?.getTracks().forEach((t) => t.stop());
    };
  }, []);

  return (
    <div className="mt-2">
      {error ? <p className="text-sm text-[#FB7185]">{error}</p> : <video ref={video} playsInline muted className="w-full max-w-xs border border-[#ECEAF8]/20" />}
    </div>
  );
}