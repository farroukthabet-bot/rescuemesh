"use client";

import { useState } from "react";
import QrScanner from "./QrScanner";

export default function CodeStep({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const [scanning, setScanning] = useState(false);
  return (
    <div className="mt-3">
      <label className="block text-sm">
        Donation code from the QR label
        <input
          className="mt-1 block w-full max-w-48 rounded-md border border-[#ECEAF8]/25 bg-[#1B1A33] text-[#ECEAF8] placeholder:text-[#ECEAF8]/40 px-3 py-2 text-sm focus-visible:outline-2 focus-visible:outline-[#C9BEFF]"
          value={value}
          placeholder="e.g. RM-003"
          onChange={(e) => onChange(e.target.value)}
        />
      </label>
      <button type="button" className="mt-2 text-sm text-[#C9BEFF] underline underline-offset-2" onClick={() => setScanning((s) => !s)}>
        {scanning ? "Close camera" : "Scan with camera"}
      </button>
      {scanning && <QrScanner onResult={(t) => { onChange(t.trim()); setScanning(false); }} />}
    </div>
  );
}