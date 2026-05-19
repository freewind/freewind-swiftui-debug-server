import type { FC, ReactNode } from 'react'
import { useEffect, useRef, useState } from 'react'
import {
  App as AntdApp,
  Button,
  Card,
  Divider,
  Flex,
  Form,
  Input,
  InputNumber,
  Layout,
  Popover,
  Select,
  Space,
  Statistic,
  Table,
  Tabs,
  Tag,
  Tree,
  Typography,
  type FormItemProps,
} from 'antd'
import { InfoCircleOutlined } from '@ant-design/icons'
import type { ColumnsType } from 'antd/es/table'
import type { DataNode } from 'antd/es/tree'
import { buildQuery, fetchJSON } from './api'
import { FloatLabel } from '@freewind/FloatLabel'
import { JsonPreviewer } from '@freewind/JsonPreviewer'
import type {
  ActionCatalogResponse,
  ActionRequest,
  ActionResponse,
  HelpResponse,
  LogEntry,
  LogsClearResponse,
  LogsResponse,
  SnapshotPreviewNode,
  SnapshotResponse,
  StateResponse,
} from './types'

type SnapshotTreeNode = {
  id: string
  kind: string
  label: string
  clickable: boolean
  children: SnapshotTreeNode[]
}

const { Header, Content } = Layout
const { Title, Text } = Typography
const compactInputStyle = { width: '100%' } as const
const compactNumberStyle = { width: '100%' } as const
const compactSelectStyle = { width: '100%' } as const
const commonSelectProps = {
  popupMatchSelectWidth: false,
  optionFilterProp: 'label' as const,
  showSearch: true,
  size: 'small' as const,
  style: compactSelectStyle,
}
const snapshotPreviewFallbackWidth = 520
const snapshotPreviewFields = [
  'id',
  'parentId',
  'type',
  'text',
  'role',
  'visible',
  'enabled',
  'clickable',
  'value',
  'bounds',
].join(',')
const triStateOptions = [
  { label: 'true', value: 'true' },
  { label: 'false', value: 'false' },
]
const stateScopeOptions = [
  { label: 'app', value: 'app' },
  { label: 'target', value: 'target' },
  { label: 'branch', value: 'branch' },
]
const snapshotScopeOptions = [
  { label: 'self', value: 'self' },
  { label: 'branchToRoot', value: 'branchToRoot' },
  { label: 'subtree', value: 'subtree' },
]

function toOptions(values: Array<string | null | undefined>) {
  return Array.from(new Set(values.filter((value): value is string => !!value)))
    .map((value) => ({
      label: value,
      value,
    }))
}

function renderJson(value: unknown, maxHeight = 280) {
  return <JsonPreviewer value={value ?? {}} maxHeight={maxHeight} />
}

const JsonInfoButton: FC<{
  title: string
  value: unknown
  maxHeight?: number
}> = ({
  title,
  value,
  maxHeight = 320,
}) => {
  return (
    <Popover
      trigger="click"
      placement="leftTop"
      title={title}
      content={(
        <div style={{ width: 420, maxWidth: '70vw' }}>
          {renderJson(value, maxHeight)}
        </div>
      )}
    >
      <Button
        size="small"
        type="text"
        icon={<InfoCircleOutlined />}
      />
    </Popover>
  )
}

const LabeledField: FC<{
  name: string
  label: string
  className?: string
  rules?: FormItemProps['rules']
  children: ReactNode
}> = ({
  name,
  label,
  className,
  rules,
  children,
}) => {
  return (
    <div className={className}>
      <Form.Item style={{ marginBottom: 0 }}>
        <FloatLabel label={label} size="small">
          <Form.Item name={name} noStyle rules={rules}>
            {children}
          </Form.Item>
        </FloatLabel>
      </Form.Item>
    </div>
  )
}

const logColumns: ColumnsType<LogEntry> = [
  { title: 'seq', dataIndex: 'seq', width: 80 },
  { title: 'time', dataIndex: 'time', width: 170 },
  { title: 'source', dataIndex: 'source', width: 120 },
  { title: 'level', dataIndex: 'level', width: 100 },
  { title: 'event', dataIndex: 'event', width: 140 },
  { title: 'targetId', dataIndex: 'targetId', width: 160, render: (value) => value || '-' },
  { title: 'summary', dataIndex: 'summary' },
  {
    title: 'data',
    dataIndex: 'data',
    width: 260,
    render: (value) => <JsonPreviewer value={value || {}} maxHeight={160} />,
  },
]

