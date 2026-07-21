// Easter egg: after 30s, a pixel pet swims a few lengths down the right-hand
// lane — front crawl going down, flip-turn at the wall, backstroke coming
// back. Low-res canvas scaled up with image-rendering: pixelated for the
// retro look. Skipped for reduced motion and narrow viewports.

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches

const SPRITE_W = 28
const SPRITE_H = 32
const SCALE = 3

// Palette matched to the Codex pet: puffy blue cloud, navy terminal face.
const PALETTE = {
  O: '#262b4a', // outline
  B: '#7c97f5', // cloud blue
  D: '#5f78e0', // shaded blue
  H: '#aebfff', // highlight
  S: '#131c45', // terminal screen
  G: '#7de8ff', // prompt glyphs
  W: '#eef7ff', // splash
  F: '#c9dffc', // foam
}

// Front-facing pet, 20×24. Head leads via wrapper rotation (180° = diving
// down, 0° = backstroke up with the face showing).
const BASE = [
  '......OOO..OOO......',
  '.....OBBBOOBBBO.....',
  '...OOBBBBBBBBBBOO...',
  '..OBBBBBBBBBBBBBBO..',
  '.OBBHBBBBBBBBBBBBO..',
  '.OBBBBBBBBBBBBBBBBO.',
  'OBBOSSSSSSSSSSSSOBBO',
  'OBOSSSSSSSSSSSSSSOBO',
  'OBOSSGGSSSSSSSSSSOBO',
  'OBOSSSGGSSGGGGSSSOBO',
  'OBOSSGGSSSSSSSSSSOBO',
  '.OBOSSSSSSSSSSSSOBO.',
  '.OBBOSSSSSSSSSSOBBO.',
  '..OBBBBBBBBBBBBBBO..',
  '...OOBBBBBBBBBBOO...',
  '.....OOOOOOOOOO.....',
  '......ODBBBBDO......',
  '.....ODBBBBBBDO.....',
  '.....ODBSSSSBDO.....',
  '.....ODBSGGSBDO.....',
  '.....ODBBBBBBDO.....',
  '......ODO..ODO......',
  '......OBO..OBO......',
  '.......O....O.......',
]

const GRID_X = 4 // left margin inside the canvas
const GRID_Y = 3

function px(ctx, x, y, color) {
  ctx.fillStyle = color
  ctx.fillRect(Math.round(x), Math.round(y), 1, 1)
}

function drawGrid(ctx, rows, ox, oy) {
  rows.forEach((row, y) => {
    for (let x = 0; x < row.length; x++) {
      const key = row[x]
      if (key !== '.') px(ctx, ox + x, oy + y, PALETTE[key])
    }
  })
}

/** Stubby paddling arms; phase swaps which side is raised. */
function drawArms(ctx, ox, oy, phase) {
  const raisedLeft = phase % 2 === 0
  const arm = (side, raised) => {
    const dir = side === 'left' ? -1 : 1
    const shoulderX = ox + (side === 'left' ? 5 : 14)
    const shoulderY = oy + 17
    if (raised) {
      px(ctx, shoulderX + dir, shoulderY - 2, PALETTE.O)
      px(ctx, shoulderX + dir, shoulderY - 3, PALETTE.B)
      px(ctx, shoulderX + dir * 2, shoulderY - 4, PALETTE.B)
      px(ctx, shoulderX + dir * 2, shoulderY - 5, PALETTE.H)
      px(ctx, shoulderX + dir * 3, shoulderY - 5, PALETTE.F)
    } else {
      px(ctx, shoulderX + dir, shoulderY, PALETTE.O)
      px(ctx, shoulderX + dir * 2, shoulderY + 1, PALETTE.B)
      px(ctx, shoulderX + dir * 2, shoulderY + 2, PALETTE.B)
      px(ctx, shoulderX + dir * 3, shoulderY + 2, PALETTE.F)
    }
  }
  arm('left', raisedLeft)
  arm('right', !raisedLeft)
}

/**
 * One animation frame. mode: 'crawl' | 'back' | 'flip'. phase: 0..3.
 */
