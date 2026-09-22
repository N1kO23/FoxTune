// The dashboard the benchmark draws: a real user's Speeduino layout, as the app
// saved it - 9 dials, 2 digital readouts, 14 lamps and 4 time graphs (60, 30,
// 30 and 10 seconds) on its first page. Kept as it was saved rather than
// tidied, so the benchmark measures a dashboard someone actually built.
const speeduinoDashboard = r'''
{
  "version": 3,
  "pages": [
    {
      "id": "hmhybebeeo-0",
      "name": "Main",
      "density": 24,
      "width": "laptop",
      "items": [
        {
          "id": "hmhybebere-1",
          "style": "dial",
          "x": 0,
          "y": 0,
          "w": 8,
          "h": 8,
          "gauges": [
            "tachometer"
          ]
        },
        {
          "id": "hmhybebezf-2",
          "style": "dial",
          "x": 8,
          "y": 0,
          "w": 8,
          "h": 8,
          "gauges": [
            "throttleGauge"
          ]
        },
        {
          "id": "hmhybebezo-3",
          "style": "dial",
          "x": 16,
          "y": 0,
          "w": 8,
          "h": 8,
          "gauges": [
            "pulseWidthGauge"
          ]
        },
        {
          "id": "hmhybebf02-4",
          "style": "dial",
          "x": 24,
          "y": 0,
          "w": 8,
          "h": 8,
          "gauges": [
            "dutyCycleGauge"
          ]
        },
        {
          "id": "hmhybebf0i-5",
          "style": "dial",
          "x": 8,
          "y": 8,
          "w": 8,
          "h": 8,
          "gauges": [
            "mapGauge"
          ]
        },
        {
          "id": "hmhybebf12-6",
          "style": "dial",
          "x": 16,
          "y": 8,
          "w": 8,
          "h": 8,
          "gauges": [
            "iatGauge"
          ]
        },
        {
          "id": "hmhybebf23-7",
          "style": "dial",
          "x": 24,
          "y": 8,
          "w": 8,
          "h": 8,
          "gauges": [
            "cltGauge"
          ]
        },
        {
          "id": "hmhybebf36-8",
          "style": "dial",
          "x": 0,
          "y": 8,
          "w": 8,
          "h": 8,
          "gauges": [
            "gammaEnrichGauge"
          ]
        },
        {
          "id": "hmhybebf6p-9",
          "style": "graph",
          "x": 0,
          "y": 20,
          "w": 72,
          "h": 12,
          "gauges": [
            "afrGauge"
          ],
          "window": 60
        },
        {
          "id": "hmhybebf8v-a",
          "style": "digital",
          "x": 0,
          "y": 16,
          "w": 8,
          "h": 4,
          "gauges": [
            "batteryVoltage"
          ]
        },
        {
          "id": "hmhybebfb2-b",
          "style": "graph",
          "x": 32,
          "y": 0,
          "w": 16,
          "h": 8,
          "gauges": [
            "advanceGauge"
          ],
          "window": 30
        },
        {
          "id": "hmhybebfdy-c",
          "style": "graph",
          "x": 32,
          "y": 8,
          "w": 16,
          "h": 8,
          "gauges": [
            "ve1Gauge"
          ],
          "window": 30
        },
        {
          "id": "hmhybebfgr-d",
          "style": "graph",
          "x": 48,
          "y": 0,
          "w": 8,
          "h": 8,
          "gauges": [
            "egoCorrGauge"
          ],
          "window": 10
        },
        {
          "id": "hmhybebfo4-e",
          "style": "lamp",
          "x": 18,
          "y": 16,
          "w": 6,
          "h": 2,
          "indicator": "running"
        },
        {
          "id": "hmhybebfro-f",
          "style": "lamp",
          "x": 18,
          "y": 18,
          "w": 6,
          "h": 2,
          "indicator": "crank"
        },
        {
          "id": "hmhybebfuf-g",
          "style": "lamp",
          "x": 12,
          "y": 16,
          "w": 6,
          "h": 2,
          "indicator": "ase"
        },
        {
          "id": "hmhybebfwf-h",
          "style": "lamp",
          "x": 12,
          "y": 18,
          "w": 6,
          "h": 2,
          "indicator": "warmup"
        },
        {
          "id": "hmhybebfyc-i",
          "style": "lamp",
          "x": 8,
          "y": 16,
          "w": 4,
          "h": 2,
          "indicator": "tpsaccaen"
        },
        {
          "id": "hmhybebg0d-j",
          "style": "lamp",
          "x": 8,
          "y": 18,
          "w": 4,
          "h": 2,
          "indicator": "tpsaccden"
        },
        {
          "id": "hmhybebg2r-k",
          "style": "lamp",
          "x": 24,
          "y": 18,
          "w": 6,
          "h": 2,
          "indicator": "mapaccaen"
        },
        {
          "id": "hmhybebg4j-l",
          "style": "lamp",
          "x": 24,
          "y": 16,
          "w": 6,
          "h": 2,
          "indicator": "mapaccden"
        },
        {
          "id": "hmhybebg65-m",
          "style": "lamp",
          "x": 42,
          "y": 16,
          "w": 6,
          "h": 2,
          "indicator": "error"
        },
        {
          "id": "hmhybebg7y-n",
          "style": "lamp",
          "x": 30,
          "y": 16,
          "w": 6,
          "h": 2,
          "indicator": "(tps > tpsflood) && (rpm < crankRPM)"
        },
        {
          "id": "hmhybebg9r-o",
          "style": "lamp",
          "x": 42,
          "y": 18,
          "w": 6,
          "h": 2,
          "indicator": "DFCOOn"
        },
        {
          "id": "hmhybebgbq-p",
          "style": "lamp",
          "x": 30,
          "y": 18,
          "w": 6,
          "h": 2,
          "indicator": "launchHard"
        },
        {
          "id": "hmi95s37fs-0",
          "style": "lamp",
          "x": 36,
          "y": 16,
          "w": 6,
          "h": 2,
          "indicator": "sync"
        },
        {
          "id": "hmi95whizu-1",
          "style": "dial",
          "x": 48,
          "y": 8,
          "w": 8,
          "h": 8,
          "gauges": [
            "syncLossGauge"
          ]
        },
        {
          "id": "hmi963045e-2",
          "style": "digital",
          "x": 48,
          "y": 16,
          "w": 8,
          "h": 4,
          "gauges": [
            "channel:syncStatus"
          ]
        },
        {
          "id": "hmi973eltq-3",
          "style": "lamp",
          "x": 36,
          "y": 18,
          "w": 6,
          "h": 2,
          "indicator": "halfSync"
        }
      ]
    },
    {
      "id": "hmhyc81ui7-q",
      "name": "Test",
      "density": 48,
      "width": "monitor",
      "items": [
        {
          "id": "hmhycu7c33-r",
          "style": "dial",
          "x": 0,
          "y": 0,
          "w": 12,
          "h": 12,
          "gauges": [
            "warmupEnrichGauge"
          ]
        },
        {
          "id": "hmhye34ygp-s",
          "style": "dial",
          "x": 12,
          "y": 0,
          "w": 12,
          "h": 12,
          "gauges": [
            "tachometer"
          ]
        }
      ]
    }
  ]
}
''';