function normalizeSnapshotQuery(values?: Record<string, unknown>) {
  const next: Record<string, unknown> = { ...(values || {}) }
  next.fields = snapshotPreviewFields
  if (next.limit === undefined || next.limit === null || next.limit === '') {
    next.limit = 200
  }
  return next
}

function toSnapshotPreviewNodes(snapshot: SnapshotResponse | null): SnapshotPreviewNode[] {
  return (snapshot?.nodes || [])
    .filter((node): node is SnapshotPreviewNode => {
      return !!node.bounds
        && node.visible !== false
        && node.bounds.width > 0
        && node.bounds.height > 0
    })
    .sort((left, right) => {
      return (right.bounds.width * right.bounds.height) - (left.bounds.width * left.bounds.height)
    })
}

function buildSnapshotTree(snapshot: SnapshotResponse | null): SnapshotTreeNode[] {
  const nodes = snapshot?.nodes || []
  const byParent = nodes.reduce<Record<string, SnapshotResponse['nodes']>>((result, node) => {
    const parentKey = node.parentId || '__root__'
    const current = result[parentKey] || []
    current.push(node)
    result[parentKey] = current
    return result
  }, {})

  const sortNodes = (items: NonNullable<SnapshotResponse['nodes']>) => {
    return [...items].sort((left, right) => {
      const topDiff = (left.bounds?.top || 0) - (right.bounds?.top || 0)
      if (topDiff !== 0) {
        return topDiff
      }
      return (left.bounds?.left || 0) - (right.bounds?.left || 0)
    })
  }

  const toTreeNode = (node: NonNullable<SnapshotResponse['nodes']>[number]): SnapshotTreeNode => {
    const children = sortNodes(byParent[node.id] || []).map(toTreeNode)

    return {
      id: node.id,
      kind: node.type || node.role || 'Node',
      label: node.text || node.value || '',
      clickable: !!node.clickable,
      children,
    }
  }

  return sortNodes(byParent.__root__ || []).map(toTreeNode)
}

const SnapshotPreview: FC<{ snapshot: SnapshotResponse | null }> = ({ snapshot }) => {
  const nodes = toSnapshotPreviewNodes(snapshot)
  const shellRef = useRef<HTMLDivElement | null>(null)
  const [canvasWidth, setCanvasWidth] = useState(snapshotPreviewFallbackWidth)

  useEffect(() => {
    const element = shellRef.current
    if (!element) {
      return
    }

    const updateWidth = () => {
      setCanvasWidth(Math.max(420, Math.floor(element.clientWidth - 2)))
    }

    updateWidth()

    const observer = new ResizeObserver(() => {
      updateWidth()
    })
    observer.observe(element)

    return () => {
      observer.disconnect()
    }
  }, [])

  if (!nodes.length) {
    return <Text type="secondary">no bounded nodes，先点 Query Snapshot</Text>
  }

  const minLeft = Math.min(...nodes.map((item) => item.bounds.left))
  const minTop = Math.min(...nodes.map((item) => item.bounds.top))
  const maxRight = Math.max(...nodes.map((item) => item.bounds.left + item.bounds.width))
  const maxBottom = Math.max(...nodes.map((item) => item.bounds.top + item.bounds.height))
  const width = Math.max(1, maxRight - minLeft)
  const height = Math.max(1, maxBottom - minTop)
  const scale = canvasWidth / width
  const canvasHeight = Math.max(220, Math.ceil(height * scale))

  return (
    <div ref={shellRef} className="snapshot-preview-shell">
      <div className="snapshot-preview-bar">
        <Text type="secondary">
          {(snapshot?.screen || snapshot?.summary?.screen || 'Unknown')} · {nodes.length} nodes
        </Text>
      </div>
      <div className="snapshot-preview-canvas" style={{ height: canvasHeight }}>
        {nodes.map((node) => {
          const label = node.text || node.value || node.id
          const typeLabel = node.type || node.role || 'Node'
          const kind = (node.role || node.type || '').toLowerCase()
          const isTextLike = kind === 'text' || kind === 'label'
          const isContainer = kind === 'container' || kind === 'panel'
          const scaledWidth = node.bounds.width * scale
          const scaledHeight = node.bounds.height * scale
          const showLabel = scaledWidth >= 18 && scaledHeight >= 8
          const fontSize = Math.max(7, Math.min(14, Math.floor(scaledHeight * 0.5)))

          return (
            <div
              key={node.id}
              className={[
                'snapshot-preview-node',
                node.clickable ? 'snapshot-preview-node--clickable' : '',
                isContainer ? 'snapshot-preview-node--container' : '',
                isTextLike ? 'snapshot-preview-node--text' : '',
              ].filter(Boolean).join(' ')}
              style={{
                left: (node.bounds.left - minLeft) * scale,
                top: (node.bounds.top - minTop) * scale,
                width: Math.max(scaledWidth, 12),
                height: Math.max(scaledHeight, 10),
                fontSize,
              }}
              title={`${node.id} / ${typeLabel}${label ? ` / ${label}` : ''}`}
            >
              {showLabel ? (
                <>
                  {!isContainer ? <div className="snapshot-preview-node-label">{label}</div> : null}
                  {!isTextLike && !isContainer ? <div className="snapshot-preview-node-meta">{typeLabel}</div> : null}
                </>
              ) : null}
            </div>
          )
        })}
      </div>
    </div>
  )
}