function drawFrame(ctx, mode, phase) {
  ctx.clearRect(0, 0, SPRITE_W, SPRITE_H)

  if (mode === 'flip') {
    // Tucked ball: just the cloud head + a swirl of foam.
    drawGrid(ctx, BASE.slice(0, 15), GRID_X, GRID_Y + 5)
    const swirl = [
      [4, 4], [22, 5], [26, 14], [21, 26], [6, 25], [2, 15],
    ]
    swirl.forEach(([x, y], i) => {
      px(ctx, x, y, (i + phase) % 2 === 0 ? PALETTE.W : PALETTE.F)
    })
    return
  }

  const wobble = phase % 2 === 0 ? 0 : 1
  drawGrid(ctx, BASE, GRID_X + wobble, GRID_Y)
  drawArms(ctx, GRID_X + wobble, GRID_Y, phase + (mode === 'back' ? 1 : 0))

  // Kick splash trailing off the feet (sprite bottom = trailing edge).
  const feetY = GRID_Y + 24
  const kick = phase % 2 === 0
  px(ctx, GRID_X + (kick ? 7 : 12) + wobble, feetY, PALETTE.W)
  px(ctx, GRID_X + (kick ? 12 : 7) + wobble, feetY + 1, PALETTE.F)
  px(ctx, GRID_X + 9 + wobble, feetY + 2, PALETTE.W)
  if (phase === 3) px(ctx, GRID_X + 11 + wobble, feetY + 3, PALETTE.F)
}

function buildLane() {
  const lane = document.createElement('div')
  lane.className = 'swim-lane'
  lane.setAttribute('aria-hidden', 'true')
  const canvas = document.createElement('canvas')
  canvas.className = 'swimmer'
  canvas.width = SPRITE_W
  canvas.height = SPRITE_H
  lane.append(canvas)
  document.body.append(lane)
  return { lane, canvas }
}

async function swimSession() {
  if (window.innerWidth < 900) return
  const { lane, canvas } = buildLane()
  const ctx = canvas.getContext('2d')
  requestAnimationFrame(() => lane.classList.add('visible'))

  const SPEED = 110 // px/s
  const FLIP_MS = 650
  const wallTop = 26
  const wallBottom = () => window.innerHeight - 26 - canvas.offsetHeight

  // Lengths: crawl down → flip → backstroke up → flip → crawl down, exit.
  const legs = [
    { mode: 'crawl', dir: 1 },
    { mode: 'back', dir: -1 },
    { mode: 'crawl', dir: 1, exit: true },
  ]

  let legIndex = 0
  let legStart = null
  let legStartY = -canvas.offsetHeight - 10
  // Debug hook: ?pety=300 starts the swim mid-lane (headless screenshots).
  const debugY = parseFloat(new URLSearchParams(location.search).get('pety'))
  if (Number.isFinite(debugY)) legStartY = debugY
  let flipUntil = 0
  let spinFrom = 0

  return new Promise((resolve) => {
    function frame(now) {
      // Elapsed-time based (never per-frame deltas): identical behavior at
      // any frame cadence.
      if (legStart === null) legStart = now
      const leg = legs[legIndex]
      const phase = Math.floor(now / 130) % 4

      let rotation = leg.dir === 1 ? 180 : 0
      let mode = leg.mode
      let y = legStartY + leg.dir * (SPEED * (now - legStart)) / 1000

      if (flipUntil > now) {
        const t = 1 - (flipUntil - now) / FLIP_MS
        rotation = spinFrom + 360 * t
        mode = 'flip'
        y = legStartY
      } else {
        const pastBottom = leg.dir === 1 && y >= wallBottom()
        const pastTop = leg.dir === -1 && y <= wallTop
        if ((pastBottom || pastTop) && !leg.exit) {
          // Tumble at the wall, then start the next length from here.
          spinFrom = rotation
          flipUntil = now + FLIP_MS
          legStartY = pastBottom ? wallBottom() : wallTop
          legStart = now + FLIP_MS
          legIndex += 1
          y = legStartY
        } else if (leg.exit && y > window.innerHeight + 20) {
          lane.classList.remove('visible')
          setTimeout(() => {
            lane.remove()
            resolve()
          }, 450)
          return
        }
      }

      drawFrame(ctx, mode, phase)
      canvas.style.transform = `translateY(${y}px) rotate(${rotation}deg)`
      requestAnimationFrame(frame)
    }
    requestAnimationFrame(frame)
  })
}

async function schedule() {
  const instant = new URLSearchParams(location.search).has('pet')
  await new Promise((r) => setTimeout(r, instant ? 800 : 30_000))
  for (;;) {
    while (document.hidden) {
      await new Promise((r) => setTimeout(r, 1000))
    }
    await swimSession()
    await new Promise((r) => setTimeout(r, 150_000))
  }
}

if (!reducedMotion) {
  schedule()
}
