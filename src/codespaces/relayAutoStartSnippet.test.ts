import { describe, it, expect } from 'vitest'
import { RELAY_DEVCONTAINER_MERGE_JSON } from './relayAutoStartSnippet.ts'

describe('RELAY_DEVCONTAINER_MERGE_JSON', () => {
  it('is valid JSON that forwards the relay port', () => {
    const parsed = JSON.parse(RELAY_DEVCONTAINER_MERGE_JSON)
    expect(parsed.forwardPorts).toContain(2222)
    expect(parsed.portsAttributes['2222'].visibility).toBe('public')
    expect(parsed.postStartCommand).toContain('@mouse-app/relay')
  })
})
