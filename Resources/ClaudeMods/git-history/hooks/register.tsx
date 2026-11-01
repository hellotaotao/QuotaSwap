import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { FileChange, OpenCommit, OpenFile, View } from '../types'
import {
  ago,
  clean,
  hunksOf,
  parseLog,
  parseNumstat,
  refLabel,
  totals,
  UNIT,
} from './parse'

const PANE = 'git-history'
const TITLE = 'Git history'
const POLL_MS = 5_000
const PAGE_SIZE = 100
const MAX_FILES = 300
// Cells that line an open commit's text up with the subject in the row above.
const DETAILS_INDENT = 9
const LOG_FORMAT = ['%H', '%h', '%an', '%at', '%D', '%s'].join('%x1f') + '%x1e'
const SHOW_FORMAT = ['%an', '%ad', '%B'].join('%x1f')
// QuotaSwap installs this mod under its own marketplace folder and keeps the
// switch for it there, as `{ showButton, appPath }`.
const SWITCH_FILE = '../../git-history.json'
const TURNED_OFF = `${TITLE} is turned off in QuotaSwap: check "Show Git history button in Claude" in its menu to bring it back.`

const INITIAL: View = {
  repo: null,
  branch: '',
  commits: [],
  hasMore: false,
  error: null,
  isAllBranches: false,
  limit: PAGE_SIZE,
  opened: [],
  file: null,
  isTurnedOn: true,
}

// Change the tag when View's fields change: it declines what an earlier
// version stored, which outlives a reload.
const view = atom({ plugin: 'git-history', key: 'view' } as const, INITIAL, {
  shape: 'view-3',
})

let isPolling = false
// Each press on a file takes a ticket, so a slower answer to an earlier press
// is dropped.
let lastTicket = 0

async function git($: EngineInterface, args: readonly string[]) {
  const { exitCode, stdout, stderr } = await $.process.run([
    'git',
    '--no-pager',
    '--literal-pathspecs',
    '-c',
    'color.ui=false',
    '-c',
    'log.showSignature=false',
    ...args,
  ])

  return { isOk: exitCode === 0, stdout, stderr }
}

async function refresh($: EngineInterface) {
  const current = await read($, view)
  const root = await git($, ['rev-parse', '--show-toplevel'])
  let fresh: Partial<View>

  if (root.isOk) {
    const [branch, log] = await Promise.all([
      git($, ['symbolic-ref', '--short', '-q', 'HEAD']),
      git($, [
        'log',
        `-n${current.limit + 1}`,
        `--format=${LOG_FORMAT}`,
        ...(current.isAllBranches ? ['--all'] : []),
      ]),
    ])
    const commits = log.isOk ? parseLog(log.stdout) : []

    fresh = {
      repo: clean(root.stdout).trim(),
      branch: branch.isOk ? clean(branch.stdout).trim() : 'detached HEAD',
      commits: commits.slice(0, current.limit),
      hasMore: commits.length > current.limit,
      error: log.isOk ? null : clean(log.stderr).trim(),
    }
  } else {
    fresh = {
      repo: null,
      branch: '',
      commits: [],
      hasMore: false,
      error: 'This folder is not a git repository.',
      opened: [],
      file: null,
    }
  }

  if (JSON.stringify({ ...current, ...fresh }) !== JSON.stringify(current)) {
    await update($, view, state => ({ ...state, ...fresh }))
  }
}

// Why the mod is off, or null while it is on. No switch file means on, so a
// copy installed without QuotaSwap keeps its button.
async function offReason($: EngineInterface): Promise<string | null> {
  let flag: unknown

  try {
    flag = JSON.parse(await $.fs.read(`${$.plugin.root}/${SWITCH_FILE}`))
  } catch {
    return null
  }

  if (typeof flag !== 'object' || flag === null) {
    return null
  }

  const { showButton, appPath } = flag as Record<string, unknown>

  if (showButton === false) {
    return TURNED_OFF
  }

  // macOS gives a deleted app no uninstall step, so the switch names the app
  // and a QuotaSwap that is gone turns the mod off.
  if (
    typeof appPath === 'string' &&
    appPath !== '' &&
    !(await $.fs.exists(`${appPath}/Contents/Info.plist`))
  ) {
    return `${TITLE} came with QuotaSwap, which is no longer at ${appPath}.`
  }

  return null
}

async function readSwitch($: EngineInterface) {
  const reason = await offReason($)
  const isTurnedOn = reason === null
  const current = await read($, view)

  if (current.isTurnedOn !== isTurnedOn) {
    await update($, view, state => ({ ...state, isTurnedOn }))
  }

  return reason
}

