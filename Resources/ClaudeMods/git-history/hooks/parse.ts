import type { Commit, FileChange, OpenFile } from '../types'

export const UNIT = '\x1f'
export const RECORD = '\x1e'
export const MAX_DIFF_CHARS = 60_000
const MAX_REFS = 2

// Text and Code refuse every control character but tab and newline, and git
// passes a file's carriage returns through.
export const clean = (text: string) =>
  text.replace(/[\x00-\x08\x0b-\x1f\x7f]/g, '')

export function parseLog(stdout: string): Commit[] {
  return stdout.split(RECORD).flatMap(record => {
    const [sha, shortSha, author, unixTime, refs, subject] = record
      .trim()
      .split(UNIT)

    if (!sha || !shortSha || unixTime === undefined) {
      return []
    }

    return [
      {
        sha,
        shortSha,
        author: clean(author ?? ''),
        unixTime: Number(unixTime),
        refs: clean(refs ?? ''),
        subject: clean(subject ?? ''),
      },
    ]
  })
}

// `git show --numstat -z`: a file is `added\tdeleted\tpath\0`, a rename
// `added\tdeleted\t\0old\0new\0`. Binary files count `-`.
export function parseNumstat(stdout: string): FileChange[] {
  const parts = stdout.split('\0')
  const files: FileChange[] = []

  for (let index = 0; index < parts.length; index += 1) {
    const row = /^\s*(\S+)\t(\S+)\t(.*)$/s.exec(parts[index] ?? '')

    if (row === null) {
      continue
    }

    const [, added = '', deleted = '', path = ''] = row

    if (path !== '') {
      files.push({ path, oldPath: null, added, deleted })
      continue
    }

    const oldPath = parts[index + 1] ?? ''
    const newPath = parts[index + 2] ?? ''
    index += 2
    files.push({ path: newPath, oldPath, added, deleted })
  }

  return files
}

// `Code` under `format: 'diff'` reads hunks only, and a hunk cut in the middle
// does not parse, so the cut falls where a hunk starts.
export function hunksOf(patch: string): Pick<OpenFile, 'hunks' | 'isCut'> {
  const start = patch.search(/^@@/m)

  if (start === -1) {
    return { hunks: '', isCut: false }
  }

  const hunks = clean(patch.slice(start)).trimEnd()

  if (hunks.length <= MAX_DIFF_CHARS) {
    return { hunks, isCut: false }
  }

  const end = hunks.lastIndexOf('\n@@', MAX_DIFF_CHARS)

  return { hunks: hunks.slice(0, end > 0 ? end : MAX_DIFF_CHARS), isCut: true }
}

// `%D` reads `HEAD -> main, tag: v1, origin/main, origin/HEAD`. HEAD's branch is
// in the pane's header, and a remote branch beside its local one adds nothing.
export function refNames(refs: string): string[] {
  const names = refs
    .split(', ')
    .map(ref => ref.replace(/^HEAD -> /, '').replace(/^tag: /, ''))
    .filter(ref => ref !== '' && ref !== 'HEAD' && !ref.endsWith('/HEAD'))

  return names.filter(ref => {
    const slash = ref.indexOf('/')

    return slash === -1 || !names.includes(ref.slice(slash + 1))
  })
}

export function refLabel(refs: string): string {
  const names = refNames(refs)
  const hidden = names.length - MAX_REFS

  return [
    ...names.slice(0, MAX_REFS),
    ...(hidden > 0 ? [`+${hidden}`] : []),
  ].join(' · ')
}

export function ago(unixTime: number, nowMs: number): string {
  const minutes = Math.floor((nowMs / 1000 - unixTime) / 60)

  if (minutes < 1) {
    return 'now'
  }

  if (minutes < 60) {
    return `${minutes}m`
  }

  const hours = Math.floor(minutes / 60)

  if (hours < 24) {
    return `${hours}h`
  }

  const days = Math.floor(hours / 24)

  if (days < 30) {
    return `${days}d`
  }

  return new Date(unixTime * 1000).toISOString().slice(0, 10)
}

export function totals(files: readonly FileChange[]) {
  const sum = (count: (file: FileChange) => string) =>
    files.reduce((all, file) => all + (Number(count(file)) || 0), 0)

  return { added: sum(file => file.added), deleted: sum(file => file.deleted) }
}
