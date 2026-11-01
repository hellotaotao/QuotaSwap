import type { On } from 'claude-code'
import type { Engine } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'

import {
  MAX_DIFF_CHARS,
  ago,
  hunksOf,
  parseLog,
  parseNumstat,
  refLabel,
  refNames,
} from '../hooks/parse'

const PANE = {
  plugin: 'git-history',
  component: 'Pane',
  requestId: 'git-history',
  props: {
    title: 'Git history',
    isFocused: false,
    bodyColumns: 60,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

const BAND = {
  plugin: 'git-history',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 10,
    bodyColumns: 80,
    scroll: { offset: 0, bodyRows: 10 },
    view: {},
  },
} as const

const APP = '/Applications/QuotaSwap.app'

const SHA = 'a'.repeat(40)
const LOG = `${SHA}\x1faaaaaaa\x1fTao Wang\x1f1793405243\x1fHEAD -> dev\x1fFix the pane\x1e\n`
const PATCH = [
  'diff --git a/app.ts b/app.ts',
  'index 1234567..89abcde 100644',
  '--- a/app.ts',
  '+++ b/app.ts',
  '@@ -1 +1 @@',
  '-old\r',
  '+new\r',
  '',
].join('\n')

function answer(argv: readonly string[]) {
  const ok = (stdout: string) => ({
    exitCode: 0,
    stdout,
    stderr: '',
    isStdoutTruncated: false,
    isStderrTruncated: false,
  })

  if (argv.includes('rev-parse')) {
    return ok('/code/app\n')
  }

  if (argv.includes('symbolic-ref')) {
    return ok('dev\n')
  }

  if (argv.includes('log')) {
    return ok(LOG)
  }

  if (argv.includes('--numstat')) {
    return ok('1\t1\tapp.ts\0')
  }

  if (argv.includes('-s')) {
    return ok(`Tao Wang\x1f2026-10-31 10:00\x1fFix the pane\n\nThe long reason.\n`)
  }

  return ok(PATCH)
}

// A session in a repository whose switch file holds `world.flag` (missing
// while undefined), the pane open while `world.isPaneOpen`, and QuotaSwap
// installed at APP alone.
async function startSwitched(
  $: Engine,
  on: On,
  world: { flag?: string; isPaneOpen: boolean; closed: string[] },
) {
  const clock = mock.clock(on, { now: 1793408843000 })

  on('command.register', () => ({ value: { command: 'git-history' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('process.run', (_, e) => ({ value: answer(e.argv) }))
  on('fs.read', (_, e, next) =>
    e.path.endsWith('/git-history.json') && world.flag !== undefined
      ? { value: world.flag }
      : next(e),
  )
  on('fs.exists', (_, e) => ({ value: e.path === `${APP}/Contents/Info.plist` }))
  on('ui.panes', () => ({
    value: world.isPaneOpen
      ? [
          {
            id: 'git-history',
            title: 'Git history',
            isShown: true,
            isFocused: false,
            isPlaced: true,
          },
        ]
      : [],
  }))
  on('ui.close', (_, e) => {
    world.closed.push(e.id)
    world.isPaneOpen = false

    return { value: undefined }
  })
  on('ui.open', () => {
    world.isPaneOpen = true

    return { value: { isPlaced: true } }
  })
  // The engine's own band, empty.
  on('ui.render', { component: 'AbovePrompt' }, () => ({ type: 'Box' as const }))

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  return clock
}

const RUN = {
  command: 'git-history',
  args: '',
  origin: { kind: 'composer' },
  presentation: { isFullscreen: false, columns: 80 },
} as const

const flag = (showButton: boolean, appPath = APP) =>
  JSON.stringify({ showButton, appPath })

test('no switch file keeps the button and the command', async ($, on) => {
  const world = { isPaneOpen: false, closed: [] as string[] }

  await startSwitched($, on, world)

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })
  expect(await ui.find({ type: 'Button', key: 'toggle' })).toBeDefined()
  await ui.unmount()

  const run = await $.command.run(RUN)
  expect(run.text).toBe('Git history pane opened.')
})

test('a garbled switch file keeps the button', async ($, on) => {
  const world = { flag: '{"showButton": fal', isPaneOpen: false, closed: [] as string[] }

  await startSwitched($, on, world)

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })
  expect(await ui.find({ type: 'Button', key: 'toggle' })).toBeDefined()
  await ui.unmount()
})

test('the switch hides the button and the pane within a tick, and brings the button back', async ($, on) => {
  const world = { flag: flag(true), isPaneOpen: true, closed: [] as string[] }
  const clock = await startSwitched($, on, world)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...BAND, surface })
    expect(await ui.find({ type: 'Button', key: 'toggle' })).toBeDefined()
    await ui.unmount()
  }

  world.flag = flag(false)
  await clock.advance(5_000)
  expect(world.closed).toEqual(['git-history'])

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...BAND, surface })
    expect(await ui.find({ type: 'Button', key: 'toggle' })).toBeUndefined()
    await ui.unmount()
  }

  const refused = await $.command.run(RUN)
  expect(refused.text).toContain('turned off in QuotaSwap')
  expect(world.isPaneOpen).toBe(false)

  world.flag = flag(true)
  await clock.advance(5_000)

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })
  expect(await ui.find({ type: 'Button', key: 'toggle' })).toBeDefined()
  await ui.unmount()
  expect(world.closed).toEqual(['git-history'])
})

