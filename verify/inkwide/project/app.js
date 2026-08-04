import React from 'react';
import { render, Box, Text } from 'ink';
// Three rows of equal DISPLAY width inside one bordered box. ink measures each with
// string-width and decides where the right border goes; if the engine disagrees about how wide
// 日本語 is, the border comes out ragged. Rendering to a plain (non-TTY) stdout gives the frame
// as text, which is exactly what the comparison needs.
const App = () => React.createElement(Box, { borderStyle: 'single', flexDirection: 'column', width: 20 },
  React.createElement(Text, null, 'abcdef'),
  React.createElement(Text, null, '日本語'),
  React.createElement(Text, null, 'a日b'),
  React.createElement(Text, null, '🎉ok'));
render(React.createElement(App));
