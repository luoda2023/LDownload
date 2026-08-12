// 任务主界面的纯 UI 状态（筛选 / 搜索 / 选中 / 折叠 / 详情面板），与服务端数据（React Query）分离。
// react-compiler 已启用，不手写 useMemo/useCallback。

import { createContext, useContext, useState, type Dispatch, type ReactNode, type SetStateAction } from 'react'
import { dirKey } from '../../lib/task-group'
import { ALL_CATEGORY } from '../../lib/categories'
import type { StatusTab } from './filters'

export type DetailTab = 'general' | 'segments' | 'queue' | 'log' | 'advanced'

const DEVICE_FILTER_KEY = 'ldownload.tasks.deviceFilter'

interface TasksUiState {
  /** 分类筛选：`ALL_CATEGORY` = 不筛选，其余为分类 id（见 lib/categories.ts）。 */
  categoryFilter: string
  setCategoryFilter: Dispatch<SetStateAction<string>>
  queueFilter: string
  setQueueFilter: Dispatch<SetStateAction<string>>
  /** 设备筛选：null=全部设备；本机=cloudDeviceId()；远程设备=其 deviceId（见 Sidebar 设备区）。 */
  deviceFilter: string | null
  setDeviceFilter: Dispatch<SetStateAction<string | null>>
  /** 选中的 RSS 订阅 id：非 null 时条目流接管中央主区（与任务列表互斥）。 */
  rssFilter: string | null
  setRssFilter: Dispatch<SetStateAction<string | null>>
  statusTab: StatusTab
  setStatusTab: Dispatch<SetStateAction<StatusTab>>
  search: string
  setSearch: Dispatch<SetStateAction<string>>
  manageMode: boolean
  setManageMode: Dispatch<SetStateAction<boolean>>
  selected: Set<string>
  setSelected: Dispatch<SetStateAction<Set<string>>>
  foldedSections: Set<string>
  toggleSectionFold: (key: string) => void
  expandedGroups: Set<string>
  toggleGroupExpand: (id: string) => void
  scrollTarget: string | null
  clearScrollTarget: () => void
  /** 失败直达：展开目标组（并展开成员所在目录，若已折叠）+ 请求 TaskList 滚动到该成员行。 */
  jumpToGroupMember: (groupId: string, taskId: string, dirPath?: string) => void
  collapsedDirs: Set<string>
  toggleDirCollapsed: (groupId: string, path: string) => void
  /** 当前选中的任务组（组详情面板；与 currentTaskId 互斥，见 selectGroup/selectTask）。 */
  selectedGroupId: string | null
  groupDetailOpen: boolean
  selectGroup: (id: string) => void
  closeGroupDetail: () => void
  /** 清空任务/任务组选中并收起两个详情面板——列表空白处点击等「退出选中」入口共用。 */
  clearSelection: () => void
  currentTaskId: string | null
  detailOpen: boolean
  sidebarOpen: boolean
  setSidebarOpen: Dispatch<SetStateAction<boolean>>
  detailTab: DetailTab
  setDetailTab: Dispatch<SetStateAction<DetailTab>>
  selectTask: (id: string) => void
  closeDetail: () => void
}

const Ctx = createContext<TasksUiState | null>(null)

