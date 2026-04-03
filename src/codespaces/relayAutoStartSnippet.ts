/**
 * Merge these keys into an existing `.devcontainer/devcontainer.json` (or start from `{}`)
 * so `@mouse-app/relay` starts in the background whenever the Codespace resumes.
 */
export const RELAY_DEVCONTAINER_MERGE_JSON = JSON.stringify(
  {
    forwardPorts: [2222],
    portsAttributes: {
      '2222': {
        label: 'Mouse relay',
        visibility: 'public',
      },
    },
    postStartCommand:
      "bash -lc 'nohup npx -y @mouse-app/relay@latest >>/tmp/mouse-relay.log 2>&1 &'",
  },
  null,
  2,
)