async function poll($: EngineInterface) {
  const isTurnedOn = (await readSwitch($)) === null
  const panes = await $.ui.panes()

  if (!panes.some(pane => pane.id === PANE)) {
    return
  }

  if (isTurnedOn) {
    await refresh($)
  } else {
    await $.ui.close({ id: PANE })
  }
}

async function openPane($: EngineInterface) {
  const opened = await $.ui.open({ id: PANE, title: TITLE })
  await refresh($)

  return opened
}

async function togglePane($: EngineInterface) {
  const panes = await $.ui.panes()

  if (panes.some(pane => pane.id === PANE)) {
    await $.ui.close({ id: PANE })

    return
  }

  const opened = await openPane($)

  if (!opened.isPlaced) {
    $.ui.toast(`${TITLE}: ${opened.reason}`)
  }
}

async function loadCommit(
  $: EngineInterface,
  sha: string,
): Promise<OpenCommit | null> {
  const [info, stat] = await Promise.all([
    git($, [
      'show',
      '-s',
      '--date=format:%Y-%m-%d %H:%M',
      `--format=${SHOW_FORMAT}`,
      sha,
    ]),
    git($, [
      'show',
      '--format=',
      '--numstat',
      '-z',
      '--diff-merges=first-parent',
      sha,
    ]),
  ])

  if (!info.isOk || !stat.isOk) {
    $.ui.toast(`${TITLE}: ${clean(info.stderr || stat.stderr).trim()}`)

    return null
  }

  const [author = '', date = '', ...message] = info.stdout.split(UNIT)

  return {
    sha,
    author: clean(author),
    date: clean(date),
    message: clean(message.join(UNIT)).trim(),
    files: parseNumstat(stat.stdout),
  }
}

async function toggleCommit($: EngineInterface, sha: string) {
  const { opened } = await read($, view)

  if (opened.some(one => one.sha === sha)) {
    await update($, view, state => ({
      ...state,
      opened: state.opened.filter(one => one.sha !== sha),
      file: state.file?.sha === sha ? null : state.file,
    }))

    return
  }

  const commit = await loadCommit($, sha)

  if (commit !== null) {
    await update($, view, state => ({
      ...state,
      opened: [...state.opened.filter(one => one.sha !== sha), commit],
    }))
  }
}

async function setOpenFile($: EngineInterface, file: OpenFile | null) {
  await update($, view, state => ({ ...state, file }))
}

async function toggleFile($: EngineInterface, sha: string, file: FileChange) {
  lastTicket += 1
  const ticket = lastTicket
  const { file: current } = await read($, view)

  if (current?.sha === sha && current.path === file.path) {
    await setOpenFile($, null)

    return
  }

  const patch = await git($, [
    'show',
    '--format=',
    '--no-ext-diff',
    '--diff-merges=first-parent',
    sha,
    '--',
    ...(file.oldPath === null ? [file.path] : [file.oldPath, file.path]),
  ])

  if (ticket === lastTicket) {
    await setOpenFile($, { sha, path: file.path, ...hunksOf(patch.stdout) })
  }
}

