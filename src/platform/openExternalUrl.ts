/** Open a URL in the system browser (Electron, Capacitor WebView, or tab). */
export function openExternalUrl(url: string): void {
  const w = window as Window & { __electron__?: { openExternal: (u: string) => void } }
  if (w.__electron__) {
    w.__electron__.openExternal(url)
    return
  }
  window.open(url, '_blank', 'noopener,noreferrer')
}
