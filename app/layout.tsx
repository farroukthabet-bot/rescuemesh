import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "RescueMesh",
  description: "Rescue the surplus. Prove the rescue.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" style={{ colorScheme: "dark" }}>
      <body className="bg-[#0D0C16]">{children}</body>
    </html>
  );
}