import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import SensorTable from './SensorTable'

describe('SensorTable', () => {
  it('shows the waiting message when no sensor data is available', () => {
    render(<SensorTable data={[]} hasData={false} />)

    expect(
      screen.getByText(
        'No sensor data yet. Waiting for WebSocket connection...',
      ),
    ).toBeTruthy()
  })
})
