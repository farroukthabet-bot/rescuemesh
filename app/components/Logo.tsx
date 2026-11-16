// RescueMesh mark: three actors (donor, NGO, volunteer) linked in a small mesh around the shared record.
export default function Logo({ size = 40, className = "" }: { size?: number; className?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 40 40" role="img" aria-label="RescueMesh" className={className}>
      <defs>
        <linearGradient id="rm-logo-g" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#B5A8FF" />
          <stop offset="1" stopColor="#6A58E8" />
        </linearGradient>
      </defs>
      <rect width="40" height="40" rx="11" fill="url(#rm-logo-g)" />
      <g stroke="#0D0C16" strokeLinecap="round" strokeLinejoin="round" fill="none">
        <path d="M20 9 10.5 27.5h19z" strokeWidth="2.2" />
        <path d="M20 21V9M20 21l-9.5 6.5M20 21l9.5 6.5" strokeWidth="1.4" strokeOpacity="0.7" />
      </g>
      <circle cx="20" cy="9" r="4.2" fill="#FF7A66" stroke="#0D0C16" strokeWidth="2" />
      <circle cx="10.5" cy="27.5" r="4.2" fill="#34D3A0" stroke="#0D0C16" strokeWidth="2" />
      <circle cx="29.5" cy="27.5" r="4.2" fill="#ECEAF8" stroke="#0D0C16" strokeWidth="2" />
      <circle cx="20" cy="21" r="2.3" fill="#0D0C16" />
    </svg>
  );
}