async function showInDiffPane($: EngineInterface, sha: string) {
  try {
    const shown = await $.mcp.call('ccd_view', 'show_pane', {
      pane: 'diff',
      diff_scope: sha,
    })

    if (shown.isError) {
      $.ui.toast(`${TITLE}: the app did not open its diff pane`)
    }
  } catch {
    $.ui.toast(`${TITLE}: the app's diff pane is not reachable from here`)
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'git-history',
      description: "Show this project's commit history in a pane",
    })
    await readSwitch($).catch(() => {})
    await refresh($).catch(() => {})

    if (!isPolling) {
      isPolling = true
      // Other sessions commit to the same repository, so a commit made
      // anywhere has to reach the open pane without a press.
      $.clock.every(POLL_MS, () => {
        void poll($).catch(() => {})
      })
    }

    return next(e)
  })

  on('command.run', { command: 'git-history' }, async $ => {
    const reason = await readSwitch($)

    if (reason !== null) {
      return { text: reason }
    }

    const opened = await openPane($)

    return {
      text: opened.isPlaced ? `${TITLE} pane opened.` : opened.reason,
    }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const { repo, isTurnedOn } = await read($, view)

    if (e.props.hasSurvey || repo === null || !isTurnedOn) {
      return next(e)
    }

    const { Box, Button } = $.ui.resolve(e)

    return (
      <Box>
        <Button key="toggle" label={TITLE} onPress={() => togglePane($)} />
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Code, Text } = $.ui.resolve(e)
    const state = await read($, view)

    if (state.repo === null) {
      return <Text dimColor>{state.error ?? 'Reading history…'}</Text>
    }

    const now = await $.clock.now()
    const details = (commit: OpenCommit) => {
      const { added, deleted } = totals(commit.files)
      const count = commit.files.length
      const hidden = count - MAX_FILES

      return (
        <Box
          flexDirection="column"
          marginBottom={1}
          paddingLeft={DETAILS_INDENT}
          rowGap="xs"
        >
          <Text>{commit.message || '(no message)'}</Text>
          <Box alignItems="center" columnGap={1} marginTop={1}>
            <Text dimColor size="footnote">
              {count} {count === 1 ? 'file' : 'files'} · +{added} −{deleted}
            </Text>
            {e.surface === 'desktop' && (
              <Button
                key={`diff-pane-${commit.sha}`}
                dimColor
                label="Open in diff pane"
                plain
                onPress={() => showInDiffPane($, commit.sha)}
              />
            )}
          </Box>
          {commit.files.slice(0, MAX_FILES).map(file => {
            const open =
              state.file?.sha === commit.sha && state.file.path === file.path
                ? state.file
                : null

            return (
              <Box key={`row-${commit.sha}-${file.path}`} flexDirection="column">
                <Box alignItems="center" columnGap={1}>
                  <Box flexShrink={1} minWidth={0} overflow="hidden">
                    <Button
                      key={`file-${commit.sha}-${file.path}`}
                      plain
                      onPress={() => toggleFile($, commit.sha, file)}
                    >
                      <Text wrap="truncate-start">{clean(file.path)}</Text>
                    </Button>
                  </Box>
                  <Box flexShrink={0}>
                    <Text dimColor size="footnote">
                      +{file.added} −{file.deleted}
                    </Text>
                  </Box>
                </Box>
                {open !== null &&
                  (open.hunks === '' ? (
                    <Text dimColor>No text diff.</Text>
                  ) : (
                    <Box flexDirection="column" marginBottom={1}>
                      <Code
                        source={open.hunks}
                        format="diff"
                        path={clean(file.path)}
                      />
                      {open.isCut && (
                        <Text dimColor>
                          Diff cut short: it is too long to draw.
                        </Text>
                      )}
                    </Box>
                  ))}
              </Box>
            )
          })}
          {hidden > 0 && <Text dimColor>{hidden} more files.</Text>}
        </Box>
      )
    }

    return (
      <Box flexDirection="column">
        <Box columnGap={1} marginBottom={1} alignItems="center">
          <Text weight="semibold">{state.branch}</Text>
          <Button
            key="scope"
            label={state.isAllBranches ? 'All branches' : 'This branch'}
            onPress={async () => {
              await update($, view, current => ({
                ...current,
                isAllBranches: !current.isAllBranches,
                limit: PAGE_SIZE,
              }))
              await refresh($)
            }}
          />
        </Box>
        {state.error !== null && <Text dimColor>{state.error}</Text>}
        <Box flexDirection="column" rowGap="xs">
          {state.commits.map(one => {
            const refs = refLabel(one.refs)
            const commit = state.opened.find(item => item.sha === one.sha)

            // Only the subject gives way on a narrow row. The desktop flattens
            // what is inside a Button, so the styled parts stand beside it and
            // an open commit's message below it, the press staying in place.
            return (
              <Box key={`row-${one.sha}`} flexDirection="column">
                <Box alignItems="center" columnGap={1}>
                  <Text dimColor mono>
                    {one.shortSha}
                  </Text>
                  <Box flexShrink={1} minWidth={0} overflow="hidden">
                    <Button
                      key={`commit-${one.sha}`}
                      dimColor={commit !== undefined}
                      plain
                      onPress={() => toggleCommit($, one.sha)}
                    >
                      <Text wrap="truncate-end">
                        {commit === undefined
                          ? one.subject || '(no subject)'
                          : `▾ ${commit.author} · ${commit.date}`}
                      </Text>
                    </Button>
                  </Box>
                  {refs !== '' && (
                    <Box flexShrink={0}>
                      <Text color="suggestion" size="footnote">
                        {refs}
                      </Text>
                    </Box>
                  )}
                  <Box flexGrow={1} />
                  <Box flexShrink={0}>
                    <Text dimColor size="footnote">
                      {ago(one.unixTime, now)}
                    </Text>
                  </Box>
                </Box>
                {commit !== undefined && details(commit)}
              </Box>
            )
          })}
        </Box>
        {state.hasMore && (
          <Button
            key="more"
            label="Load more"
            onPress={async () => {
              await update($, view, current => ({
                ...current,
                limit: current.limit + PAGE_SIZE,
              }))
              await refresh($)
            }}
          />
        )}
      </Box>
    )
  })
}