export function TasksUiProvider({ children }: { children: ReactNode }) {
  const [categoryFilter, setCategoryFilter] = useState<string>(ALL_CATEGORY)
  const [queueFilter, setQueueFilter] = useState('all')
  const [deviceFilter, setDeviceFilterState] = useState<string | null>(() => localStorage.getItem(DEVICE_FILTER_KEY))
  const [rssFilter, setRssFilter] = useState<string | null>(null)
  const [statusTab, setStatusTab] = useState<StatusTab>('all')
  const [search, setSearch] = useState('')
  const [manageMode, setManageModeState] = useState(false)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [foldedSections, setFoldedSections] = useState<Set<string>>(new Set())
  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(new Set())
  const [scrollTarget, setScrollTarget] = useState<string | null>(null)
  const [collapsedDirs, setCollapsedDirs] = useState<Set<string>>(new Set())
  const [selectedGroupId, setSelectedGroupId] = useState<string | null>(null)
  const [groupDetailOpen, setGroupDetailOpen] = useState(false)
  const [currentTaskId, setCurrentTaskId] = useState<string | null>(null)
  const [detailOpen, setDetailOpen] = useState(false)
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [detailTab, setDetailTab] = useState<DetailTab>('general')

  function setManageMode(v: SetStateAction<boolean>) {
    setManageModeState(v)
    setSelected(new Set())
  }
  function setDeviceFilter(v: SetStateAction<string | null>) {
    setDeviceFilterState((prev) => {
      const next = typeof v === 'function' ? (v as (p: string | null) => string | null)(prev) : v
      if (next === null) localStorage.removeItem(DEVICE_FILTER_KEY)
      else localStorage.setItem(DEVICE_FILTER_KEY, next)
      return next
    })
  }
  function toggleSectionFold(key: string) {
    setFoldedSections((prev) => {
      const next = new Set(prev)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }
  function selectTask(id: string) {
    setCurrentTaskId(id)
    setDetailOpen(true)
    setSelectedGroupId(null)
    setGroupDetailOpen(false)
  }
  function selectGroup(id: string) {
    setSelectedGroupId(id)
    setGroupDetailOpen(true)
    setCurrentTaskId(null)
    setDetailOpen(false)
  }
  // 面板关闭即选中结束：留着 currentTaskId/selectedGroupId 会让列表行挂着一圈
  // 无法解释的选中态（面板已经不在了），用户只能靠再点一次同一行才消得掉。
  function closeGroupDetail() {
    setGroupDetailOpen(false)
    setSelectedGroupId(null)
  }
  function toggleGroupExpand(id: string) {
    setExpandedGroups((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }
  function jumpToGroupMember(groupId: string, taskId: string, dirPath?: string) {
    setExpandedGroups((prev) => (prev.has(groupId) ? prev : new Set(prev).add(groupId)))
    if (dirPath) {
      const key = dirKey(groupId, dirPath)
      setCollapsedDirs((prev) => {
        if (!prev.has(key)) return prev
        const next = new Set(prev)
        next.delete(key)
        return next
      })
    }
    setScrollTarget(taskId)
  }
  function toggleDirCollapsed(groupId: string, path: string) {
    const key = dirKey(groupId, path)
    setCollapsedDirs((prev) => {
      const next = new Set(prev)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }
  function clearScrollTarget() {
    setScrollTarget(null)
  }
  function closeDetail() {
    setDetailOpen(false)
    setCurrentTaskId(null)
  }
  function clearSelection() {
    setCurrentTaskId(null)
    setDetailOpen(false)
    setSelectedGroupId(null)
    setGroupDetailOpen(false)
  }

  return (
    <Ctx.Provider
      value={{
        categoryFilter,
        setCategoryFilter,
        queueFilter,
        setQueueFilter,
        deviceFilter,
        setDeviceFilter,
        rssFilter,
        setRssFilter,
        statusTab,
        setStatusTab,
        search,
        setSearch,
        manageMode,
        setManageMode,
        selected,
        setSelected,
        foldedSections,
        toggleSectionFold,
        expandedGroups,
        toggleGroupExpand,
        scrollTarget,
        clearScrollTarget,
        jumpToGroupMember,
        collapsedDirs,
        toggleDirCollapsed,
        selectedGroupId,
        groupDetailOpen,
        selectGroup,
        closeGroupDetail,
        clearSelection,
        currentTaskId,
        detailOpen,
        sidebarOpen,
        setSidebarOpen,
        detailTab,
        setDetailTab,
        selectTask,
        closeDetail,
      }}
    >
      {children}
    </Ctx.Provider>
  )
}

export function useTasksUi(): TasksUiState {
  const ctx = useContext(Ctx)
  if (!ctx) throw new Error('useTasksUi must be used within TasksUiProvider')
  return ctx
}
