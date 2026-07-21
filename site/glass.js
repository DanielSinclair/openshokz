// Liquid glass via @liquid-dom/core (WebGPU), with the CSS backdrop-filter
// panels in styles.css as the everywhere-fallback.
//
// The page background is painted on a 2D canvas and uploaded as the glass
// core's backdropTexture, so no experimental HTML-in-Canvas flag is needed —
// the WebGPU layer composites background + glass and sits behind the live DOM
// content. The blobs drift slowly so the refraction reads as liquid.

const bg = document.getElementById('bg')
const fx = document.getElementById('fx')

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
const dpr = () => Math.min(window.devicePixelRatio || 1, 2)

// Canvases cover the whole document so they scroll with the content.
const docHeight = () =>
  Math.max(document.documentElement.scrollHeight, window.innerHeight)

function drawBackground(time = 0) {
  const w = window.innerWidth
  const h = docHeight()
  const scale = dpr()
  const pxW = Math.max(1, Math.round(w * scale))
  const pxH = Math.max(1, Math.round(h * scale))
  if (bg.width !== pxW || bg.height !== pxH) {
    bg.width = pxW
    bg.height = pxH
    bg.style.height = `${h}px`
  }
  const ctx = bg.getContext('2d')
  ctx.setTransform(scale, 0, 0, scale, 0, 0)

  const base = ctx.createLinearGradient(0, 0, 0, h)
  base.addColorStop(0, '#f2f5fa')
  base.addColorStop(1, '#e3e9f2')
  ctx.fillStyle = base
  ctx.fillRect(0, 0, w, h)

  const blob = (x, y, r, color) => {
    const g = ctx.createRadialGradient(x, y, 0, x, y, r)
    g.addColorStop(0, color)
    g.addColorStop(1, 'rgba(255,255,255,0)')
    ctx.fillStyle = g
    ctx.fillRect(x - r, y - r, r * 2, r * 2)
  }

  // Saturated pool-water hues so glass panels have something to bend.
  const t = time / 1000
  const drift = (fx1, fy1, ax, ay, speed, phase) => [
    w * fx1 + Math.sin(t * speed + phase) * ax,
    h * fy1 + Math.cos(t * speed * 0.8 + phase) * ay,
  ]
  let [x, y] = drift(0.24, 0.2, 60, 40, 0.21, 0)
  blob(x, y, Math.max(w, h) * 0.42, 'rgba(96, 156, 255, 0.55)')
  ;[x, y] = drift(0.8, 0.26, 70, 50, 0.17, 2.1)
  blob(x, y, Math.max(w, h) * 0.38, 'rgba(64, 199, 214, 0.5)')
  ;[x, y] = drift(0.52, 0.85, 80, 45, 0.14, 4.2)
  blob(x, y, Math.max(w, h) * 0.44, 'rgba(150, 130, 255, 0.42)')
  ;[x, y] = drift(0.1, 0.75, 50, 60, 0.19, 1.2)
  blob(x, y, Math.max(w, h) * 0.3, 'rgba(255, 178, 128, 0.35)')
}

async function initLiquid() {
  if (!navigator.gpu) throw new Error('WebGPU unavailable')
  const adapter = await navigator.gpu.requestAdapter()
  if (!adapter) throw new Error('No WebGPU adapter')
  const device = await adapter.requestDevice()
  const { Scene, Container, Glass, WebGpuGlassCore } =
    await import('./vendor/liquid-dom/index.js')

  const format = navigator.gpu.getPreferredCanvasFormat()
  const context = fx.getContext('webgpu')
  context.configure({ device, format, alphaMode: 'opaque' })
  const core = new WebGpuGlassCore({ device, format })

  const scene = new Scene()
  const panels = [...document.querySelectorAll('[data-glass]')].map((el) => {
    // One container per panel: separate containers never fuse.
    const container = new Container({
      blur: 9,
      bezelWidth: 12,
      thickness: 48,
      ior: 1.46,
      dispersion: 6,
      specularOpacity: 0.62,
      specularWidth: 'hairline',
      tint: { r: 1, g: 1, b: 1, a: 0.34 },
      shadowColor: { r: 0.12, g: 0.18, b: 0.3, a: 0.2 },
      shadowOffsetY: 9,
      shadowBlur: 22,
    })
    const glass = new Glass({
      width: 10,
      height: 10,
      cornerRadius: 12,
      cornerSmoothing: 0.6,
    })
    container.add(glass)
    scene.add(container)
    return { el, container, glass }
  })

  let backdropTexture = null

  function uploadBackdrop() {
    if (
      !backdropTexture ||
      backdropTexture.width !== bg.width ||
      backdropTexture.height !== bg.height
    ) {
      backdropTexture?.destroy()
      backdropTexture = device.createTexture({
        size: [bg.width, bg.height],
        format,
        usage:
          GPUTextureUsage.COPY_DST |
          GPUTextureUsage.TEXTURE_BINDING |
          GPUTextureUsage.RENDER_ATTACHMENT,
      })
    }
    device.queue.copyExternalImageToTexture(
      { source: bg },
      { texture: backdropTexture },
      [bg.width, bg.height]
    )
  }

  function positionPanels() {
    for (const panel of panels) {
      const rect = panel.el.getBoundingClientRect()
      panel.container.x = rect.left + window.scrollX
      panel.container.y = rect.top + window.scrollY
      panel.glass.width = rect.width
      panel.glass.height = rect.height
      const radius = parseFloat(getComputedStyle(panel.el).borderRadius)
      panel.glass.cornerRadius = Math.min(
        Number.isFinite(radius) ? radius : rect.height / 2,
        rect.height / 2
      )
    }
  }

  function render() {
    core.render({
      scene,
      width: fx.width,
      height: fx.height,
      dpr: dpr(),
      outputTexture: context.getCurrentTexture(),
      backdropTexture,
    })
  }

  let lastTime = 0

  function sync(time = 0) {
    const scale = dpr()
    fx.width = Math.max(1, Math.round(window.innerWidth * scale))
    fx.height = Math.max(1, Math.round(docHeight() * scale))
    fx.style.height = `${docHeight()}px`
    drawBackground(time)
    uploadBackdrop()
    positionPanels()
    render()
  }

  window.addEventListener('resize', () => sync(lastTime))

  await (document.fonts?.ready ?? Promise.resolve())
  sync()
  document.documentElement.classList.add('liquid')

  if (!reducedMotion) {
    // Panels re-position and re-render every frame so the glass never lags
    // the DOM during scroll or hover; the background drift stays at ~30fps.
    let lastFrame = 0
    const tick = (now) => {
      requestAnimationFrame(tick)
      if (document.hidden) return
      if (now - lastFrame >= 33) {
        lastFrame = now
        lastTime = now
        drawBackground(now)
        uploadBackdrop()
      }
      positionPanels()
      render()
    }
    requestAnimationFrame(tick)
  }
}

drawBackground()
window.addEventListener('resize', () => drawBackground())

if (!reducedMotion && !navigator.gpu) {
  // CSS-fallback browsers still get the drifting background (backdrop-filter
  // samples the canvas live).
  let lastFrame = 0
  const tick = (now) => {
    requestAnimationFrame(tick)
    if (document.hidden || now - lastFrame < 33) return
    lastFrame = now
    drawBackground(now)
  }
  requestAnimationFrame(tick)
}

initLiquid().catch((error) => {
  // CSS backdrop-filter glass stays active — nothing else to do.
  console.warn('liquid glass unavailable:', error)
})
