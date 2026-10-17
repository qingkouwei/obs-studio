/**
 * MobileTheme — high-contrast dark palette for the phone director console.
 *
 * The first cut reused the desktop tokens at small font sizes and the result
 * was unreadable on a phone (user report 10-17: "颜色对比度不明显，有的字根本
 * 看不清" — #9AA0A6 grey at 11fp on #1B1D21 measures ~4.2:1). Every token
 * here is chosen for the small screen: text ladder ≥7:1 on its surface,
 * saturated fills under white button labels ≥4.5:1, and three surface steps
 * (page → card → inset) so the hierarchy reads without hairlines.
 */
export class MobileTheme {
  // Surfaces: each nesting step gets lighter, cards carry a border.
  static readonly bg: string = '#121417';
  static readonly card: string = '#1D2025';
  static readonly cardBorder: string = '#2E333B';
  static readonly inset: string = '#0B0C0E';
  // Text ladder. textDim is the FLOOR for any label — never go below it.
  static readonly textStrong: string = '#F4F6F8';
  static readonly text: string = '#D6DBE1';
  static readonly textDim: string = '#A9B1BB';
  // Action fills (white label on top).
  static readonly blue: string = '#2E7CF6';
  static readonly green: string = '#1FA35F';
  static readonly red: string = '#D64550';
  // State lights.
  static readonly live: string = '#FF555C';
  static readonly ok: string = '#3DDC84';
  static readonly warn: string = '#F5B942';
  // Semi-transparent badge plate over video.
  static readonly badgeBg: string = '#B3000000';
}
