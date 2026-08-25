import React from "react";

// One 24px stroke set shared by the dashboard window and the tray popover.
export function Icon({ children, className, title, spinning }) {
  return (
    <svg
      aria-hidden={title ? undefined : "true"}
      role={title ? "img" : undefined}
      className={`${className || ""} ${spinning ? "spinning" : ""}`.trim() || undefined}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      {title && <title>{title}</title>}
      {children}
    </svg>
  );
}
export function GridIcon() { return <Icon><rect x="4" y="4" width="6" height="6" rx="1"/><rect x="14" y="4" width="6" height="6" rx="1"/><rect x="4" y="14" width="6" height="6" rx="1"/><rect x="14" y="14" width="6" height="6" rx="1"/></Icon>; }
export function GaugeIcon({ className }) { return <Icon className={className}><path d="M5 17a8 8 0 1 1 14 0"/><path d="m12 13 4-4"/><path d="M8 19h8"/></Icon>; }
export function TrendsIcon() { return <Icon><path d="M4 18V6"/><path d="M4 18h16"/><path d="m7 14 4-4 3 2 5-6"/></Icon>; }
export function DevicesIcon() { return <Icon><rect x="3" y="5" width="13" height="10" rx="1.5"/><path d="M7 19h5M9.5 15v4"/><rect x="17" y="9" width="4" height="8" rx="1"/></Icon>; }
export function DataSourcesIcon() { return <Icon><ellipse cx="12" cy="5" rx="7" ry="3"/><path d="M5 5v6c0 1.7 3.1 3 7 3s7-1.3 7-3V5"/><path d="M5 11v6c0 1.7 3.1 3 7 3s7-1.3 7-3v-6"/></Icon>; }
export function SettingsIcon() { return <Icon><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2.8 2.8-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6v.2h-4V21a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1L4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9A1.7 1.7 0 0 0 3 14H2.8v-4H3a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9L4.2 7 7 4.2l.1.1a1.7 1.7 0 0 0 1.9.3A1.7 1.7 0 0 0 10 3V2.8h4V3a1.7 1.7 0 0 0 1 1.6 1.7 1.7 0 0 0 1.9-.3l.1-.1L19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.6 1h.2v4H21a1.7 1.7 0 0 0-1.6 1Z"/></Icon>; }
export function RefreshIcon({ spinning }) { return <Icon spinning={spinning}><path d="M20 7v5h-5"/><path d="M4 17v-5h5"/><path d="M6.1 8a7 7 0 0 1 11.5-2.6L20 7M4 17l2.4 1.6A7 7 0 0 0 17.9 16"/></Icon>; }
export function LockIcon() { return <Icon><rect x="5" y="10" width="14" height="10" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></Icon>; }
export function ChevronRightIcon({ className }) { return <Icon className={className}><path d="m9 6 6 6-6 6"/></Icon>; }
export function PlusIcon() { return <Icon><path d="M12 5v14"/><path d="M5 12h14"/></Icon>; }
export function MinusIcon() { return <Icon><path d="M5 12h14"/></Icon>; }
export function FlameIcon() { return <Icon><path d="M12 21c3.9 0 6.5-2.4 6.5-6 0-3.2-2.2-5.4-3.7-7.5-.6.9-1 1.6-1.3 2.8C12.4 8 11.4 5.5 9.2 3c-.4 3-1.2 4.4-2.4 6.2-1 1.6-1.3 3-1.3 4.8 0 4.6 3 7 6.5 7Z"/></Icon>; }
export function BoltIcon() { return <Icon><path d="M13 3 5 13h5l-1 8 8-11h-5l1-7Z"/></Icon>; }
export function ReplyIcon() { return <Icon><path d="M20 12a8 8 0 0 1-8 8H4l2.5-2.6A8 8 0 1 1 20 12Z"/></Icon>; }
export function RepostIcon() { return <Icon><path d="M17 3 21 7l-4 4"/><path d="M21 7H8a4 4 0 0 0-4 4"/><path d="m7 21-4-4 4-4"/><path d="M3 17h13a4 4 0 0 0 4-4"/></Icon>; }
export function HeartIcon() { return <Icon><path d="M12 20.5S4 15.5 4 9.9A4.4 4.4 0 0 1 8.4 5.5c1.6 0 2.9.9 3.6 2.1.7-1.2 2-2.1 3.6-2.1a4.4 4.4 0 0 1 4.4 4.4c0 5.6-8 10.6-8 10.6Z"/></Icon>; }
export function ArrowUpRightIcon({ className }) { return <Icon className={className}><path d="M7 17 17 7"/><path d="M9 7h8v8"/></Icon>; }
export function CheckCircleIcon({ className, title }) { return <Icon className={className} title={title}><circle cx="12" cy="12" r="8.5"/><path d="m8.5 12.2 2.4 2.4 4.6-4.9"/></Icon>; }
export function AlertIcon({ className, title }) { return <Icon className={className} title={title}><path d="M12 4 2.8 20h18.4L12 4Z"/><path d="M12 10v4.4"/><path d="M12 17.2v.1"/></Icon>; }
export function MoonIcon() { return <Icon><path d="M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5Z"/></Icon>; }
export function PieIcon() { return <Icon><path d="M12 3a9 9 0 1 0 9 9h-9V3Z"/><path d="M15 3.6A9 9 0 0 1 20.4 9H15V3.6Z"/></Icon>; }
export function RadioIcon() { return <Icon><circle cx="12" cy="12" r="1.6"/><path d="M8.5 15.5a5 5 0 0 1 0-7"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M5.6 18.4a9 9 0 0 1 0-12.8"/><path d="M18.4 5.6a9 9 0 0 1 0 12.8"/></Icon>; }
export function ResetIcon() { return <Icon><path d="M4 8a8 8 0 1 1-1 6"/><path d="M4 3v5h5"/></Icon>; }
export function SwitchIcon() { return <Icon><rect x="3" y="6" width="18" height="5" rx="2.5"/><circle cx="7" cy="8.5" r="1.4"/><rect x="3" y="13" width="18" height="5" rx="2.5"/><circle cx="17" cy="15.5" r="1.4"/></Icon>; }
export function InfoIcon() { return <Icon><circle cx="12" cy="12" r="8.5"/><path d="M12 11v5"/><path d="M12 8v.1"/></Icon>; }
export function RestartIcon() { return <Icon><path d="M20 12a8 8 0 1 1-2.3-5.6"/><path d="M20 3v4h-4"/></Icon>; }
export function MoreIcon() { return <Icon><path d="M5 12h.1"/><path d="M12 12h.1"/><path d="M19 12h.1"/></Icon>; }
/// The Mac widget chrome's keep-expanded control: `pin` when off, `pin.fill`
/// when on, so the state reads without colour.
export function PinIcon({ className, title, filled }) {
  return (
    <Icon className={className} title={title}>
      <path d="M9 3.5h6"/>
      <path d="M10.2 3.5v5.1L7.6 12.6h8.8L13.8 8.6V3.5Z" fill={filled ? "currentColor" : undefined}/>
      <path d="M12 12.6V20.5"/>
    </Icon>
  );
}
/// The Mac AI Feed widget's identity glyph (`newspaper`).
export function FeedIcon({ className }) {
  return (
    <Icon className={className}>
      <rect x="3" y="5.5" width="13" height="13" rx="1.6"/>
      <path d="M16 9.5h3.4a1.6 1.6 0 0 1 1.6 1.6V17a1.5 1.5 0 0 1-1.5 1.5H16"/>
      <path d="M6 9.5h7M6 12.5h7M6 15.5h4.5"/>
    </Icon>
  );
}
export function PowerIcon() { return <Icon><path d="M12 3v8"/><path d="M6.3 6.5a8 8 0 1 0 11.4 0"/></Icon>; }
export function CloseIcon() { return <Icon><path d="m7 7 10 10"/><path d="M17 7 7 17"/></Icon>; }
/// Menu checkmark. Drawn rather than typed: the "✓" character is placed by the
/// ascent of whichever family Windows resolved for the row, which is why it sat
/// off the row's centre under Segoe UI and Microsoft YaHei alike.
export function CheckIcon({ className }) { return <Icon className={className}><path d="m5 12.5 4.5 4.5L19 7"/></Icon>; }
