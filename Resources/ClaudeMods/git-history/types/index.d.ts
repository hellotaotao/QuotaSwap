export type Commit = {
  sha: string
  shortSha: string
  author: string
  unixTime: number
  refs: string
  subject: string
}

export type FileChange = {
  path: string
  oldPath: string | null
  added: string
  deleted: string
}

export type OpenFile = {
  sha: string
  path: string
  hunks: string
  isCut: boolean
}

export type OpenCommit = {
  sha: string
  author: string
  date: string
  message: string
  files: FileChange[]
}

export type View = {
  repo: string | null
  branch: string
  commits: Commit[]
  hasMore: boolean
  error: string | null
  isAllBranches: boolean
  limit: number
  opened: OpenCommit[]
  file: OpenFile | null
  // False while QuotaSwap's switch hides the band button and the pane.
  isTurnedOn: boolean
}

declare module 'claude-code' {
  interface PluginState {
    'git-history': { view: Shaped<View> }
  }
}