const SnapshotTreeView: FC<{ snapshot: SnapshotResponse | null }> = ({ snapshot }) => {
  const treeData = buildSnapshotTree(snapshot)

  if (!treeData.length) {
    return <Text type="secondary">no snapshot tree</Text>
  }

  const toAntdTreeNode = (node: SnapshotTreeNode): DataNode => {
    return {
      key: node.id,
      title: (
        <Space size={4} wrap>
          <Text code>{node.kind}</Text>
          <Text strong>{node.id}</Text>
          {node.label ? <Text type="secondary">{node.label}</Text> : null}
          {node.clickable ? <Tag color="blue">clickable</Tag> : null}
        </Space>
      ),
      children: node.children.map(toAntdTreeNode),
    }
  }

  return (
    <div className="snapshot-tree-shell">
      <Tree
        blockNode
        defaultExpandAll
        selectable={false}
        showLine
        treeData={treeData.map(toAntdTreeNode)}
      />
    </div>
  )
}

const App: FC = () => {
  const { message } = AntdApp.useApp()

  const [help, setHelp] = useState<HelpResponse | null>(null)
  const [actions, setActions] = useState<ActionCatalogResponse | null>(null)
  const [logs, setLogs] = useState<LogsResponse | null>(null)
  const [stateData, setStateData] = useState<StateResponse | null>(null)
  const [snapshot, setSnapshot] = useState<SnapshotResponse | null>(null)
  const [actionResult, setActionResult] = useState<ActionResponse | LogsClearResponse | null>(null)

  const [actionQueryForm] = Form.useForm()
  const [manualActionForm] = Form.useForm()
  const [logsForm] = Form.useForm()
  const [stateForm] = Form.useForm()
  const [snapshotForm] = Form.useForm()
  const actionQueryTargetId = Form.useWatch('targetId', actionQueryForm)
  const actionQueryAction = Form.useWatch('action', actionQueryForm)
  const manualActionTargetId = Form.useWatch('targetId', manualActionForm)
  const manualActionAction = Form.useWatch('action', manualActionForm)

  const actionTargetIdOptions = toOptions([
    ...(actions?.items || []).map((item) => item.targetId),
    ...(stateData?.summary?.targetStateTargets || []),
  ])
  const actionsByTargetId = (actions?.items || []).reduce<Record<string, string[]>>((result, item) => {
    result[item.targetId] = item.actions.map((action) => action.name)
    return result
  }, {})
  const actionNameOptions = toOptions(
    (actions?.items || []).flatMap((item) => item.actions.map((action) => action.name))
  )
  const actionQueryActionOptions = actionQueryTargetId
    ? toOptions(actionsByTargetId[actionQueryTargetId] || [])
    : actionNameOptions
  const manualActionOptions = manualActionTargetId
    ? toOptions(actionsByTargetId[manualActionTargetId] || [])
    : actionNameOptions
  const screenOptions = toOptions([
    help?.screenName,
    snapshot?.screen,
    snapshot?.summary?.screen,
    ...(actions?.items || []).map((item) => item.screen),
    ...(logs?.items || []).map((item) => item.data?.screen),
  ])
  const logEventOptions = toOptions([
    ...Object.keys(logs?.summary?.eventCountsTop || {}),
    ...(logs?.items || []).map((item) => item.event),
  ])
  const logLevelOptions = toOptions([
    ...Object.keys(logs?.summary?.levelCounts || {}),
    ...(logs?.items || []).map((item) => item.level),
  ])
  const logSourceOptions = toOptions([
    ...Object.keys(logs?.summary?.sourceCounts || {}),
    ...(logs?.items || []).map((item) => item.source),
  ])
  const logTargetIdOptions = toOptions([
    ...(logs?.items || []).map((item) => item.targetId),
    ...(actions?.items || []).map((item) => item.targetId),
  ])
  const stateKeyOptions = toOptions(
    (stateData?.summary?.appStateKeys || []).map((item) => item.key)
  )
  const stateTargetIdOptions = toOptions([
    ...(stateData?.summary?.targetStateTargets || []),
    ...(actions?.items || []).map((item) => item.targetId),
  ])
  const snapshotTargetIdOptions = toOptions([
    ...(snapshot?.nodes || []).map((item) => item.id),
    ...(actions?.items || []).map((item) => item.targetId),
  ])
  const snapshotTypeOptions = toOptions(
    (snapshot?.nodes || []).map((item) => item.type)
  )

  const actionColumns: ColumnsType<ActionCatalogResponse['items'][number]> = [
    {
      title: 'targetId',
      dataIndex: 'targetId',
      width: 180,
      render: (value) => <Text strong>{value}</Text>,
    },
    {
      title: 'type',
      dataIndex: 'targetType',
      width: 120,
      render: (value) => <Tag>{value}</Tag>,
    },
    {
      title: 'screen',
      dataIndex: 'screen',
      width: 140,
      render: (value) => <Tag>{value}</Tag>,
    },
    {
      title: 'actions',
      key: 'actions',
      render: (_, item) => (
        <Space size={4} wrap>
          {item.actions.map((action) => (
            <Button
              size="small"
              key={`${item.targetId}-${action.name}`}
              onClick={() => void runAction(action.example)}
            >
              {action.name}
            </Button>
          ))}
        </Space>
      ),
    },
  ]

  async function loadHelp() {
    const result = await fetchJSON<HelpResponse>('/help')
    setHelp(result)
    return result
  }

  async function loadActions(values?: Record<string, unknown>) {
    const formValues = values ?? actionQueryForm.getFieldsValue()
    const result = await fetchJSON<ActionCatalogResponse>(`/action${buildQuery(formValues)}`)
    setActions(result)
    return result
  }

  async function loadLogs(values?: Record<string, unknown>) {
    const formValues = values ?? logsForm.getFieldsValue()
    const result = await fetchJSON<LogsResponse>(`/logs${buildQuery(formValues)}`)
    setLogs(result)
    return result
  }

  async function loadState(values?: Record<string, unknown>) {
    const formValues = values ?? stateForm.getFieldsValue()
    const result = await fetchJSON<StateResponse>(`/state${buildQuery(formValues)}`)
    setStateData(result)
    return result
  }

  async function loadSnapshot(values?: Record<string, unknown>) {
    const formValues = normalizeSnapshotQuery(values ?? snapshotForm.getFieldsValue())
    const result = await fetchJSON<SnapshotResponse>(`/snapshot${buildQuery(formValues)}`)
    setSnapshot(result)
    return result
  }

  async function loadSnapshotSummary() {
    const result = await fetchJSON<SnapshotResponse>('/snapshot')
    setSnapshot(result)
    return result
  }

  async function refreshAll() {
    try {
      await Promise.all([
        loadHelp(),
        loadActions({}),
        loadLogs({}),
        loadState({}),
        loadSnapshot(),
      ])
    } catch (error) {
      message.error(String((error as Error).message || error))
    }
  }

  async function runAction(payload: ActionRequest) {
    try {
      const result = await fetchJSON<ActionResponse>('/action', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      })
      setActionResult(result)
      message.success(result.message)
      await Promise.all([loadHelp(), loadLogs({}), loadState({}), loadSnapshot()])
    } catch (error) {
      message.error(String((error as Error).message || error))
    }
  }

  async function runManualAction() {
    try {
      const values = await manualActionForm.validateFields()
      const args = values.args ? (JSON.parse(values.args) as Record<string, string>) : {}
      await runAction({
        action: values.action,
        targetId: values.targetId,
        text: values.text || undefined,
        dx: values.dx ?? undefined,
        dy: values.dy ?? undefined,
        source: values.source || undefined,
        args,
      })
    } catch (error) {
      message.error(String((error as Error).message || error))
    }
  }

  async function clearLogs() {
    try {
      const result = await fetchJSON<LogsClearResponse>('/logs', { method: 'DELETE' })
      setActionResult(result)
      message.success(result.message)
      await Promise.all([loadHelp(), loadLogs({})])
    } catch (error) {
      message.error(String((error as Error).message || error))
    }
  }

  useEffect(() => {
    actionQueryForm.setFieldsValue({})
    manualActionForm.setFieldsValue({ source: 'human', args: '{}' })
    logsForm.setFieldsValue({ limit: 20 })
    stateForm.setFieldsValue({})
    snapshotForm.setFieldsValue({ limit: 200, types: [] })
    void refreshAll()
  }, [])

  useEffect(() => {
    if (!actionQueryAction) {
      return
    }
    const matched = actionQueryActionOptions.some((item) => item.value === actionQueryAction)
    if (!matched) {
      actionQueryForm.setFieldValue('action', undefined)
    }
  }, [actionQueryAction, actionQueryActionOptions, actionQueryForm])

  useEffect(() => {
    if (!manualActionAction) {
      return
    }
    const matched = manualActionOptions.some((item) => item.value === manualActionAction)
    if (!matched) {
      manualActionForm.setFieldValue('action', undefined)
    }
  }, [manualActionAction, manualActionForm, manualActionOptions])

  return (
    <Layout>
      <Header style={{ background: '#fff', borderBottom: '1px solid #f0f0f0', paddingInline: 16, height: 56 }}>
        <Space direction="vertical" size={0}>
          <Title level={4} style={{ margin: 0, lineHeight: '32px', paddingTop: 6 }}>
            Freewind Debug Console
          </Title>
          <Text type="secondary">
            {help ? `${help.appName} / ${help.screenName} / ${help.serverTime}` : 'loading...'}
          </Text>
        </Space>
      </Header>
      <Content className="page">
        <Space direction="vertical" size={8} style={{ display: 'flex' }}>
          <Card size="small">
            <Space size={8} wrap>
              <Button size="small" type="primary" onClick={() => void refreshAll()}>
                Refresh All
              </Button>
              <Button size="small" onClick={() => void loadActions({})}>Refresh Actions</Button>
              <Button size="small" danger onClick={() => void clearLogs()}>
                Clear Logs
              </Button>
            </Space>
          </Card>

          <Flex gap={8} wrap>
            <Card size="small" className="stat-card"><Statistic title="Action Targets" value={help?.counts.actionTargetCount ?? 0} /></Card>
            <Card size="small" className="stat-card"><Statistic title="Logs" value={help?.counts.logCount ?? 0} /></Card>
            <Card size="small" className="stat-card"><Statistic title="State Keys" value={help?.counts.stateKeyCount ?? 0} /></Card>
            <Card size="small" className="stat-card"><Statistic title="Snapshot Nodes" value={help?.counts.snapshotNodeCount ?? 0} /></Card>
          </Flex>

          <Tabs
            size="small"
            items={[
              {
                key: 'logs',
                label: 'Logs',
                children: (
                  <Space direction="vertical" size={8} style={{ display: 'flex' }}>
                    <Card size="small" title="Query">
                      <Form form={logsForm} layout="vertical" size="small">
                        <Flex vertical gap="small">
                          <Flex gap="small" wrap>
                            <LabeledField name="event" label="event" className="query-cell"><Select {...commonSelectProps} allowClear options={logEventOptions} /></LabeledField>
                            <LabeledField name="level" label="level" className="query-cell"><Select {...commonSelectProps} allowClear options={logLevelOptions} /></LabeledField>
                            <LabeledField name="source" label="source" className="query-cell"><Select {...commonSelectProps} allowClear options={logSourceOptions} /></LabeledField>
                            <LabeledField name="targetId" label="targetId" className="query-cell"><Select {...commonSelectProps} allowClear options={logTargetIdOptions} /></LabeledField>
                            <LabeledField name="screen" label="screen" className="query-cell"><Select {...commonSelectProps} allowClear options={screenOptions} /></LabeledField>
                            <LabeledField name="from" label="from" className="query-cell"><Input size="small" style={compactInputStyle} /></LabeledField>
                            <LabeledField name="to" label="to" className="query-cell"><Input size="small" style={compactInputStyle} /></LabeledField>
                            <LabeledField name="limit" label="limit" className="query-cell query-cell--number"><InputNumber size="small" style={compactNumberStyle} /></LabeledField>
                            <LabeledField name="keyword" label="keyword" className="query-cell"><Input size="small" style={compactInputStyle} /></LabeledField>
                          </Flex>
                          <Space size={8} wrap>
                            <Button size="small" type="primary" onClick={() => void loadLogs()}>Query Logs</Button>
                            <Button size="small" onClick={() => void loadLogs({})}>Summary</Button>
                            <Button size="small" danger onClick={() => void clearLogs()}>Delete Logs</Button>
                          </Space>
                        </Flex>
                      </Form>
                    </Card>

                    <Card
                      size="small"
                      title="Table"
                      extra={<JsonInfoButton title="Logs JSON" value={logs} />}
                    >
                      <Table
                        size="small"
                        rowKey="seq"
                        columns={logColumns}
                        dataSource={logs?.items || []}
                        pagination={false}
                        scroll={{ x: 1200 }}
                      />
                    </Card>
                  </Space>
                ),
              },
              {
                key: 'action',
                label: 'Action',
                children: (
                  <Space direction="vertical" size={8} style={{ display: 'flex' }}>
                    <Card size="small" title="Query">
                      <Form form={actionQueryForm} layout="vertical" size="small">
                        <Flex vertical gap="small">
                          <Flex gap="small" wrap>
                            <LabeledField name="targetId" label="targetId" className="query-cell"><Select {...commonSelectProps} allowClear options={actionTargetIdOptions} /></LabeledField>
                            <LabeledField name="action" label="action" className="query-cell"><Select {...commonSelectProps} allowClear options={actionQueryActionOptions} /></LabeledField>
                            <LabeledField name="screen" label="screen" className="query-cell"><Select {...commonSelectProps} allowClear options={screenOptions} /></LabeledField>
                          </Flex>
                          <Button size="small" type="primary" onClick={() => void loadActions()}>Load Actions</Button>
                        </Flex>
                      </Form>
                    </Card>

                    <Card
                      size="small"
                      title="Action Table"
                      extra={<JsonInfoButton title="Action Catalog JSON" value={actions} />}
                    >
                      <Table
                        size="small"
                        rowKey="targetId"
                        columns={actionColumns}
                        dataSource={actions?.items || []}
                        pagination={false}
                        scroll={{ x: 760 }}
                      />
                    </Card>

                    <Card size="small" title="Manual Action">
                      <Form form={manualActionForm} layout="vertical" size="small">
                        <Flex vertical gap="small">
                          <Flex gap="small" wrap>
                            <LabeledField name="targetId" label="targetId" className="query-cell" rules={[{ required: true }]}><Select {...commonSelectProps} options={actionTargetIdOptions} /></LabeledField>
                            <LabeledField name="action" label="action" className="query-cell" rules={[{ required: true }]}><Select {...commonSelectProps} options={manualActionOptions} /></LabeledField>
                            <LabeledField name="source" label="source" className="query-cell"><Input size="small" style={compactInputStyle} /></LabeledField>
                            <LabeledField name="text" label="text" className="query-cell"><Input size="small" style={compactInputStyle} /></LabeledField>
                            <LabeledField name="dx" label="dx" className="query-cell query-cell--number"><InputNumber size="small" style={compactNumberStyle} /></LabeledField>
                            <LabeledField name="dy" label="dy" className="query-cell query-cell--number"><InputNumber size="small" style={compactNumberStyle} /></LabeledField>
                          </Flex>
                          <LabeledField name="args" label="args JSON"><Input.TextArea rows={4} /></LabeledField>
                          <Space size={8}>
                            <Button size="small" type="primary" onClick={() => void runManualAction()}>Send Action</Button>
                          </Space>
                        </Flex>
                      </Form>
                    </Card>

                    <Card size="small" title="Latest Result">
                      {renderJson(actionResult)}
                    </Card>
                  </Space>
                ),
              },
              {
                key: 'state',
                label: 'State',
                children: (
                  <Space direction="vertical" size={8} style={{ display: 'flex' }}>
                    <Card size="small" title="Query">
                      <Form form={stateForm} layout="vertical" size="small">
                        <Flex vertical gap="small">
                          <Flex gap="small" wrap>
                            <LabeledField name="keys" label="keys" className="query-cell query-cell--wide"><Select {...commonSelectProps} mode="multiple" allowClear options={stateKeyOptions} /></LabeledField>
                            <LabeledField name="targetId" label="targetId" className="query-cell"><Select {...commonSelectProps} allowClear options={stateTargetIdOptions} /></LabeledField>
                            <LabeledField name="scope" label="scope" className="query-cell"><Select {...commonSelectProps} allowClear options={stateScopeOptions} /></LabeledField>
                          </Flex>
                          <Space size={8}>
                            <Button size="small" type="primary" onClick={() => void loadState()}>Query State</Button>
                            <Button size="small" onClick={() => void loadState({})}>Summary</Button>
                          </Space>
                        </Flex>
                      </Form>
                    </Card>

                    <Card size="small" title="JSON">
                      {renderJson(stateData)}
                    </Card>
                  </Space>
                ),
              },
              {
                key: 'snapshot',
                label: 'Snapshot',
                children: (
                  <Space direction="vertical" size={8} style={{ display: 'flex' }}>
                    <Card size="small" title="Query">
                      <Form form={snapshotForm} layout="vertical" size="small">
                        <Flex vertical gap="small">
                          <Flex gap="small" wrap>
                            <LabeledField name="targetId" label="targetId" className="query-cell"><Select {...commonSelectProps} allowClear options={snapshotTargetIdOptions} /></LabeledField>
                            <LabeledField name="scope" label="scope" className="query-cell"><Select {...commonSelectProps} allowClear options={snapshotScopeOptions} /></LabeledField>
                            <LabeledField name="depth" label="depth" className="query-cell query-cell--number"><InputNumber size="small" style={compactNumberStyle} /></LabeledField>
                            <LabeledField name="types" label="types" className="query-cell query-cell--wide"><Select {...commonSelectProps} mode="multiple" allowClear options={snapshotTypeOptions} /></LabeledField>
                            <LabeledField name="textKeyword" label="textKeyword" className="query-cell"><Input size="small" style={compactInputStyle} /></LabeledField>
                            <LabeledField name="visible" label="visible" className="query-cell"><Select {...commonSelectProps} allowClear options={triStateOptions} /></LabeledField>
                            <LabeledField name="enabled" label="enabled" className="query-cell"><Select {...commonSelectProps} allowClear options={triStateOptions} /></LabeledField>
                            <LabeledField name="clickable" label="clickable" className="query-cell"><Select {...commonSelectProps} allowClear options={triStateOptions} /></LabeledField>
                            <LabeledField name="limit" label="limit" className="query-cell query-cell--number"><InputNumber size="small" style={compactNumberStyle} /></LabeledField>
                          </Flex>
                          <Space size={8}>
                            <Button size="small" type="primary" onClick={() => void loadSnapshot()}>Query Snapshot</Button>
                            <Button size="small" onClick={() => void loadSnapshotSummary()}>Summary</Button>
                          </Space>
                        </Flex>
                      </Form>
                    </Card>

                    <Flex gap={8} wrap align="start">
                      <Card
                        size="small"
                        title="Preview"
                        extra={<JsonInfoButton title="Snapshot JSON" value={snapshot} maxHeight={360} />}
                        className="snapshot-pane-card snapshot-pane-card--preview"
                      >
                        <SnapshotPreview snapshot={snapshot} />
                      </Card>

                      <Card
                        size="small"
                        title="Tree"
                        className="snapshot-pane-card snapshot-pane-card--tree"
                      >
                        <SnapshotTreeView snapshot={snapshot} />
                      </Card>
                    </Flex>
                  </Space>
                ),
              },
              {
                key: 'help',
                label: 'Help',
                children: (
                  <Space direction="vertical" size={8} style={{ display: 'flex' }}>
                    <Card size="small" title="JSON">
                      {renderJson(help)}
                    </Card>
                  </Space>
                ),
              },
            ]}
          />
          <Divider />
          <Text type="secondary">Vite + TypeScript + Antd build output served from Swift static dist.</Text>
        </Space>
      </Content>
    </Layout>
  )
}

export default App