test('the button goes when the QuotaSwap that installed it is gone', async ($, on) => {
  const world = {
    flag: flag(true, '/Users/me/.Trash/QuotaSwap.app'),
    isPaneOpen: false,
    closed: [] as string[],
  }

  await startSwitched($, on, world)

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })
  expect(await ui.find({ type: 'Button', key: 'toggle' })).toBeUndefined()
  await ui.unmount()

  const refused = await $.command.run(RUN)
  expect(refused.text).toBe(
    'Git history came with QuotaSwap, which is no longer at /Users/me/.Trash/QuotaSwap.app.',
  )
  expect(world.isPaneOpen).toBe(false)
})

test('a row opens in place and closes with the same press', async ($, on) => {
  on('command.register', () => ({ value: { command: 'git-history' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('clock.every', () => ({ value: undefined }))
  on('clock.now', () => ({ value: 1793408843000 }))
  on('process.run', (_, e) => ({ value: answer(e.argv) }))

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })

    expect(await ui.find({ type: 'Text', text: /^aaaaaaa$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^Fix the pane$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Tao Wang/ })).toBeUndefined()
    await ui.press({ key: `commit-${SHA}` })
    expect(
      (await ui.find({ type: 'Text', text: /The long reason/ }))?.text,
    ).toContain('Fix the pane')
    expect(await ui.find({ type: 'Text', text: /^aaaaaaa$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Tao Wang/ })).toBeDefined()

    await ui.press({ key: `file-${SHA}-app.ts` })
    const code = await ui.find({ type: 'Code' })
    expect(code?.text).toBe('@@ -1 +1 @@\n-old\n+new')

    await ui.press({ key: `file-${SHA}-app.ts` })
    expect(await ui.find({ type: 'Code' })).toBeUndefined()

    await ui.press({ key: `file-${SHA}-app.ts` })
    await ui.press({ key: `commit-${SHA}` })
    expect(await ui.find({ type: 'Text', text: /The long reason/ })).toBeUndefined()
    expect(await ui.find({ type: 'Code' })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /^Fix the pane$/ })).toBeDefined()
    await ui.unmount()
  }
})

