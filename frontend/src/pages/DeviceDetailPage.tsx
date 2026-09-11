import { useParams } from 'react-router'
import { EmptyState } from '../components/EmptyState'

/** Placeholder -- real content lands in a later issue. */
export function DeviceDetailPage() {
  const { deviceId } = useParams<{ deviceId: string }>()
  return (
    <EmptyState
      title={`Device: ${deviceId}`}
      description="Device detail is coming in a later issue."
    />
  )
}
