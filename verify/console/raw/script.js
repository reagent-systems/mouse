// The CONSOLE audit. In a terminal IDE every one of these is a visible feature, and the routing
// matters as much as the text: warn/error go to STDERR, and a tool piping stdout must not get
// them mixed in. stdout and stderr are printed separately so the split is part of the check.
console.log('log line');
console.info('info line');
console.debug('debug line');
console.warn('warn line');
console.error('error line');
console.dir({ a: { b: { c: 1 } } });
console.dir({ a: { b: { c: 1 } } }, { depth: 0 });
console.group('group A');
console.log('inside A');
console.group('group B');
console.log('inside B');
console.groupEnd();
console.log('back in A');
console.groupEnd();
console.log('outside');
console.count();
console.count();
console.count('tag');
console.countReset();
console.count();
console.assert(true, 'never shown');
console.assert(false, 'assertion text');
console.table([{ a: 1, b: 'x' }, { a: 2, b: 'y' }]);
console.table({ row: { col: 1 } });
console.table([1, 2]);
console.log('has methods:', ['table', 'group', 'groupEnd', 'count', 'countReset', 'time',
  'timeEnd', 'timeLog', 'dir', 'assert', 'trace', 'clear', 'groupCollapsed', 'dirxml',
  'profile', 'profileEnd', 'timeStamp'].filter(n => typeof console[n] !== 'function').join(',') || 'all present');
// timers print a duration, which varies — only the shape is checked.
console.time('t');
console.timeEnd('t');