test('two commits stay open side by side', async ($, on) => {
  const other = 'b'.repeat(40)

  on('command.register', () => ({ value: { command: 'git-history' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('clock.every', () => ({ value: undefined }))
  on('clock.now', () => ({ value: 1793408843000 }))
  on('process.run', (_, e) => ({
    value: e.argv.includes('log')
      ? { ...answer(e.argv), stdout: `${LOG}${other}\x1fbbbbbbb\x1fTao Wang\x1f1793405243\x1f\x1fSecond\x1e\n` }
      : answer(e.argv),
  }))

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  await ui.press({ key: `commit-${SHA}` })
  await ui.press({ key: `commit-${other}` })
  expect(await ui.find({ type: 'Button', key: `file-${SHA}-app.ts` })).toBeDefined()
  expect(await ui.find({ type: 'Button', key: `file-${other}-app.ts` })).toBeDefined()

  await ui.press({ key: `commit-${SHA}` })
  expect(await ui.find({ type: 'Button', key: `file-${SHA}-app.ts` })).toBeUndefined()
  expect(await ui.find({ type: 'Button', key: `file-${other}-app.ts` })).toBeDefined()
  await ui.unmount()
})

test('the band offers the pane only inside a repository', async ($, on) => {
  on('command.register', () => ({ value: { command: 'git-history' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('clock.every', () => ({ value: undefined }))
  on('process.run', () => ({
    value: {
      exitCode: 128,
      stdout: '',
      stderr: 'fatal: not a git repository',
      isStdoutTruncated: false,
      isStderrTruncated: false,
    },
  }))

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text' }))?.text).toBe(
    'This folder is not a git repository.',
  )
  await ui.unmount()
})

test('parsers read what git prints', () => {
  expect(parseLog(LOG)[0]?.subject).toBe('Fix the pane')
  expect(parseNumstat('1\t2\ta.ts\0-\t-\timg.png\0')).toEqual([
    { path: 'a.ts', oldPath: null, added: '1', deleted: '2' },
    { path: 'img.png', oldPath: null, added: '-', deleted: '-' },
  ])
  expect(parseNumstat('3\t4\t\0old.ts\0new.ts\0')).toEqual([
    { path: 'new.ts', oldPath: 'old.ts', added: '3', deleted: '4' },
  ])
})

test('a row names only the refs worth reading', () => {
  expect(
    refNames('HEAD -> main, tag: v1.0, origin/main, origin/HEAD, feature/a, origin/feature/a'),
  ).toEqual(['main', 'v1.0', 'feature/a'])
  expect(refNames('origin/other')).toEqual(['origin/other'])
  expect(refNames('HEAD')).toEqual([])
  expect(refNames('')).toEqual([])
  expect(refLabel('HEAD -> main, tag: v1.0')).toBe('main · v1.0')
  expect(refLabel('main, tag: v1.0, tag: v1.1, dev')).toBe('main · v1.0 · +2')
  expect(refLabel('')).toBe('')
})

test('a row keeps its age short', () => {
  const now = 1793408843000
  const secondsAgo = (seconds: number) => now / 1000 - seconds

  expect(ago(secondsAgo(5), now)).toBe('now')
  expect(ago(secondsAgo(300), now)).toBe('5m')
  expect(ago(secondsAgo(7_200), now)).toBe('2h')
  expect(ago(secondsAgo(172_800), now)).toBe('2d')
  expect(ago(secondsAgo(86_400 * 40), now)).toMatch(/^\d{4}-\d{2}-\d{2}$/)
})

test('a long diff is cut where a hunk starts', () => {
  const hunk = `@@ -1 +1 @@\n${'+x\n'.repeat(MAX_DIFF_CHARS / 6)}`
  const { hunks, isCut } = hunksOf(`header\n${hunk}${hunk}${hunk}`)

  expect(isCut).toBe(true)
  expect(hunks.length).toBeLessThanOrEqual(MAX_DIFF_CHARS)
  expect(hunks.endsWith('+x')).toBe(true)
  expect(hunksOf('Binary files differ\n').hunks).toBe('')
})
